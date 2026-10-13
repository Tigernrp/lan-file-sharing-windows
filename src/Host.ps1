. (Join-Path $PSScriptRoot 'Network.ps1')

$script:LanHostActiveJournalIds = @{}
. (Join-Path $PSScriptRoot 'Online.ps1')

if (-not ('LanHostProcessTime' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class LanHostProcessTime {
 [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr OpenProcess(uint rights,bool inherit,int id);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetProcessTimes(IntPtr h,out long created,out long exited,out long kernel,out long user);
 [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr h);
 public static long StartTicks(int id) {
  IntPtr h=OpenProcess(0x1000,false,id);if(h==IntPtr.Zero)return 0;
  try {long c,e,k,u;return GetProcessTimes(h,out c,out e,out k,out u)?DateTime.FromFileTimeUtc(c).Ticks:0;}
  finally {CloseHandle(h);}
 }
}
'@
}

function New-LanShareTransactionLease {
    param([string]$Name,[string]$StatePath)
    $security=New-Object Security.AccessControl.MutexSecurity
    $security.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
    }
    $caller=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $sidPath=Join-Path (Split-Path -Parent $StatePath) 'broker-user.sid'
    if([IO.File]::Exists($sidPath)){$caller=[Security.Principal.SecurityIdentifier]::new([IO.File]::ReadAllText($sidPath).Trim())}
    $rights=[Security.AccessControl.MutexRights]::Synchronize -bor [Security.AccessControl.MutexRights]::Modify
    $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($caller,$rights,[Security.AccessControl.AccessControlType]::Allow))
    $created=$false
    return [Threading.Mutex]::new($false,$Name,[ref]$created,$security)
}

function Invoke-LanHostAdapter {
    param([hashtable]$Adapter, [string]$Operation, [object[]]$Arguments = @())
    if (-not $Adapter.ContainsKey($Operation)) { throw "Host operation unavailable: $Operation" }
    return & $Adapter[$Operation] @Arguments
}

function Test-LanOwnedShare {
    param($Actual, [string]$Path, [string]$Id)
    return ($Actual -and
        [string]::Equals([string]$Actual.Path,$Path,[StringComparison]::OrdinalIgnoreCase) -and
        [string]$Actual.Description -eq "LanFileSharing:$Id")
}

function Test-LanManagedShare {
    param($Actual)
    # True for any SMB share this application created, including one recorded by a different
    # installation or an older state file. Its description carries our marker, so it is ours to
    # remove; a share created by the user or another program has no such marker and must be left
    # alone.
    if (-not $Actual) { return $false }
    return ([string]$Actual.Description -match '^LanFileSharing:')
}

function Test-LanHostShareHealth {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$StatePath,
          [hashtable]$Adapter=(New-LanHostAdapter))
    $state=Read-LanState $StatePath
    $entry=@($state.Shares | Where-Object {$_.Id -eq $Id}) | Select-Object -First 1
    if (-not $entry -or $entry.Status -ne 'Running') { throw 'แชร์ที่เลือกยังไม่อยู่ในสถานะ Running' }
    $actual=Invoke-LanHostAdapter $Adapter GetShare @($entry.Name)
    if (-not (Test-LanOwnedShare -Actual $actual -Path $entry.SharePath -Id $entry.Id)) { throw 'ไม่พบ SMB share ที่ตรงกับพาธและรหัสของรายการนี้' }
    if (-not [IO.Directory]::Exists($entry.SharePath)) { throw 'พาธที่แชร์ไม่พร้อมใช้งาน' }
    $access=@(Invoke-LanHostAdapter $Adapter GetShareAccess @($entry.Name))
    if (@($access | Where-Object {$_.AccessControlType -eq 'Deny'}).Count) { throw 'พบ SMB Deny ที่อาจบล็อกการเข้าใช้ กรุณาตรวจสิทธิ์แชร์' }
    foreach ($account in @(Resolve-LanSmbAccountNames -Sids @($entry.AllowedSids))) {
        $allowed=@($access | Where-Object { $_.AccountName -eq $account -and $_.AccessControlType -eq 'Allow' -and
            ($_.AccessRight -eq 'Full' -or $_.AccessRight -eq 'Change' -or ($entry.Mode -eq 'Read' -and $_.AccessRight -eq 'Read')) })
        if (-not $allowed.Count) { throw 'สิทธิ์ SMB ของบัญชีที่อนุญาตไม่ครบ' }
    }
    if ($entry.AuthMode -eq 'Protected') {
        $account=Invoke-LanHostAdapter $Adapter GetProtectedAccount @($entry.CredentialInfo.UserName)
        if (-not $account -or -not $account.Enabled -or [string]$account.SID.Value -ne [string]$entry.CredentialInfo.Sid -or
            $account.Description -ne 'LAN File Sharing app account') { throw 'บัญชี Protected ของแชร์นี้ไม่พร้อมใช้งานหรือไม่ตรงกับบัญชีเดิม' }
    } elseif ($entry.AuthMode -eq 'Guest') {
        $guest=Get-LanGuestCompatibility -Role Host -Adapter (New-LanAuthAdapter)
        if ($state.OnlineSettings.Enabled -or -not $guest.Supported -or @($guest.RequiredChanges).Count) { throw 'บัญชีหรือนโยบาย Guest ไม่พร้อมสำหรับแชร์นี้' }
    }
    foreach ($record in @($entry.AclRecords)) {
        $acl=Get-LanNtfsAccess -Path $record.Path
        Assert-LanNoDenyAcl -Acl $acl -Path $record.Path -Mode $entry.Mode -LocalUserSidPrefix (Get-LanLocalUserSidPrefix -Sids $entry.AllowedSids) -IgnoreOrphanedDeny:($entry.AllowedSids -contains 'S-1-5-11')
        $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        $required=if($entry.Mode -eq 'Read'){[int][Security.AccessControl.FileSystemRights]::ReadAndExecute}else{[int][Security.AccessControl.FileSystemRights]::Modify}
        foreach($sid in @($entry.AllowedSids)) {
            [int]$granted=0
            foreach($rule in $rules){
                if($rule.IdentityReference.Value -eq $sid -and $rule.AccessControlType -eq 'Allow' -and
                   -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){
                    $granted=$granted -bor (ConvertTo-LanSpecificAclMask ([int]$rule.FileSystemRights))
                }
            }
            if(($granted -band $required) -ne $required){throw "สิทธิ์ NTFS สำหรับบัญชีที่อนุญาตไม่ครบ: $($record.Path)"}
        }
        $present=@($rules | ForEach-Object {Get-LanAclRuleKey $_})
        foreach ($rule in (Get-LanAccessRuleDelta -Before $record.Before -After $record.After).Rules) {
            if ((Get-LanAclRuleKey $rule) -notin $present) { throw "สิทธิ์ NTFS ที่โปรแกรมตั้งเปลี่ยนไป: $($record.Path)" }
        }
    }
    return [pscustomobject]@{Healthy=$true;Summary="ตรวจแชร์ผ่าน: \\$env:COMPUTERNAME\$($entry.Name) — SMB, บัญชี และสิทธิ์ NTFS ที่บันทึกตรงกัน"}
}

function Get-LanHostProcessStartTicks {
    param([int]$Id)
    return [LanHostProcessTime]::StartTicks($Id)
}

function Test-LanActiveJournal {
    param($Journal,[switch]$AllowLeaseOnly)
    if (-not $Journal.ActiveProcessId -or -not $Journal.ActiveProcessStartTicks) { return $false }
    try {
        # .NET Framework requests broad process rights for StartTime and cannot
        # inspect SYSTEM from the normal UI. Query only limited information.
        $startTicks=Get-LanHostProcessStartTicks -Id ([int]$Journal.ActiveProcessId)
        if ($startTicks) {
            if ($startTicks -ne [long]$Journal.ActiveProcessStartTicks) { return $false }
        } else {
            # Some SYSTEM task processes deny even limited queries. UI may
            # observe a live PID plus its held GUID lease, but the recovery
            # worker retains the strict process identity check by default.
            if (-not $AllowLeaseOnly) { return $false }
            $owner=[Diagnostics.Process]::GetProcessById([int]$Journal.ActiveProcessId)
            $owner.Dispose()
        }
        if ($Journal.ActiveLeaseName -ne ('Global\LanFileSharing-Share-' + $Journal.Id)) { return $false }
        if ([int]$Journal.ActiveProcessId -eq $PID -and $script:LanHostActiveJournalIds.ContainsKey([string]$Journal.Id)) { return $true }
        $lease = $null
        try {
            $rights=[Security.AccessControl.MutexRights]::Synchronize -bor [Security.AccessControl.MutexRights]::Modify
            $lease = [Threading.Mutex]::OpenExisting([string]$Journal.ActiveLeaseName,$rights)
            try {
                if (-not $lease.WaitOne(0)) { return $true }
                $lease.ReleaseMutex()
                return $false
            } catch [Threading.AbandonedMutexException] {
                $lease.ReleaseMutex()
                return $false
            }
        } finally { if ($lease) { $lease.Dispose() } }
    } catch { return $false }
}

