. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Auth.ps1"

Describe 'LAN authentication modes' {
    It 'stores client Guest policy snapshots in a machine-wide path' {
        $path = Get-LanClientGuestStatePath
        $path | Should Match ([regex]::Escape($env:ProgramData))
        $path | Should Not Match ([regex]::Escape($env:LOCALAPPDATA))
    }
    It 'reuses the account the machine already uses for its shares' {
        # Windows keeps one credential per server, so a second share on the same machine has to be reached with
        # the same account. A fresh LFS_ name for every share meant two shares on one machine used different
        # accounts — even when the user typed the same password — and neither could connect while the other was:
        # the client answered 1219 and the drives took turns failing. The existing account is therefore handed
        # to the creator instead of a new one being invented.
        $script:seenReuse = $null
        $adapter = @{
            FindHostAccount = { [pscustomobject]@{ UserName='LFS_existing'; Sid='S-1-5-21-1-2-3-1001'; Password='Pw1!' } }
            CreateProtected = {
                param($password,$reuse)
                $script:seenReuse = $reuse
                # Reusing means the same account comes back, and the stored password when none was typed.
                return @{ UserName=[string]$reuse.UserName; Sid=[string]$reuse.Sid; Password=[string]$reuse.Password }
            }
        }
        $access = Resolve-LanAccess -AuthMode Protected -Adapter $adapter
        $access.CredentialInfo.UserName | Should Be 'LFS_existing'
        $access.CredentialInfo.Password | Should Be 'Pw1!'
        $access.AllowedSids | Should Be @('S-1-5-21-1-2-3-1001')
        $script:seenReuse.UserName | Should Be 'LFS_existing'
    }

    It 'rejects a different visible account name when the machine must reuse its existing share account' {
        $script:createAfterMismatch = $false
        $adapter = @{
            PreferredAccountName = 'Ks'
            FindHostAccount = { [pscustomobject]@{ UserName='LFS_existing'; Sid='S-1-5-21-1-2-3-1001'; Password='Pw1!' } }
            CreateProtected = {
                $script:createAfterMismatch = $true
                @{ UserName='LFS_existing'; Sid='S-1-5-21-1-2-3-1001'; Password='Pw1!' }
            }
        }

        { Resolve-LanAccess -AuthMode Protected -ProtectedPasswordMode Random -Adapter $adapter } | Should Throw
        $script:createAfterMismatch | Should Be $false
    }

    It 'still asks the creator when the machine has no share account yet' {
        # Nothing to reuse means a new account, and the creator is responsible for making it.
        $script:reusePassed = 'not-called'
        $adapter = @{
            FindHostAccount = { $null }
            CreateProtected = {
                param($password,$reuse)
                $script:reusePassed = $reuse
                return @{ UserName='LFS_new'; Sid='S-1-5-21-1-2-3-2002'; Password='Pw2!' }
            }
        }
        $access = Resolve-LanAccess -AuthMode Protected -Adapter $adapter
        $access.CredentialInfo.UserName | Should Be 'LFS_new'
        ($null -eq $script:reusePassed) | Should Be $true
    }
    It 'creates credentials only for Protected mode' {
        $script:created = 0
        $adapter = @{
            CreateProtected = { $script:created++; @{ UserName='LFS_1'; Sid='S-1-5-21-1-1'; Password='secret' } }
            ResolvePrincipal = { param($name) 'S-1-5-21-2-2' }
            GetGuestSid = { 'S-1-5-21-3-501' }
        }
        $a = Resolve-LanAccess -AuthMode Protected -WindowsPrincipals @() -Adapter $adapter
        $b = Resolve-LanAccess -AuthMode WindowsCurrent -WindowsPrincipals @('user') -Adapter $adapter
        $c = Resolve-LanAccess -AuthMode Guest -WindowsPrincipals @() -Adapter $adapter
        $script:created | Should Be 1
        $a.CredentialInfo.UserName | Should Be 'LFS_1'
        $b.CredentialInfo | Should BeNullOrEmpty
        $c.CredentialInfo | Should BeNullOrEmpty
        $b.AllowedSids[0] | Should Be 'S-1-5-21-2-2'
        $c.AllowedSids[0] | Should Be 'S-1-5-21-3-501'
    }

    It 'grants authenticated Windows users when no account is specified' {
        $script:resolved = 0
        $adapter = @{ ResolvePrincipal = { param($name) $script:resolved++; 'S-1-5-21-2-2' } }
        $access = Resolve-LanAccess -AuthMode WindowsCurrent -WindowsPrincipals @() -Adapter $adapter
        @($access.AllowedSids) | Should Be @('S-1-5-11')
        $script:resolved | Should Be 0
    }

    It 'uses the chosen Protected password and rejects an empty manual password' {
        $script:chosenPassword = $null
        $adapter = @{ CreateProtected = {
            param($password)
            $script:chosenPassword = $password
            @{ UserName='LFS_1'; Sid='S-1-5-21-1-1'; Password=$password }
        } }
        $access = Resolve-LanAccess -AuthMode Protected -ProtectedPasswordMode Manual -ProtectedPassword 'Chosen#Pass123' -Adapter $adapter

        $script:chosenPassword | Should Be 'Chosen#Pass123'
        $access.CredentialInfo.Password | Should Be 'Chosen#Pass123'
        $preview = Resolve-LanAccess -AuthMode Protected -ProtectedPasswordMode Random -ProtectedPassword 'Preview#Pass456' -Adapter $adapter
        $preview.CredentialInfo.Password | Should Be 'Preview#Pass456'
        { Resolve-LanAccess -AuthMode Protected -ProtectedPasswordMode Manual -ProtectedPassword '' -Adapter $adapter } | Should Throw 'Password is required'
    }

    It 'passes the selected password into the actual local-account adapter' {
        Mock New-LocalUser { [pscustomobject]@{ SID=[pscustomobject]@{ Value='S-1-5-21-1-1' } } }
        $adapter = New-LanAuthAdapter

        $credential = & $adapter.CreateProtected 'Chosen#Pass123'

        $credential.Password | Should Be 'Chosen#Pass123'
        Assert-MockCalled New-LocalUser -Times 1 -Exactly -Scope It -ParameterFilter { $Password -is [Security.SecureString] }
    }

    It 'generates a nonempty random password for Protected mode' {
        $first = New-LanProtectedPassword
        $second = New-LanProtectedPassword

        $first.Length | Should BeGreaterThan 24
        $first | Should Not Be $second
    }

    It 'reports signing and managed policy as blockers, not silent changes' {
        $adapter = @{ GetGuestPolicy = { param($role) @{ Managed=$true; RequireSigning=$true; RequireEncryption=$false; InsecureGuestAllowed=$false; UnrelatedSharesAtRisk=@() } } }
        $check = Get-LanGuestCompatibility -Role Client -Adapter $adapter
        $check.Supported | Should Be $false
        @($check.BlockedReasons).Count | Should BeGreaterThan 0
        ($check.RequiredChanges -join ',') | Should Match 'InsecureGuestAllowed'
    }

    It 'refuses guest host changes when another share may become accessible' {
        $adapter = @{ GetGuestPolicy = { param($role) @{ Managed=$false; RequireSigning=$false; RequireEncryption=$false; PasswordProtectedSharing=$true; GuestEnabled=$false; UnrelatedSharesAtRisk=@('OtherShare') } } }
        $check = Get-LanGuestCompatibility -Role Host -Adapter $adapter
        $check.Supported | Should Be $false
        $check.UnrelatedSharesAtRisk[0] | Should Be 'OtherShare'
    }

    It 'changes only required Guest settings and restores recorded values' {
        $path = Join-Path $TestDrive 'guest.json'
        $script:values = @{ Managed=$false; RequireSigning=$false; RequireEncryption=$false; InsecureGuestAllowed=$false; UnrelatedSharesAtRisk=@() }
        $adapter = @{
            GetGuestPolicy = { param($role) $script:values.Clone() }
            ApplyGuestChange = { param($role,$key,$value) $script:values[$key] = $value }
        }
        $result = Enable-LanGuestConfiguration -Role Client -Adapter $adapter -StatePath $path
        $result.Enabled | Should Be $true
        $script:values.InsecureGuestAllowed | Should Be $true
        @((Read-LanState -Path $path).GuestSnapshots).Count | Should Be 1
        Restore-LanGuestConfiguration -Role Client -Adapter $adapter -StatePath $path | Out-Null
        $script:values.InsecureGuestAllowed | Should Be $false
        @((Read-LanState -Path $path).GuestSnapshots).Count | Should Be 0
    }

    It 'does not overwrite an externally changed setting on restore' {
        $path = Join-Path $TestDrive 'external.json'
        $script:values = @{ Managed=$false; RequireSigning=$false; RequireEncryption=$false; InsecureGuestAllowed=$false; UnrelatedSharesAtRisk=@() }
        $adapter = @{
            GetGuestPolicy = { param($role) $script:values.Clone() }
            ApplyGuestChange = { param($role,$key,$value) $script:values[$key] = $value }
        }
        Enable-LanGuestConfiguration -Role Client -Adapter $adapter -StatePath $path | Out-Null
        $script:values.InsecureGuestAllowed = $false
        $result = Restore-LanGuestConfiguration -Role Client -Adapter $adapter -StatePath $path
        $result.Skipped.Count | Should Be 1
        $script:values.InsecureGuestAllowed | Should Be $false
    }
    It 'enables a compatible Host Guest account explicitly and restores it' {
        $path = Join-Path $TestDrive 'host-guest.json'
        $script:hostGuestEnabled = $false
        $adapter = @{
            GetGuestPolicy = { param($role) @{Managed=$false;RequireSigning=$false;RequireEncryption=$false;GuestEnabled=$script:hostGuestEnabled;UnrelatedSharesAtRisk=@()} }
            ApplyGuestChange = { param($role,$key,$value) $script:hostGuestEnabled=[bool]$value }
        }
        Enable-LanGuestConfiguration -Role Host -Adapter $adapter -StatePath $path | Out-Null
        $script:hostGuestEnabled | Should Be $true
        Restore-LanGuestConfiguration -Role Host -Adapter $adapter -StatePath $path | Out-Null
        $script:hostGuestEnabled | Should Be $false
    }
    It 'does not change Host Guest policy during a concurrent host transaction' {
        $path = Join-Path $TestDrive 'locked-host-guest.json'
        $script:changedHostGuest = $false
        $adapter = @{
            GetGuestPolicy = { param($role) @{Managed=$false;RequireSigning=$false;RequireEncryption=$false;GuestEnabled=$false;UnrelatedSharesAtRisk=@()} }
            ApplyGuestChange = { param($role,$key,$value) $script:changedHostGuest=$true }
        }
        $lock = Enter-LanStateLock -StatePath $path -TimeoutMilliseconds 200
        try {
            { Enable-LanGuestConfiguration -Role Host -Adapter $adapter -StatePath $path -LockTimeoutMilliseconds 100 } | Should Throw 'Timed out waiting'
            $script:changedHostGuest | Should Be $false
        } finally { $lock.Dispose() }
    }
}
