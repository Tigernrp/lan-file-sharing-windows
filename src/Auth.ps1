function Get-LanClientGuestStatePath {
    return Join-Path (Join-Path $env:ProgramData 'LanFileSharingGuest') 'guest-state.json'
}

function New-LanProtectedPassword {
    $bytes = New-Object byte[] 24
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','A').Replace('/','B') + 'a1!'
    } finally {
        $random.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Resolve-LanAccess {
    param(
        [Parameter(Mandatory)][ValidateSet('Protected','WindowsCurrent','Guest')][string]$AuthMode,
        [string[]]$WindowsPrincipals = @(),
        [ValidateSet('Random','Manual')][string]$ProtectedPasswordMode = 'Random',
        [string]$ProtectedPassword,
        [Parameter(Mandatory)][hashtable]$Adapter
    )
    $sids = @()
    $credential = $null
    switch ($AuthMode) {
        'Protected' {
            if (-not $Adapter.CreateProtected) { throw 'Protected-account adapter is unavailable.' }
            if ($ProtectedPasswordMode -eq 'Manual' -and [string]::IsNullOrWhiteSpace($ProtectedPassword)) {
                throw 'Password is required for Protected Password.'
            }
            if ($ProtectedPassword -and $ProtectedPassword.Length -gt 127) {
                throw 'Protected Password cannot exceed 127 characters.'
            }
            # The account this machine already uses for its shares is offered to the creator first.
            #
            # Windows keeps one credential per server, so every share on a machine has to be reached with the
            # same account. Creating a fresh LFS_ account for each share meant two shares on one machine used
            # different names — even when the user typed the same password — and neither could be connected
            # while the other was: the client answered 1219 and the drives took turns failing. Reusing the
            # account is not a convenience, it is what makes a second share usable at all.
            $reuse = $null
            if ($Adapter.FindHostAccount) { $reuse = & $Adapter.FindHostAccount }
            $visibleName = ([string]$Adapter.PreferredAccountName).Trim()
            if ($reuse -and $visibleName -and
                -not [string]::Equals($visibleName,[string]$reuse.UserName,[StringComparison]::OrdinalIgnoreCase)) {
                # Windows keeps one credential per server. Reusing the saved account is required for every
                # share on this machine, but doing it while the form displays a different name makes the form
                # promise something the program will not do. Stop before touching an account or any ACL and
                # direct the owner to the button that fills the real saved credentials.
                throw "เครื่องนี้ใช้บัญชีแชร์ '$($reuse.UserName)' อยู่แล้ว กรุณากด 'ใช้บัญชีเดิม' เพื่อเติมชื่อและรหัสที่ถูกต้องก่อนเริ่มแชร์"
            }
            if ($reuse -and $ProtectedPasswordMode -eq 'Random') {
                $ProtectedPassword = [string]$reuse.Password
            }
            $credential = & $Adapter.CreateProtected $ProtectedPassword $reuse
            if (-not $credential.UserName -or -not $credential.Sid -or -not $credential.Password) {
                throw 'Protected account was not created completely.'
            }
            $sids = @($credential.Sid)
        }
        'WindowsCurrent' {
            if (@($WindowsPrincipals).Count -eq 0) {
                # Authenticated Users, not Everyone or Guest. Use the SID so localized names work.
                $sids = @('S-1-5-11')
            } else {
                if (-not $Adapter.ResolvePrincipal) { throw 'Windows-principal adapter is unavailable.' }
                foreach ($name in $WindowsPrincipals) {
                    $sid = & $Adapter.ResolvePrincipal $name
                    if (-not $sid) { throw "Windows account cannot be resolved: $name" }
                    $sids += $sid
                }
            }
        }
        'Guest' {
            if (-not $Adapter.GetGuestSid) { throw 'Guest-account adapter is unavailable.' }
            $sid = & $Adapter.GetGuestSid
            if (-not $sid) { throw 'Guest account is unavailable.' }
            $sids = @($sid)
        }
    }
    return [pscustomobject]@{ AuthMode=$AuthMode; AllowedSids=@($sids); CredentialInfo=$credential }
}

function Get-LanGuestCompatibility {
    param([Parameter(Mandatory)][ValidateSet('Host','Client')][string]$Role,
          [Parameter(Mandatory)][hashtable]$Adapter)
    if (-not $Adapter.GetGuestPolicy) { throw 'Guest-policy adapter is unavailable.' }
    $policy = & $Adapter.GetGuestPolicy $Role
    $blocked = @()
    $changes = @()
    if ($policy.Managed) { $blocked += 'Guest policy is managed by an administrator or domain.' }
    if ($policy.RequireSigning) { $blocked += 'SMB signing is required; Guest cannot satisfy signing.' }
    if ($policy.RequireEncryption) { $blocked += 'SMB encryption is required; Guest cannot satisfy encryption.' }
    if ($policy.Unsupported) { $blocked += [string]$policy.Unsupported }
    $risk = @($policy.UnrelatedSharesAtRisk | Where-Object { $_ })
    if ($Role -eq 'Host') {
        if ($risk.Count -gt 0) { $blocked += 'Other shares may become accessible to Guest.' }
        if (-not $policy.GuestEnabled) { $changes += 'GuestEnabled' }
        if ($policy.PasswordProtectedSharing) { $changes += 'PasswordProtectedSharing' }
    } else {
        if (-not $policy.InsecureGuestAllowed) { $changes += 'InsecureGuestAllowed' }
    }
    return [pscustomobject]@{
        Supported=($blocked.Count -eq 0); BlockedReasons=@($blocked)
        RequiredChanges=@($changes); UnrelatedSharesAtRisk=@($risk)
        Policy=$policy
    }
}

function New-LanAuthAdapter {
    return @{
        CreateProtected = {
            param($password, $reuse)
            # An account this machine already uses is reused instead of a new one being invented.
            #
            # Windows keeps one credential per server, so every share on a machine has to be reached with the
            # same account. A fresh LFS_ name for each share meant two shares on one machine used different
            # accounts — even when the user typed the same password — and neither could be connected while the
            # other was: the client answered 1219 and the drives took turns failing.
            if ($reuse -and $reuse.UserName -and $reuse.Sid) {
                $secret = if ([string]::IsNullOrEmpty($password)) { [string]$reuse.Password } else { $password }
                if ([string]::IsNullOrEmpty($secret)) { throw 'The existing share account has no usable password.' }
                # All shares use this account. Changing its password here invalidates the
                # saved login details of every existing share, even if creation later fails.
                if (-not [string]::IsNullOrEmpty($password) -and $password -cne [string]$reuse.Password) {
                    throw 'The existing share account uses a different password. Use its current password, or choose Random to reuse the saved password.'
                }
                # Saved credentials alone do not establish ownership: the name may
                # have been deleted and recreated for another Windows user.
                $existing = Get-LocalUser -Name ([string]$reuse.UserName) -ErrorAction SilentlyContinue
                if (-not $existing -or [string]$existing.Description -cne 'LAN File Sharing app account' -or
                    [string]$existing.SID.Value -ne [string]$reuse.Sid) {
                    throw 'The existing share account is unavailable or is no longer owned by LAN File Sharing.'
                }
                # Repair older app accounts without rotating their saved password.
                # Target the checked SID so a replacement account cannot be changed.
                Set-LocalUser -SID $existing.SID -PasswordNeverExpires $true -ErrorAction Stop
                return @{ UserName=[string]$reuse.UserName; Sid=[string]$reuse.Sid; Password=$secret }
            }
            if ([string]::IsNullOrEmpty($password)) { $password = New-LanProtectedPassword }
            # The name the owner typed, when one was given and Windows accepts it. A name they choose is easier
            # to recognise in Windows than a random string, and it is a local account on their own computer, so
            # nothing about choosing it is against policy — the password is the part that has to stay strong.
            $userName = ''
            # Read from the adapter rather than from a bare name: this script block runs in the caller's scope,
            # so a key of the adapter is not visible as a variable here. That is what silently sent every share
            # back to a random name even though the name had been set.
            $preferred = ''
            $requested = $Adapter.PreferredAccountName
            if ($requested) { $preferred = ([string]$requested).Trim() }
            if ($preferred) {
                $safeName = $preferred -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$' -and
                    $preferred -notmatch '^(?i)(administrator|guest|defaultaccount|wdagutilityaccount|system|localsystem|networkservice|localservice)$'
                if (-not $safeName) {
                    throw 'ชื่อบัญชีแชร์ใช้ได้เฉพาะ A-Z, 0-9, จุด, ขีดล่าง หรือขีดกลาง ยาว 1-20 ตัว และห้ามเป็นชื่อบัญชีระบบของ Windows'
                }
                $existingAccount = Get-LocalUser -Name $preferred -ErrorAction SilentlyContinue
                if (-not $existingAccount) {
                    $userName = $preferred
                } elseif ([string]$existingAccount.Description -eq 'LAN File Sharing app account') {
                    # The account this program made earlier is adopted rather than a second one being invented.
                    # Refusing it because the name was already taken meant the name the owner chose worked once
                    # and then silently stopped working: the next share made a random account beside it, and
                    # Windows — one credential per machine — could then only reach one of them at a time. The
                    # description is the marker, so an account belonging to something else is still never used.
                    $userName = $preferred
                } else {
                    # Never turn a visible choice into an unrelated random account. In particular, "Ks" is
                    # commonly the owner's real Windows login. Taking it over would require changing that
                    # account's password, while silently choosing LFS_* makes the form lie about what it will
                    # create. Refuse the collision and let the owner enter a new, dedicated share-account name.
                    throw "ชื่อบัญชี '$preferred' มีอยู่ใน Windows แล้วและไม่ได้สร้างโดย LAN File Sharing กรุณาใช้ชื่อใหม่ เช่น LFS_Ks หรือกด 'ใช้บัญชีเดิม' หากมีบัญชีแชร์อยู่แล้ว"
                }
            }
            if (-not $userName) { $userName = 'LFS_' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
            $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
            $existing = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
            if ($existing) {
                if ([string]$existing.Description -cne 'LAN File Sharing app account') {
                    throw 'The selected Windows account is not owned by LAN File Sharing.'
                }
                # Already ours: set the password it should have and use it as it is.
                try { Set-LocalUser -SID $existing.SID -Password $secure -PasswordNeverExpires $true -ErrorAction Stop }
                catch { throw "Windows rejected the Protected Password for the existing account: $($_.Exception.Message)" }
                return @{ UserName=$userName; Sid=$existing.SID.Value; Password=$password }
            }
            try { $user = New-LocalUser -Name $userName -Password $secure -Description 'LAN File Sharing app account' -PasswordNeverExpires -ErrorAction Stop }
            catch { throw "Windows rejected the Protected Password or could not create the account: $($_.Exception.Message)" }
            return @{ UserName=$userName; Sid=$user.SID.Value; Password=$password }
        }
        ResolvePrincipal = {
            param($name)
            return ([Security.Principal.NTAccount]::new($name)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        GetGuestSid = {
            $guest = Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' } | Select-Object -First 1
            if (-not $guest) { throw 'Windows Guest account is unavailable.' }
            return $guest.SID.Value
        }
        GetGuestPolicy = {
            param($role)
            if ($role -eq 'Client') {
                $config = Get-SmbClientConfiguration -ErrorAction Stop
                $managed = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
                return @{
                    Managed=$managed; RequireSigning=[bool]$config.RequireSecuritySignature
                    RequireEncryption=[bool]$config.RequireEncryption
                    InsecureGuestAllowed=[bool]$config.EnableInsecureGuestLogons
                    UnrelatedSharesAtRisk=@()
                }
            }
            $config = Get-SmbServerConfiguration -ErrorAction Stop
            $guest = Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' } | Select-Object -First 1
            $unrelated = @(Get-SmbShare -ErrorAction Stop | Where-Object {
                $_.Name -ne 'IPC$' -and $_.Name -ne 'ADMIN$' -and $_.Name -notmatch '^[A-Za-z]\$$' -and
                $_.Description -notlike 'LanFileSharing:*'
            } | Select-Object -ExpandProperty Name)
            return @{
                Managed=(Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanServer')
                RequireSigning=[bool]$config.RequireSecuritySignature
                RequireEncryption=[bool]$config.EncryptData
                GuestEnabled=($guest -and $guest.Enabled)
                UnrelatedSharesAtRisk=$unrelated
            }
        }
        ApplyGuestChange = {
            param($role,$key,$value)
            if ($role -eq 'Client' -and $key -eq 'InsecureGuestAllowed') {
                Set-SmbClientConfiguration -EnableInsecureGuestLogons ([bool]$value) -Force -ErrorAction Stop | Out-Null
                return
            }
            if ($role -eq 'Host' -and $key -eq 'GuestEnabled') {
                $guest = Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' } | Select-Object -First 1
                if (-not $guest) { throw 'Windows Guest account is unavailable.' }
                if ($value) { Enable-LocalUser -Name $guest.Name -ErrorAction Stop }
                else { Disable-LocalUser -Name $guest.Name -ErrorAction Stop }
                return
            }
            throw "Automatic Guest policy change is unsupported: $role/$key"
        }
    }
}

function Enable-LanGuestConfigurationCore {
    param([Parameter(Mandatory)][ValidateSet('Host','Client')][string]$Role,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$StatePath)
    $check = Get-LanGuestCompatibility -Role $Role -Adapter $Adapter
    if (-not $check.Supported) { throw ($check.BlockedReasons -join '; ') }
    if (-not $Adapter.ApplyGuestChange -and @($check.RequiredChanges).Count -gt 0) { throw 'Guest setting adapter is unavailable.' }
    $state = Read-LanState -Path $StatePath
    foreach ($key in $check.RequiredChanges) {
        $target = $key -ne 'PasswordProtectedSharing'
        $already = @($state.GuestSnapshots | Where-Object { $_.Role -eq $Role -and $_.Setting -eq $key })
        if ($already.Count -gt 0) { continue }
        $snapshot = [pscustomobject]@{ Role=$Role; Setting=$key; Original=[bool]$check.Policy[$key]; Expected=[bool]$target }
        $state.GuestSnapshots = @($state.GuestSnapshots) + @($snapshot)
        Write-LanState -Path $StatePath -State $state
        & $Adapter.ApplyGuestChange $Role $key $target
    }
    return [pscustomobject]@{ Enabled=$true; Changes=@($check.RequiredChanges) }
}

function Enable-LanGuestConfiguration {
    param([Parameter(Mandatory)][ValidateSet('Host','Client')][string]$Role,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$StatePath,
          [int]$LockTimeoutMilliseconds = 30000)
    $stateLock = Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds
    try { return Enable-LanGuestConfigurationCore -Role $Role -Adapter $Adapter -StatePath $StatePath }
    finally { $stateLock.Dispose() }
}

function Restore-LanGuestConfigurationCore {
    param([Parameter(Mandatory)][ValidateSet('Host','Client')][string]$Role,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$StatePath)
    $state = Read-LanState -Path $StatePath
    if (@($state.GuestSnapshots | Where-Object { $_.Role -eq $Role }).Count -eq 0) {
        return [pscustomobject]@{ Restored=@(); Skipped=@() }
    }
    $policy = & $Adapter.GetGuestPolicy $Role
    $skipped = @(); $restored = @(); $remaining = @()
    foreach ($item in @($state.GuestSnapshots)) {
        if ($item.Role -ne $Role) { $remaining += $item; continue }
        if ([bool]$policy[$item.Setting] -ne [bool]$item.Expected) {
            $skipped += $item.Setting
            $remaining += $item
            continue
        }
        & $Adapter.ApplyGuestChange $Role $item.Setting ([bool]$item.Original)
        $restored += $item.Setting
    }
    $state.GuestSnapshots = @($remaining)
    Write-LanState -Path $StatePath -State $state
    return [pscustomobject]@{ Restored=@($restored); Skipped=@($skipped) }
}

function Restore-LanGuestConfiguration {
    param([Parameter(Mandatory)][ValidateSet('Host','Client')][string]$Role,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$StatePath,
          [int]$LockTimeoutMilliseconds = 30000)
    $stateLock = Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds
    try { return Restore-LanGuestConfigurationCore -Role $Role -Adapter $Adapter -StatePath $StatePath }
    finally { $stateLock.Dispose() }
}