function Enable-LanBlankPasswordNetworkLogon {
    param([Parameter(Mandatory)][string]$StatePath,[Parameter(Mandatory)][hashtable]$Adapter)
    $lock = Enter-LanStateLock -StatePath $StatePath
    try {
        $state = Read-LanState -Path $StatePath
        $current = Invoke-LanHostAdapter $Adapter 'GetBlankPasswordPolicy'
        if ($state.BlankPasswordSnapshot) {
            if ($current.Present -and [int]$current.Value -eq 0) { return [pscustomobject]@{Changed=$false;Value=0} }
            $original = $state.BlankPasswordSnapshot
            if (-not ($current.Present -eq $original.Present -and [int]$current.Value -eq [int]$original.Value)) {
                throw 'Blank-password policy changed outside this app; its original setting is retained for recovery.'
            }
            Invoke-LanHostAdapter $Adapter 'SetBlankPasswordPolicy' @($true,0) | Out-Null
            return [pscustomobject]@{Changed=$true;Value=0}
        }
        if ($current.Present -and [int]$current.Value -eq 0) { return [pscustomobject]@{Changed=$false;Value=0} }
        $state.BlankPasswordSnapshot = [pscustomobject]@{Present=[bool]$current.Present;Value=[int]$current.Value}
        Write-LanState -Path $StatePath -State $state
        Invoke-LanHostAdapter $Adapter 'SetBlankPasswordPolicy' @($true,0) | Out-Null
        return [pscustomobject]@{Changed=$true;Value=0}
    } finally { $lock.Dispose() }
}

function Restore-LanBlankPasswordNetworkLogon {
    param([Parameter(Mandatory)][string]$StatePath,[Parameter(Mandatory)][hashtable]$Adapter)
    $lock = Enter-LanStateLock -StatePath $StatePath
    try {
        $state = Read-LanState -Path $StatePath
        if (-not $state.BlankPasswordSnapshot) { return [pscustomobject]@{Restored=$false} }
        $current = Invoke-LanHostAdapter $Adapter 'GetBlankPasswordPolicy'
        $original = $state.BlankPasswordSnapshot
        if ($current.Present -and [int]$current.Value -eq 0) {
            Invoke-LanHostAdapter $Adapter 'SetBlankPasswordPolicy' @([bool]$original.Present,[int]$original.Value) | Out-Null
        } elseif (-not ($current.Present -eq $original.Present -and [int]$current.Value -eq [int]$original.Value)) {
            throw 'Blank-password policy changed outside this app; its recovery snapshot was retained.'
        }
        $state.BlankPasswordSnapshot = $null
        Write-LanState -Path $StatePath -State $state
        return [pscustomobject]@{Restored=$true}
    } finally { $lock.Dispose() }
}

function Start-LanHostShareCore {
    param(
        [Parameter(Mandatory)]$Selection,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Read','Modify')][string]$Mode,
        [Parameter(Mandatory)]$Access,
        [bool]$AutoStart = $true,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][hashtable]$Adapter,
        [ref]$StateLock,
        [int]$LockTimeoutMilliseconds = 30000
    )
    Write-LanProgress -Message "ตรวจสอบชื่อแชร์ '$Name'"
    Assert-LanShareName -Name $Name | Out-Null
    Write-LanProgress -Message "ตรวจสอบพาธที่เลือกและสิทธิ์ NTFS"
    Assert-LanShareRoot -Selection $Selection | Out-Null
    $state = Read-LanState -Path $StatePath
    Update-LanShareOnlineSnapshot -State $state -Adapter $Adapter
    if (@($state.Shares | Where-Object { $_.Name -eq $Name }).Count -gt 0 -or
        @($state.Journal | Where-Object { $_.Name -eq $Name }).Count -gt 0 -or
        (Invoke-LanHostAdapter $Adapter 'GetShare' @($Name))) { throw "Share name is already in use: $Name" }
    if (Test-LanOverlap -Candidate $Selection.FullPath -Existing @(@($state.Shares) + @($state.Journal) | ForEach-Object { $_.SourcePath })) {
        throw 'Selected path overlaps an existing app share.'
    }
    if ($Access.AuthMode -eq 'Guest') {
        if($state.OnlineSettings.Enabled){throw 'Guest shares cannot be created while Online sharing is enabled.'}
        Write-LanProgress -Message 'ตรวจสอบนโยบาย Guest ของเครื่องนี้'
        $check = Get-LanGuestCompatibility -Role Host -Adapter $Adapter
        if (-not $check.Supported -or @($check.RequiredChanges).Count -gt 0) {
            throw 'Guest host policy is not compatible. Use the separate Guest configuration action and verify compatibility.'
        }
    }
    Write-LanProgress -Message 'เตรียมโปรไฟล์เครือข่าย LAN ให้เป็น Private'
    $networkProfile = Ensure-LanShareNetwork -Adapter $Adapter
    $id = [guid]::NewGuid().ToString('N')
    $sharePath = $Selection.FullPath
    $ntfsPolicy = if (Test-LanSystemDriveRoot -Path $sharePath -Kind $Selection.Kind) { 'Preserved' } else { 'Managed' }
    $singleFile = $null
    if ($Selection.Kind -eq 'File') {
        Write-LanProgress -Message 'เตรียมโฟลเดอร์แยกสำหรับแชร์ไฟล์เดียว'
        if (-not (Get-Command New-LanSingleFileRoot -ErrorAction SilentlyContinue)) { throw 'Single-file isolation is unavailable.' }
        $singleFile = New-LanSingleFileRoot -SourcePath $Selection.FullPath -ShareId $id
        $sharePath = $singleFile.Root
    }
    $journal = [pscustomobject]@{
        Id=$id; Name=$Name; SourcePath=$Selection.FullPath; SharePath=$sharePath
        AclRecords=@(); FirewallSnapshot=$null; SingleFile=$singleFile; Phase='Preparing'
        ActiveProcessId=$PID; ActiveProcessStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        ActiveLeaseName=('Global\LanFileSharing-Share-' + $id)
        AccountName=$(if ($Access.CredentialInfo) { $Access.CredentialInfo.UserName } else { $null })
    }
    $state.Journal = @($state.Journal) + @($journal)
    Write-LanState -Path $StatePath -State $state
    $transactionLease = New-LanShareTransactionLease -Name $journal.ActiveLeaseName -StatePath $StatePath
    if (-not $transactionLease.WaitOne(0)) { $transactionLease.Dispose(); throw 'Share transaction lease is already held.' }
    $script:LanHostActiveJournalIds[$id] = $true
    $shareCreated = $false
    try {
        Write-LanProgress -Message 'เปิดกฎ Firewall สำหรับ SMB บนเครือข่าย Private'
        $journal.FirewallSnapshot = Invoke-LanHostAdapter $Adapter 'EnableFirewall' @($Adapter)
        $journal.Phase = 'FirewallReady'
        Write-LanState -Path $StatePath -State $state
        # Closures run in a dynamic module in Windows PowerShell. Capture callable
        # functions explicitly instead of relying on another module's scope.
        $enterState = ${function:Enter-LanStateLock}
        $readState = ${function:Read-LanState}
        $writeState = ${function:Write-LanState}
        $beforeApply = {
            param($record)
            # A bounded ACL retry updates the same intention, not a second grant.
            $journal.AclRecords = @($journal.AclRecords | Where-Object { $_.Path -ne $record.Path }) + @($record)
            if ($StateLock) {
                $recordLock = & $enterState -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds
                try {
                    $latest = & $readState -Path $StatePath
                    $latest.Journal = @($latest.Journal | Where-Object { $_.Id -ne $journal.Id }) + @($journal)
                    & $writeState -Path $StatePath -State $latest
                } finally { $recordLock.Dispose() }
            } else { & $writeState -Path $StatePath -State $state }
        }.GetNewClosure()
        $granted = if ($ntfsPolicy -eq 'Preserved') {
            Write-LanProgress -Message 'ไดรฟ์ระบบ: ใช้สิทธิ์ NTFS เดิม ไม่แก้ ACL ของไดรฟ์ C:'
            @()
        } else {
            if ($StateLock) { $StateLock.Value.Dispose(); $StateLock.Value = $null }
            try {
                @(Invoke-LanHostAdapter $Adapter 'GrantAcl' @($sharePath, $Access.AllowedSids, $Mode, $beforeApply, $Selection.Kind))
            } finally {
                if ($StateLock) {
                    $StateLock.Value = Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds
                    # Worker/policy operations may have saved changes while NTFS was busy.
                    $state = Read-LanState -Path $StatePath
                    $state.Journal = @($state.Journal | Where-Object { $_.Id -ne $id }) + @($journal)
                }
            }
        }
        foreach ($record in $granted) {
            if (@($journal.AclRecords | Where-Object { $_.Path -eq $record.Path }).Count -eq 0) {
                $journal.AclRecords = @($journal.AclRecords) + @($record)
            }
        }
        $journal.Phase = 'AclReady'
        Write-LanState -Path $StatePath -State $state
        Write-LanProgress -Message "ตั้งสิทธิ์ NTFS แล้ว $($journal.AclRecords.Count) รายการ"
        Write-LanProgress -Message 'ตรวจสอบว่าไดรฟ์ไม่เปลี่ยนระหว่างติดตั้ง'
        $currentVolume = Get-LanVolumeIdentity $Selection.VolumeRoot
        if ($currentVolume.Id -ne $Selection.VolumeId) { throw 'The selected volume changed during share setup.' }
        Write-LanProgress -Message 'ยืนยันโปรไฟล์เครือข่าย Private'
        Update-LanShareOnlineSnapshot -State $state -Adapter $Adapter
        $networkProfile=Ensure-LanShareNetwork -Adapter $Adapter -Expected $networkProfile
        Write-LanProgress -Message "สร้าง SMB share '$Name' (Temporary)"
        if($Access.AuthMode -eq 'Guest' -and $state.OnlineSettings.Enabled){throw 'Guest shares cannot be created while Online sharing is enabled.'}
        Invoke-LanHostAdapter $Adapter 'NewShare' @($Name, $sharePath, $Mode, $Access.AllowedSids, $true, $id) | Out-Null
        $shareCreated = $true
        $journal.Phase = 'SmbReady'
        Write-LanState -Path $StatePath -State $state
        Write-LanProgress -Message "สร้างแชร์สำเร็จ: \\$env:COMPUTERNAME\$Name"
        $credential = $null
        if ($Access.CredentialInfo) {
            $credential = [pscustomobject]@{
                UserName=$Access.CredentialInfo.UserName
                Sid=$Access.CredentialInfo.Sid
                PasswordCipher=(Protect-LanSecret -Text $Access.CredentialInfo.Password)
            }
        }
        $entry = [pscustomobject]@{
            Id=$id; Name=$Name; Kind=$Selection.Kind; SourcePath=$Selection.FullPath
            SharePath=$sharePath; VolumeRoot=$Selection.VolumeRoot; VolumeId=$Selection.VolumeId
            FileId=$(if($singleFile){$singleFile.FileId}else{$null})
            Mode=$Mode; AuthMode=$Access.AuthMode; AllowedSids=@($Access.AllowedSids); NtfsPolicy=$ntfsPolicy
            CredentialInfo=$credential; AutoStart=[bool]$AutoStart; Status='Running'
            AclRecords=@($journal.AclRecords); FirewallSnapshot=$journal.FirewallSnapshot
            SingleFile=$singleFile; NetworkProfile=$networkProfile
        }
        $state.Shares = @($state.Shares) + @($entry)
        $state.Journal = @($state.Journal | Where-Object { $_.Id -ne $id })
        Write-LanState -Path $StatePath -State $state
        if ($Access.CredentialInfo) {
            $entry | Add-Member -NotePropertyName InitialPassword -NotePropertyValue $Access.CredentialInfo.Password
        }
        return $entry
    } catch {
        $failure = $_
        if ($StateLock -and -not $StateLock.Value) {
            # Another writer owns state. Retain the durable journal for recovery;
            # never roll back or overwrite a stale snapshot without the lock.
            throw $failure
        }
        $errors = @()
        if ($shareCreated) {
            try { Invoke-LanHostAdapter $Adapter 'RemoveShare' @($Name) | Out-Null } catch { $errors += $_.Exception.Message }
        }
        if (@($journal.AclRecords).Count -gt 0) {
            try { Invoke-LanHostAdapter $Adapter 'RevokeAcl' @($journal.AclRecords) | Out-Null } catch { $errors += $_.Exception.Message }
        }
        if ($journal.FirewallSnapshot -and @($state.Shares).Count -eq 0 -and
            @($state.Journal | Where-Object { $_.Id -ne $id }).Count -eq 0) {
            try { Invoke-LanHostAdapter $Adapter 'RemoveFirewall' @($journal.FirewallSnapshot) | Out-Null } catch { $errors += $_.Exception.Message }
        }
        if ($singleFile) {
            try { Remove-LanSingleFileRoot -Entry $singleFile } catch { $errors += $_.Exception.Message }
        }
        $journal.ActiveProcessId = 0
        if ($errors.Count -eq 0) {
            $state.Journal = @($state.Journal | Where-Object { $_.Id -ne $id })
        }
        Write-LanState -Path $StatePath -State $state
        throw "Share activation failed: $($failure.Exception.Message). Cleanup: $($errors -join '; ')"
    } finally {
        [void]$script:LanHostActiveJournalIds.Remove($id)
        $transactionLease.ReleaseMutex()
        $transactionLease.Dispose()
    }
}

function Start-LanHostShare {
    param(
        [Parameter(Mandatory)]$Selection,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Read','Modify')][string]$Mode,
        [Parameter(Mandatory)]$Access,
        [bool]$AutoStart = $true,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][hashtable]$Adapter,
        # NTFS scanning and application run outside the state lock; only journal
        # updates hold it. A caller can allow a longer wait for those short writes.
        [int]$LockTimeoutMilliseconds = 30000
    )
    $parameters = $PSBoundParameters
    $timeout = if ($PSBoundParameters.ContainsKey('LockTimeoutMilliseconds')) { [int]$LockTimeoutMilliseconds } else { 30000 }
    # Pass the resolved timeout explicitly alongside the lock reference below.
    [void]$parameters.Remove('LockTimeoutMilliseconds')
    try {
        if ($Selection.Kind -eq 'File' -or $AutoStart) {
            Write-LanProgress -Message 'ตรวจว่า Host Worker พร้อมสำหรับแชร์อัตโนมัติ'
            Invoke-LanHostAdapter $Adapter 'EnsureWorker' | Out-Null
        }
        $stateLock = Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $timeout
        if ($Adapter.PrepareOnline) { $stateLock.Dispose(); $stateLock=$null; & $Adapter.PrepareOnline $StatePath $Adapter | Out-Null; $stateLock=Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $timeout }
        try { return Start-LanHostShareCore @parameters -StateLock ([ref]$stateLock) -LockTimeoutMilliseconds $timeout }
        finally { if ($stateLock) { $stateLock.Dispose() } }
    }
    catch {
        $failure = $_
        if ($Access.AuthMode -eq 'Protected' -and $Access.CredentialInfo) {
            try {
                # A failed second share must not delete the account of the first one.
                # If state cannot be read, retain the account rather than risk disconnecting users.
                $accountState = Read-LanState -Path $StatePath
                $inUse = @($accountState.Shares | Where-Object {
                    $_.CredentialInfo.UserName -eq $Access.CredentialInfo.UserName
                }).Count -gt 0 -or @($accountState.Journal | Where-Object {
                    $_.AccountName -eq $Access.CredentialInfo.UserName
                }).Count -gt 0
                if (-not $inUse) {
                    Invoke-LanHostAdapter $Adapter 'DisableProtected' @($Access.CredentialInfo.UserName) | Out-Null
                }
            }
            catch { throw "Share failed: $($failure.Exception.Message). Account cleanup also failed: $($_.Exception.Message)" }
        }
        throw $failure
    }
}

function Stop-LanHostShareCore {
    param([Parameter(Mandatory)][string]$Id,
          [Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter,
          # Cleanup during setup or uninstall must always finish. When the name was taken over by
          # a share this app does not own, the foreign share is left alone and only our own
          # record, NTFS rights and firewall rule are undone. The window never passes this, so a
          # manual stop still refuses to touch a share it does not own.
          [switch]$ReleaseUnownedName)
    $state = Read-LanState -Path $StatePath
    $entry = @($state.Shares | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $entry) { throw "App share not found: $Id" }
    $entry.AutoStart = $false
    $entry.Status = 'Stopping'
    Write-LanState -Path $StatePath -State $state
    # Once the network share is gone the share is stopped, and that has to be recorded even if the cleanup
    # after it fails.
    #
    # The status "Stopping" was written first and the record was removed last, so any failure in between —
    # an ACL that could not be revoked, an account that could not be removed — left the record behind with
    # that status for good. A share stuck at "Stopping" then blocked the next install and uninstall, because
    # the leftover record described a share that no longer existed. Each cleanup step now reports its own
    # failure and the record is removed as soon as the share is off the network.
    $cleanupErrors = New-Object System.Collections.Generic.List[string]
    $actual = Invoke-LanHostAdapter $Adapter 'GetShare' @($entry.Name)
    if ($actual) {
        if (-not (Test-LanOwnedShare -Actual $actual -Path $entry.SharePath -Id $entry.Id)) {
            if (-not $ReleaseUnownedName) { throw "Share name now belongs to another share: $($entry.Name)" }
            $entry | Add-Member -NotePropertyName LastError -NotePropertyValue 'The share name is used by a share this app does not own; it was left in place.' -Force
        } else {
            Invoke-LanHostAdapter $Adapter 'RemoveShare' @($entry.Name) | Out-Null
        }
    }
    if (@($entry.AclRecords).Count -gt 0) {
        try { Invoke-LanHostAdapter $Adapter 'RevokeAcl' @($entry.AclRecords) | Out-Null }
        catch { [void]$cleanupErrors.Add("คืนสิทธิ์ NTFS ไม่สำเร็จ: $($_.Exception.Message)") }
    }
    if ($entry.SingleFile) {
        try { Remove-LanSingleFileRoot -Entry $entry.SingleFile }
        catch { [void]$cleanupErrors.Add("ลบโฟลเดอร์ไฟล์เดียวไม่สำเร็จ: $($_.Exception.Message)") }
    }
    # The share is off the network, so it is no longer a share: the record goes now, and the steps that remain
    # cannot put it back.
    $state.Shares = @($state.Shares | Where-Object { $_.Id -ne $Id })
    Write-LanState -Path $StatePath -State $state
    if (@($state.Shares).Count -eq 0 -and @($state.Journal).Count -eq 0 -and $entry.FirewallSnapshot) {
        try { Invoke-LanHostAdapter $Adapter 'RemoveFirewall' @($entry.FirewallSnapshot) | Out-Null }
        catch { [void]$cleanupErrors.Add("คืนกฎ Firewall ไม่สำเร็จ: $($_.Exception.Message)") }
    }
    if ($entry.AuthMode -eq 'Protected' -and $entry.CredentialInfo -and
        @($state.Shares | Where-Object { $_.CredentialInfo.UserName -eq $entry.CredentialInfo.UserName }).Count -eq 0 -and
        @($state.Journal | Where-Object { $_.AccountName -eq $entry.CredentialInfo.UserName }).Count -eq 0) {
        try { Invoke-LanHostAdapter $Adapter 'DisableProtected' @($entry.CredentialInfo.UserName) | Out-Null }
        catch { [void]$cleanupErrors.Add("ลบบัญชีแชร์ไม่สำเร็จ: $($_.Exception.Message)") }
    }
    if ($entry.AuthMode -eq 'Guest' -and @($state.Shares | Where-Object { $_.AuthMode -eq 'Guest' }).Count -eq 0) {
        $restoredGuest = Restore-LanGuestConfigurationCore -Role Host -Adapter $Adapter -StatePath $StatePath
        if (@($restoredGuest.Skipped).Count -gt 0) { throw 'Guest account was changed outside this app; its recovery snapshot was retained.' }
    }
    # The stop itself succeeded, so a cleanup failure is reported rather than thrown: throwing would leave the
    # caller believing the share is still running when it is not.
    if ($cleanupErrors.Count -gt 0) {
        Write-LanProgress -Message ("หยุดแชร์แล้ว แต่ทำความสะอาดไม่ครบ: " + ($cleanupErrors -join ' / '))
    }
    return [pscustomobject]@{ Id=$Id; Stopped=$true; CleanupErrors=@($cleanupErrors) }
}

function Stop-LanHostShare {
    param([Parameter(Mandatory)][string]$Id,
          [Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [switch]$ReleaseUnownedName,
          [int]$LockTimeoutMilliseconds = 30000)
    $parameters = @{} + $PSBoundParameters
    [void]$parameters.Remove('LockTimeoutMilliseconds')
    $stateLock = Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds
    try { return Stop-LanHostShareCore @parameters }
    finally { $stateLock.Dispose() }
}

function Repair-LanHostStateCore {
    param([Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $state = Read-LanState -Path $StatePath
    $shareCount = @($state.Shares).Count
    $remaining = @(); $repaired = @(); $resolved = @()
    foreach ($item in @($state.Journal)) {
        if (Test-LanActiveJournal -Journal $item) { $remaining += $item; continue }
        try {
            $actual = Invoke-LanHostAdapter $Adapter 'GetShare' @($item.Name)
            $conflict = $false
            if ($actual) {
                if (Test-LanOwnedShare -Actual $actual -Path $item.SharePath -Id $item.Id) {
                    Invoke-LanHostAdapter $Adapter 'RemoveShare' @($item.Name) | Out-Null
                } elseif (Test-LanManagedShare -Actual $actual) {
                    # The name is held by this application's own share from another install or an
                    # older state file. It is ours, so removing it is what the interrupted setup
                    # was trying to do anyway.
                    Invoke-LanHostAdapter $Adapter 'RemoveShare' @($item.Name) | Out-Null
                } else {
                    # The name now belongs to a share this application does not own. Removing it
                    # would delete someone else's share, and waiting will never clear it, so the
                    # unfinished bookkeeping is dropped and only our own changes are undone.
                    $conflict = $true
                }
            }
            # NTFS rights and the single-file root are always restored, even for a conflicting
            # name: they are this application's changes, and revocation is idempotent.
            if (@($item.AclRecords).Count -gt 0) { Invoke-LanHostAdapter $Adapter 'RevokeAcl' @($item.AclRecords) | Out-Null }
            if ($item.SingleFile) { Remove-LanSingleFileRoot -Entry $item.SingleFile }
            # The firewall snapshot stores the rules that existed before this application added
            # its own, so it is only restored when no app share is left that needs them.
            $otherActive = @($state.Journal | Where-Object { $_.Id -ne $item.Id -and (Test-LanActiveJournal -Journal $_) }).Count -gt 0
            if ($item.FirewallSnapshot -and $shareCount -eq 0 -and -not $otherActive) {
                Invoke-LanHostAdapter $Adapter 'RemoveFirewall' @($item.FirewallSnapshot) | Out-Null
            }
            if ($conflict) {
                $item | Add-Member -NotePropertyName Resolution -NotePropertyValue 'Share name taken over by a share this app does not own; the entry was released.' -Force
                $resolved += $item
            } else { $repaired += $item.Id }
        } catch {
            # Keep the entry for recovery but record the concrete blocker so the installer
            # can report what actually still needs attention.
            $item | Add-Member -NotePropertyName FailureReason -NotePropertyValue $_.Exception.Message -Force
            $remaining += $item
        }
    }
    $state.Journal = @($remaining)
    Write-LanState -Path $StatePath -State $state
    return [pscustomobject]@{ Repaired=@($repaired); Pending=@($remaining); Resolved=@($resolved) }
}

function Repair-LanHostState {
    param([Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $parameters = $PSBoundParameters
    $stateLock = Enter-LanStateLock -StatePath $StatePath
    try { return Repair-LanHostStateCore @parameters }
    finally { $stateLock.Dispose() }
}

function Get-LanLocalUserSidPrefix {
    param([Parameter(Mandatory)][string[]]$Sids)
    $prefix = $null
    foreach ($sidText in $Sids) {
        try {
            $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
            if ($sid.Value -notmatch '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { return $null }
            $userPrefix = $Matches[1]
            $user = Get-LocalUser -SID $sid -ErrorAction Stop
            if (-not $user -or $user.SID.Value -ne $sid.Value) { return $null }
        } catch { return $null }
        if ($prefix -and $prefix -ne $userPrefix) { return $null }
        $prefix = $userPrefix
    }
    return $prefix
}

function Assert-LanNoDenyAcl {
    param([Parameter(Mandatory)]$Acl,
          [Parameter(Mandatory)][string]$Path,
          [string]$LocalUserSidPrefix,
          [ValidateSet('Read','Modify')][string]$Mode = 'Read',
          [switch]$IgnoreOrphanedDeny)
    # Only a Deny that covers a right this share hands out can actually block access. Real
    # folders (for example anything under OneDrive) carry inherited Deny entries such as
    # "Delete subfolders and files" for Everyone, which never prevents reading, writing or
    # modifying files, so refusing the share for those would block working folders.
    $granted = if ($Mode -eq 'Read') {
        [Security.AccessControl.FileSystemRights]'ReadData, ReadAttributes, ReadExtendedAttributes, ReadPermissions, ExecuteFile, Synchronize'
    } else {
        [Security.AccessControl.FileSystemRights]'ReadData, ReadAttributes, ReadExtendedAttributes, ReadPermissions, ExecuteFile, Synchronize, WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete'
    }
    foreach ($ace in @($Acl.Access)) {
        if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Deny) { continue }
        if (($ace.FileSystemRights -band $granted) -eq 0) { continue }
        # An entry that only applies to descendants does not deny access to this object itself.
        if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($IgnoreOrphanedDeny) {
            try {
                $deniedSid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier])
                [void]$deniedSid.Translate([Security.Principal.NTAccount])
            } catch [Security.Principal.IdentityNotMappedException] {
                # A deleted account cannot authenticate; leave its Deny ACE untouched.
                continue
            }
        }
        if ($LocalUserSidPrefix) {
            try {
                $deniedSid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                # A verified local user cannot be a principal from another account domain.
                if ($deniedSid -match '^(S-1-5-21-\d+-\d+-\d+)-\d+$' -and
                    $Matches[1] -ne $LocalUserSidPrefix) { continue }
            } catch { }
        }
        throw "Deny ACE prevents verified access throughout the share: $Path"
    }
}

function Get-LanNtfsAccess {
    param([Parameter(Mandatory)][string]$Path)
    # Request only the DACL. Avoid provider/name translation overhead for every
    # file in a drive-sized walk, while retaining the full access checks.
    $sections = [Security.AccessControl.AccessControlSections]::Access
    if ([IO.Directory]::Exists($Path)) { return [IO.Directory]::GetAccessControl($Path,$sections) }
    return [IO.File]::GetAccessControl($Path,$sections)
}

function Set-LanNtfsAccess {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Acl)
    # Only the DACL belongs to this operation. A descriptor obtained from the
    # PowerShell provider may also carry owner/audit state; persisting it can
    # require SeSecurityPrivilege even though only file access was changed.
    $access = $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    if ([IO.Directory]::Exists($Path)) {
        $clean = New-Object Security.AccessControl.DirectorySecurity
        $clean.SetSecurityDescriptorSddlForm($access,[Security.AccessControl.AccessControlSections]::Access)
        [IO.Directory]::SetAccessControl($Path,$clean)
    } else {
        $clean = New-Object Security.AccessControl.FileSecurity
        $clean.SetSecurityDescriptorSddlForm($access,[Security.AccessControl.AccessControlSections]::Access)
        [IO.File]::SetAccessControl($Path,$clean)
    }
}

function Test-LanNtfsAclEquivalent {
    param([string]$Expected,[string]$Actual)
    if ($Expected -ceq $Actual) { return $true }
    try {
        $left=[Security.AccessControl.RawSecurityDescriptor]::new($Expected)
        $right=[Security.AccessControl.RawSecurityDescriptor]::new($Actual)
        $protected=[Security.AccessControl.ControlFlags]::DiscretionaryAclProtected
        if (($left.ControlFlags -band $protected) -ne ($right.ControlFlags -band $protected)) { return $false }
        if ($null -eq $left.DiscretionaryAcl -or $null -eq $right.DiscretionaryAcl) { return $false }
        $lists=@();$onlyAllow=$true
        foreach($descriptor in @($left,$right)) {
            $keys=[Collections.Generic.List[string]]::new()
            foreach($ace in $descriptor.DiscretionaryAcl) {
                # Unsupported/object/callback ACEs require an exact descriptor.
                if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) { return $false }
                if ($ace.AceQualifier -notin @([Security.AccessControl.AceQualifier]::AccessAllowed,[Security.AccessControl.AceQualifier]::AccessDenied)) { return $false }
                if ($ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed) { $onlyAllow=$false }
                $mask=ConvertTo-LanSpecificAclMask -Mask $ace.AccessMask
                # Keep every flag, including IsInherited, and duplicate counts.
                $keys.Add(('{0}|{1}|{2}|{3}' -f $ace.SecurityIdentifier.Value,$mask,[int]$ace.AceFlags,$ace.AceQualifier))
            }
            $lists+=,@($keys.ToArray())
        }
        if ($onlyAllow) {
            foreach($list in $lists){[Array]::Sort($list,[StringComparer]::Ordinal)}
        }
        # Only Allow-only ordering and generic mask spelling may differ. A Deny
        # must retain its exact position so evaluation precedence cannot change.
        return (($lists[0] -join ';') -ceq ($lists[1] -join ';'))
    } catch { return $false }
}

function Grant-LanNtfsAcl {
    param([Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)][string[]]$Sids,
          [Parameter(Mandatory)][ValidateSet('Read','Modify')][string]$Mode,
          [scriptblock]$BeforeApply,
          [ValidateSet('Drive','Folder','File')][string]$Kind = 'Folder')
    # Never propagate a new ACE over the Windows system volume. Share permissions still
    # apply, while each file and folder retains its existing NTFS access restrictions.
    if (Test-LanSystemDriveRoot -Path $Path -Kind $Kind) { return @() }
    $records = @()
    $items = @($Path)
    $localUserSidPrefix = Get-LanLocalUserSidPrefix -Sids $Sids
    $ignoreOrphanedDeny = $Sids -contains 'S-1-5-11'
    Assert-LanNoDenyAcl -Acl (Get-LanNtfsAccess -Path $Path) -Path $Path -LocalUserSidPrefix $localUserSidPrefix -Mode $Mode -IgnoreOrphanedDeny:$ignoreOrphanedDeny
    if ([IO.Directory]::Exists($Path)) {
        Write-LanProgress -Message "สำรวจโฟลเดอร์ย่อยใน $Path"
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($Path)
        $scanned = 0
        $throttle = New-LanProgressThrottle
        # The walk is the longest phase of a large share, and it used to update only the status
        # file. The window reads its log file, so the pane showed nothing at all for the whole
        # walk — minutes of silence exactly when the user most needs to see progress.
        $lastLogged = 0
        $logWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($pending.Count -gt 0) {
            $folder = $pending.Pop()
            # A subtree this account cannot list keeps its existing permissions, exactly like a
            # linked directory: the share is still created instead of failing on a system folder.
            try { $children = @(([IO.DirectoryInfo]::new($folder)).GetFileSystemInfos()) }
            catch [IO.IOException] { continue }
            catch [UnauthorizedAccessException] { continue }
            catch [Security.SecurityException] { continue }
            foreach ($item in $children) {
                $scanned++
                if (Test-LanProgressDue -Throttle $throttle) {
                    # The status drives the counter under the window, the log drives the progress
                    # pane. This step used to update only the status, which is why a whole-drive
                    # walk showed no new log line for minutes.
                    Set-LanProgress -Message "สำรวจโฟลเดอร์ย่อยแล้ว $scanned รายการ" -Current $scanned
                }
                # Log far less often than the status is updated: a drive-sized walk would otherwise
                # write one line per 25 items. Every 2000 items or 15 seconds proves the program is
                # moving without drowning the pane. The current folder is included so that a path
                # this app cannot handle can be found from the log alone.
                if (($scanned - $lastLogged) -ge 2000 -or $logWatch.Elapsed.TotalSeconds -ge 15) {
                    $lastLogged = $scanned
                    $logWatch.Restart()
                    Add-LanProgressLog -Message "สำรวจโฟลเดอร์ย่อยแล้ว $scanned รายการ — กำลังตรวจ: $(Split-Path -Leaf $folder)"
                }
                # Prune the whole Windows-owned container: never record it and never descend
                # into it, so no record can outlive a change Windows makes on its own.
                if (Test-LanDriveMetadataChild -SharePath $Path -Folder $folder -Item $item -Kind $Kind) { continue }
                # A linked directory is left exactly as it is. Its target may sit outside the
                # share, and OneDrive placeholders must keep the attribute Windows gave them.
                if (Test-LanReparseDirectory -Item $item) { continue }
                if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($item.FullName) }
                $childAcl = Get-LanNtfsAccess -Path $item.FullName
                Assert-LanNoDenyAcl -Acl $childAcl -Path $item.FullName -LocalUserSidPrefix $localUserSidPrefix -Mode $Mode -IgnoreOrphanedDeny:$ignoreOrphanedDeny
                if ($childAcl.AreAccessRulesProtected) { $items += $item.FullName }
            }
        }
        Write-LanProgress -Message "สำรวจเสร็จ: ต้องตั้งสิทธิ์ $($items.Count) รายการ (จาก $scanned รายการ)"
    }
    # A Windows-owned container must not receive an ACE even when it is the selected root.
    if ($items.Count -eq 1 -and (Get-LanCanonicalPath $Path) -match '(?i)\\(System Volume Information|\$RECYCLE\.BIN)$') {
        return @()
    }
    try {
        $grantedCount = 0
        $total = $items.Count
        $applyThrottle = New-LanProgressThrottle
        foreach ($itemPath in $items) {
            $grantedCount++
            if (Test-LanProgressDue -Throttle $applyThrottle -Interval 10 -Seconds 2) {
                # The folder being changed is the useful detail here: it shows real movement.
                Set-LanProgress -Message "กำลังตั้งสิทธิ์ NTFS: $(Split-Path -Leaf $itemPath)" -Current $grantedCount -Total $total
            }
            $acl = Get-LanNtfsAccess -Path $itemPath
            Assert-LanNoDenyAcl -Acl $acl -Path $itemPath -LocalUserSidPrefix $localUserSidPrefix -Mode $Mode -IgnoreOrphanedDeny:$ignoreOrphanedDeny
            $before = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            $isFolder = [IO.Directory]::Exists($itemPath)
            $inheritance = if ($isFolder) {
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            } else { [Security.AccessControl.InheritanceFlags]::None }
            $rights = if ($Mode -eq 'Read') {
                [Security.AccessControl.FileSystemRights]::ReadAndExecute
            } else { [Security.AccessControl.FileSystemRights]::Modify }
            foreach ($sidText in $Sids) {
                $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
                $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                    $sid, $rights, $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow)
                $acl.AddAccessRule($rule)
            }
            $after = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            $record = [pscustomobject]@{ Path=$itemPath; Before=$before; After=$after }
            # Track the current intention too: a write that fails verification
            # can still have applied part/all of our grant and needs rollback.
            $records += $record
            for($attempt=1;$attempt -le 3;$attempt++) {
                if ($BeforeApply) { & $BeforeApply $record | Out-Null }
                try { Set-LanNtfsAccess -Path $itemPath -Acl $acl }
                catch { throw "Cannot set NTFS permissions on '$itemPath': $($_.Exception.Message)" }
                $live=Get-LanNtfsAccess -Path $itemPath
                $applied=$live.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
                if (Test-LanNtfsAclEquivalent -Expected $record.After -Actual $applied) {
                    if ($applied -cne $record.After) { Write-LanProgress -Message "Windows จัดรูปแบบ ACL ใหม่ ตรวจแล้วสิทธิ์ตรงกัน: $itemPath" }
                    break
                }
                # Reapply only when the previous write did not stick. Never
                # overwrite unrelated permission/protection changes or Deny.
                if (-not (Test-LanNtfsAclEquivalent -Expected $before -Actual $applied)) {
                    throw "NTFS permissions changed during activation; automatic overwrite refused: $itemPath"
                }
                if ($attempt -eq 3) { throw "NTFS grant could not be verified after 3 automatic attempts: $itemPath" }
                Write-LanProgress -Message "สิทธิ์ยังไม่ติด กำลังแก้อัตโนมัติครั้งที่ $($attempt+1)/3: $itemPath"
                Start-Sleep -Milliseconds (100*$attempt)
                $acl=Get-LanNtfsAccess -Path $itemPath
                $fresh=$acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
                if (-not (Test-LanNtfsAclEquivalent -Expected $before -Actual $fresh)) { throw "NTFS permissions changed before automatic retry: $itemPath" }
                Assert-LanNoDenyAcl -Acl $acl -Path $itemPath -LocalUserSidPrefix $localUserSidPrefix -Mode $Mode -IgnoreOrphanedDeny:$ignoreOrphanedDeny
                foreach($sidText in $Sids) {
                    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidText),$rights,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
                    $acl.AddAccessRule($rule)
                }
                $record.After=$acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            }
        }
    } catch {
        if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records }
        throw
    }
    return $records
}

function ConvertTo-LanSpecificAclMask {
    param([int]$Mask)
    # A recorded security descriptor can hold generic access bits (GENERIC_READ/WRITE/EXECUTE/
    # ALL). FileSystemRights has no members for them, and .NET refuses to build a
    # FileSystemAccessRule from a mask it cannot represent, so the bits are translated to the
    # specific rights they stand for before any enum conversion. Without this an interrupted
    # setup that recorded a generic mask could not be undone, which blocked setup and uninstall.
    # Every constant is cast to [int]: literals above 0x7FFFFFFF are Int64 otherwise, and mixing
    # them into the bitwise operators fails with "Argument types do not match".
    [int]$genericRead = [int]0x80000000
    [int]$genericWrite = [int]0x40000000
    [int]$genericExecute = [int]0x20000000
    [int]$genericAll = [int]0x10000000
    [int]$genericBits = [int]0xF0000000
    [int]$specificAll = 0x001F01FF
    [int]$specificRead = 0x00120089
    [int]$specificWrite = 0x00120116
    [int]$specificExecute = 0x001200A0
    if (($Mask -band $genericAll) -ne 0) { return ($specificAll -bor ($Mask -band (-bnot $genericBits))) }
    # Drop the generic bits, then add the specific rights the generic bits stand for.
    [int]$result = $Mask -band (-bnot $genericBits)
    if (($Mask -band $genericRead) -ne 0) { $result = $result -bor $specificRead }
    if (($Mask -band $genericWrite) -ne 0) { $result = $result -bor $specificWrite }
    if (($Mask -band $genericExecute) -ne 0) { $result = $result -bor $specificExecute }
    return $result
}

function Get-LanAclPrincipalSid {
    param([Parameter(Mandatory)]$IdentityReference)
    # Live ACLs and SDDL-parsed ACLs report the same principal differently (account name
    # versus SID string), so both forms are normalized to a SID before comparison.
    $value = [string]$IdentityReference.Value
    if ($value -match '^S-\d-\d+(-\d+)+$') { return $value }
    try { return $IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return $value }
}

function Get-LanAclRuleKey {
    param([Parameter(Mandatory)]$Rule)
    # A canonical identity for one ACE: principal, access mask, inheritance bits and type.
    # FileSystemAccessRule.Equals compares references, so keys are compared as strings.
    $aceFlags = 0
    if ($Rule.InheritanceFlags.HasFlag([Security.AccessControl.InheritanceFlags]::ObjectInherit)) { $aceFlags = $aceFlags -bor 1 }
    if ($Rule.InheritanceFlags.HasFlag([Security.AccessControl.InheritanceFlags]::ContainerInherit)) { $aceFlags = $aceFlags -bor 2 }
    if ($Rule.PropagationFlags.HasFlag([Security.AccessControl.PropagationFlags]::InheritOnly)) { $aceFlags = $aceFlags -bor 4 }
    if ($Rule.PropagationFlags.HasFlag([Security.AccessControl.PropagationFlags]::NoPropagateInherit)) { $aceFlags = $aceFlags -bor 8 }
    return ('{0}|{1}|{2}|{3}' -f (Get-LanAclPrincipalSid -IdentityReference $Rule.IdentityReference),
        (ConvertTo-LanSpecificAclMask -Mask ([int]$Rule.FileSystemRights)),$aceFlags,$Rule.AccessControlType)
}

function Get-LanAclRules {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Sddl)
    # Materializes the access rules of a recorded security descriptor so recovery can match
    # them against a live ACL without depending on reference equality.
    # A List is returned because PowerShell unwraps a bare array and would turn an empty
    # result into a single $null element for the caller.
    $rules = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Sddl)) { return $rules }
    $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($Sddl)
    foreach ($ace in @($descriptor.DiscretionaryAcl)) {
        if ($ace -isnot [Security.AccessControl.CommonAce]) { continue }
        $flags = $ace.AceFlags
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
        if ($flags.HasFlag([Security.AccessControl.AceFlags]::ObjectInherit)) {
            $inheritance = $inheritance -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        }
        if ($flags.HasFlag([Security.AccessControl.AceFlags]::ContainerInherit)) {
            $inheritance = $inheritance -bor [Security.AccessControl.InheritanceFlags]::ContainerInherit
        }
        $propagation = [Security.AccessControl.PropagationFlags]::None
        if ($flags.HasFlag([Security.AccessControl.AceFlags]::NoPropagateInherit)) {
            $propagation = $propagation -bor [Security.AccessControl.PropagationFlags]::NoPropagateInherit
        }
        $rights = [Security.AccessControl.FileSystemRights](ConvertTo-LanSpecificAclMask -Mask ([int]$ace.AccessMask))
        # AceType (AccessAllowed/AccessDenied) and AccessControlType (Allow/Deny) are different
        # enums with the same numeric values, and the FileSystemAccessRule constructor insists on
        # the latter. Passing AceType directly made .NET throw "Argument types do not match", which
        # aborted the whole comparison and surfaced as "NTFS permissions changed after activation".
        $ruleType = [Security.AccessControl.AccessControlType][int]$ace.AceType
        $rules.Add((New-Object Security.AccessControl.FileSystemAccessRule(
            $ace.SecurityIdentifier,$rights,$inheritance,$propagation,$ruleType)))
    }
    # PowerShell returns a bare collection by unwrapping it, which would turn the empty case
    # into a $null element, so the rules travel inside a single wrapper object.
    return [pscustomobject]@{ Rules = $rules }
}

function Get-LanAccessRuleDelta {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Before,
          [Parameter(Mandatory)][AllowEmptyString()][string]$After)
    # Returns exactly the rules this app added, so recovery can undo its own change without
    # discarding permission changes the owner made afterwards.
    $beforeKeys = @((Get-LanAclRules -Sddl $Before).Rules | ForEach-Object { Get-LanAclRuleKey -Rule $_ })
    $added = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rule in (Get-LanAclRules -Sddl $After).Rules) {
        if ($beforeKeys -notcontains (Get-LanAclRuleKey -Rule $rule)) { $added.Add($rule) }
    }
    return [pscustomobject]@{ Rules = $added }
}

function Test-LanAclHoldsNoAppGrant {
    param([Parameter(Mandatory)]$Acl,
          [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AddedRules)
    if (@($AddedRules).Count -eq 0) { return $true }
    $addedKeys = @($AddedRules | ForEach-Object { Get-LanAclRuleKey -Rule $_ })
    foreach ($rule in @($Acl.Access)) {
        if ($addedKeys -contains (Get-LanAclRuleKey -Rule $rule)) { return $false }
    }
    return $true
}

function Remove-LanAppAclEntries {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$AddedRules,[string]$BaselineSddl)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $addedKeys = @($AddedRules | ForEach-Object { Get-LanAclRuleKey -Rule $_ })
    $baselineRules=@()
    if($BaselineSddl) {
        $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($BaselineSddl)
        foreach($ace in $descriptor.DiscretionaryAcl) {
            if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or
               ([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) -or
               $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed){continue}
            $single=[Security.AccessControl.RawAcl]::new([byte]2,1);$single.InsertAce(0,$ace)
            $sd=[Security.AccessControl.RawSecurityDescriptor]::new([Security.AccessControl.ControlFlags]::DiscretionaryAclPresent,$null,$null,$null,$single)
            $parsed=Get-LanAclRules ($sd.GetSddlForm('Access'))
            foreach($original in $parsed.Rules){$baselineRules+=,$original}
        }
    }
    $restore=[Collections.Generic.List[object]]::new()
    foreach ($rule in @($acl.Access)) {
        if (-not $rule.IsInherited -and $addedKeys -contains (Get-LanAclRuleKey -Rule $rule)) {
            $acl.RemoveAccessRuleSpecific($rule)
            # AddAccessRule can merge our new rights with an existing explicit
            # grant. Removing the merged ACE must not remove its original rights.
            foreach($original in $baselineRules){
                if((Get-LanAclPrincipalSid $original.IdentityReference) -eq (Get-LanAclPrincipalSid $rule.IdentityReference) -and
                   $original.InheritanceFlags -eq $rule.InheritanceFlags -and $original.PropagationFlags -eq $rule.PropagationFlags -and
                   $original.AccessControlType -eq $rule.AccessControlType){$restore.Add($original)}
            }
        }
    }
    foreach($original in $restore){$acl.AddAccessRule($original)}
    Set-LanNtfsAccess -Path $Path -Acl $acl
}

function Revoke-LanNtfsAcl {
    param([Parameter(Mandatory)][object[]]$Records)
    # Restoring thousands of entries one at a time takes minutes, and this loop used to report
    # nothing at all. The window showed a single "starting" line for the whole stop, which reads as
    # a frozen program; report the count as the work proceeds.
    $total = $Records.Count
    $done = 0
    $progressThrottle = New-LanProgressThrottle
    for ($i=$Records.Count-1; $i -ge 0; $i--) {
        $record = $Records[$i]
        $done++
        if (Test-LanProgressDue -Throttle $progressThrottle -Interval 200 -Seconds 3) {
            Set-LanProgress -Message "คืนสิทธิ์ NTFS แล้ว $done จาก $total รายการ" -Current $done -Total $total
            Add-LanProgressLog -Message "คืนสิทธิ์ NTFS แล้ว $done จาก $total รายการ"
        }
        # A vanished path cannot still carry this app's grant: the record is already satisfied.
        if (-not (Test-Path -LiteralPath $record.Path)) { continue }
        $acl = Get-Acl -LiteralPath $record.Path -ErrorAction Stop
        $current = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        if (Test-LanNtfsAclEquivalent -Expected $record.Before -Actual $current) { continue }
        $added = (Get-LanAccessRuleDelta -Before ([string]$record.Before) -After ([string]$record.After)).Rules
        if (Test-LanNtfsAclEquivalent -Expected $record.After -Actual $current) {
            $acl.SetSecurityDescriptorSddlForm($record.Before, [Security.AccessControl.AccessControlSections]::Access)
            Set-LanNtfsAccess -Path $record.Path -Acl $acl
            continue
        }
        # The ACL moved after activation. Undo only this app's own entries and keep the
        # rest, instead of demanding a manual repair for an unrelated permission change.
        if (Test-LanAclHoldsNoAppGrant -Acl $acl -AddedRules $added) { continue }
        Remove-LanAppAclEntries -Path $record.Path -AddedRules $added -BaselineSddl ([string]$record.Before)
        $resolvedAcl = Get-Acl -LiteralPath $record.Path -ErrorAction Stop
        $resolved = $resolvedAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $matchesBefore = Test-LanNtfsAclEquivalent -Expected $record.Before -Actual $resolved
        $holdsNoGrant = Test-LanAclHoldsNoAppGrant -Acl $resolvedAcl -AddedRules $added
        if (-not $matchesBefore -and -not $holdsNoGrant) {
            throw "ACL changed outside this app; manual cleanup required: $($record.Path)"
        }
    }
}

function Resolve-LanSmbAccountNames {
    param([Parameter(Mandatory)][string[]]$Sids)
    $accounts = @()
    foreach ($sidText in $Sids) {
        try {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
            $account = $sid.Translate([Security.Principal.NTAccount]).Value
            $roundTrip = ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
            if ($roundTrip -ne $sid.Value) { throw 'Account now resolves to a different SID.' }
        } catch {
            throw "Cannot resolve SMB account SID $sidText to a Windows account: $($_.Exception.Message)"
        }
        $accounts += $account
    }
    return $accounts
}

function Test-LanFirewallRuleOwned {
    param([Parameter(Mandatory)]$Rule,[Parameter(Mandatory)]$PortFilter)
    # NetSecurity returns CIM enum values differently across Windows/PowerShell versions. On the
    # user's Windows 11 machine exposes GpoBoolean False=2, Profile Private=2, Inbound=1 and Allow=2;
    # other callers expose their names. Compare both representations, then verify the TCP/445
    # filter so an unrelated rule cannot be accepted merely because it copied our description.
    $direction=[string]$Rule.Direction
    $action=[string]$Rule.Action
    $protocol=[string]$PortFilter.Protocol
    return (
        [string]$Rule.Name -ceq 'LFS-Private-SMB' -and
        [string]$Rule.DisplayName -ceq 'LAN File Sharing SMB Private' -and
        [string]$Rule.Description -ceq 'Created by LAN File Sharing' -and
        $direction -in @('Inbound','1') -and
        $action -in @('Allow','2') -and
        $protocol -in @('TCP','6') -and
        [string]$PortFilter.LocalPort -ceq '445'
    )
}

function Test-LanFirewallRuleMatches {
    param([Parameter(Mandatory)]$Rule,[Parameter(Mandatory)]$PortFilter)
    if (-not (Test-LanFirewallRuleOwned -Rule $Rule -PortFilter $PortFilter)) { return $false }
    # GpoBoolean is 1=True and 2=False; Profile Private is bit 2. Some PowerShell versions
    # stringify these as names, others expose the numeric CIM values.
    return ([string]$Rule.Enabled -in @('True','1') -and [string]$Rule.Profile -in @('Private','2'))
}

function Get-LanFirewallRulePlan {
    param($Rules,$PortFilters)
    $rules=@($Rules);$ports=@($PortFilters)
    if ($rules.Count -eq 0) { return 'Create' }
    if ($rules.Count -ne 1 -or $ports.Count -ne 1 -or
        -not (Test-LanFirewallRuleOwned -Rule $rules[0] -PortFilter $ports[0])) { return 'Conflict' }
    if (Test-LanFirewallRuleMatches -Rule $rules[0] -PortFilter $ports[0]) { return 'Ready' }
    return 'Repair'
}

function New-LanHostAdapter {
    return @{
        GetShareAccess={param($name) @(Get-SmbShareAccess -Name $name -ErrorAction Stop)}
        GetProtectedAccount={param($name) Get-LocalUser -Name $name -ErrorAction Stop}
        RemoveOnlineFirewall={ Remove-LanOnlineFirewall }
        PrepareOnline={param($statePath,$hostAdapter) $hostAdapter.OnlineContext=Get-LanShareOnlineContext -StatePath $statePath}
        GetBlankPasswordPolicy = {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            $present = $item.PSObject.Properties.Name -contains 'LimitBlankPasswordUse'
            return [pscustomobject]@{Present=$present;Value=$(if($present){[int]$item.LimitBlankPasswordUse}else{1})}
        }
        SetBlankPasswordPolicy = {
            param($present,$value)
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            if ($present) { New-ItemProperty -LiteralPath $key -Name 'LimitBlankPasswordUse' -Value ([int]$value) -PropertyType DWord -Force -ErrorAction Stop | Out-Null }
            else { Remove-ItemProperty -LiteralPath $key -Name 'LimitBlankPasswordUse' -ErrorAction Stop }
        }
        GetProfile = {
            $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
            if ($profiles.Count -eq 0 -or @($profiles | Where-Object { $_.NetworkCategory -eq 'Public' }).Count -gt 0) { return 'Public' }
            if (@($profiles | Where-Object { $_.NetworkCategory -eq 'Private' }).Count -gt 0) { return 'Private' }
            return 'DomainAuthenticated'
        }
        GetNetworkProfiles = { @(Get-NetConnectionProfile -ErrorAction Stop) }
        SetNetworkProfile = {
            param($index)
            Set-NetConnectionProfile -InterfaceIndex ([uint32]$index) -NetworkCategory Private -ErrorAction Stop
        }
        GetShare = {
            param($name)
            return Get-SmbShare -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        EnsureWorker = {
            $heartbeat = Join-Path (Join-Path $env:ProgramData 'LanFileSharing') 'worker.heartbeat'
            if (Test-LanWorkerHeartbeat -Path $heartbeat) { return }
            $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostWorker'
            if (-not $task) { throw 'File monitor worker is not installed.' }
            if ($task.State -ne 'Running') {
                Start-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -ErrorAction Stop
            }
            # Poll the heartbeat file rather than the task: reading a scheduled task costs
            # seconds on some machines and would make a short readiness wait very slow.
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while ($watch.ElapsedMilliseconds -lt 15000) {
                if (Test-LanWorkerHeartbeat -Path $heartbeat) { return }
                Start-Sleep -Milliseconds 250
            }
            throw 'File monitor worker is not ready.'
        }
        EnableFirewall = {
            param($hostAdapter)
            $rule = @(Get-NetFirewallRule -Name 'LFS-Private-SMB' -ErrorAction SilentlyContinue)
            $portFilter=if($rule.Count){@($rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)}else{@()}
            $plan=Get-LanFirewallRulePlan -Rules $rule -PortFilters $portFilter
            if ($plan -eq 'Conflict') { throw 'Firewall rule name conflicts with another rule.' }
            if ($plan -eq 'Repair') {
                # This exact rule belongs to the app. Windows or a security utility may disable
                # it; repairing Enabled/Profile is safe and lets auto-start restore saved shares.
                Set-NetFirewallRule -Name 'LFS-Private-SMB' -Enabled True -Profile Private -ErrorAction Stop | Out-Null
            } elseif ($plan -eq 'Create') {
                $ruleOptions = @{
                    Name='LFS-Private-SMB'; DisplayName='LAN File Sharing SMB Private'
                    Description='Created by LAN File Sharing'; Direction='Inbound'; Action='Allow'
                    Protocol='TCP'; LocalPort=445; Profile='Private'; Enabled='True'; ErrorAction='Stop'
                }
                New-NetFirewallRule @ruleOptions | Out-Null
            }
            if ($hostAdapter -and $hostAdapter.OnlineContext) {
                $ctx=$hostAdapter.OnlineContext
                $interface=if($ctx.Status.InterfaceId){$ctx.Status}else{$ctx.Settings.LastKnownInterface}
                if($interface){ & (Get-LanOnlinePolicyAdapter).RestrictLanRule $interface }
            }
            return @{Owned=$true; Name='LFS-Private-SMB'}
        }
        RemoveFirewall = {
            param($snapshot)
            if (-not $snapshot.Owned) { return }
            $rule = Get-NetFirewallRule -Name $snapshot.Name -ErrorAction SilentlyContinue
            if ($rule -and $rule.Description -eq 'Created by LAN File Sharing') {
                Remove-NetFirewallRule -Name $snapshot.Name -ErrorAction Stop
            }
        }
        GrantAcl = { param($path,$sids,$mode,$beforeApply,$kind) Grant-LanNtfsAcl -Path $path -Sids $sids -Mode $mode -BeforeApply $beforeApply -Kind $kind }
        RevokeAcl = { param($records) Revoke-LanNtfsAcl -Records $records }
        NewShare = {
            param($name,$path,$mode,$sids,$temporary,$id)
            if (-not $temporary) { throw 'Persistent SMB share is forbidden.' }
            $accounts = @(Resolve-LanSmbAccountNames -Sids $sids)
            $administrators = @(Resolve-LanSmbAccountNames -Sids @('S-1-5-32-544'))
            $options = @{Name=$name;Path=$path;Temporary=$true;FolderEnumerationMode='AccessBased';FullAccess=$administrators;Description="LanFileSharing:$id";ErrorAction='Stop'}
            if ($mode -eq 'Read') { $options.ReadAccess = $accounts }
            else { $options.ChangeAccess = $accounts }
            try { New-SmbShare @options | Out-Null }
            catch { throw "SMB share creation failed for '$name': $($_.Exception.Message)" }
        }
        RemoveShare = { param($name) Remove-SmbShare -Name $name -Force -ErrorAction Stop | Out-Null }
        DisableProtected = {
            param($userName)
            # Only an account this program could have made is removed — the random LFS_ names, and the names the
        # owner chooses now that they can. The account name alone is not proof of ownership, so the description
        # set when the account was created is checked too: an account the user made for something else is never
        # touched, whatever it is called.
        $looksOurs = $userName -match '^LFS_[a-f0-9]{10}$' -or
                     ($userName -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,19}$' -and
                      (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue).Description -eq 'LAN File Sharing app account')
        if (-not $looksOurs) { throw 'Refusing to remove an account not created by this app.' }
            $user = Get-LocalUser -Name $userName -ErrorAction Stop
            if ($user.Description -ne 'LAN File Sharing app account') { throw 'Account marker changed; automatic removal refused.' }
            Disable-LocalUser -Name $userName -ErrorAction Stop
            Remove-LocalUser -Name $userName -ErrorAction Stop
        }
        GetGuestPolicy = (New-LanAuthAdapter).GetGuestPolicy
        ApplyGuestChange = (New-LanAuthAdapter).ApplyGuestChange
    }
}
