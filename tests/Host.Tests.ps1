. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/SingleFile.ps1"
. "$PSScriptRoot/../src/Host.ps1"

Describe 'LAN host share transaction' {
    It 'recognizes and distinguishes enabled and disabled app-owned firewall CIM enums' {
        $rule=[pscustomobject]@{
            Name='LFS-Private-SMB';DisplayName='LAN File Sharing SMB Private'
            Description='Created by LAN File Sharing';Enabled=1;Profile=2;Direction=1;Action=2
        }
        $port=[pscustomobject]@{Protocol='TCP';LocalPort='445';RemotePort='Any'}
        Test-LanFirewallRuleOwned -Rule $rule -PortFilter $port | Should Be $true
        Test-LanFirewallRuleMatches -Rule $rule -PortFilter $port | Should Be $true
        Get-LanFirewallRulePlan -Rules @($rule) -PortFilters @($port) | Should Be 'Ready'
        $rule.Enabled=2
        Test-LanFirewallRuleOwned -Rule $rule -PortFilter $port | Should Be $true
        Test-LanFirewallRuleMatches -Rule $rule -PortFilter $port | Should Be $false
        Get-LanFirewallRulePlan -Rules @($rule) -PortFilters @($port) | Should Be 'Repair'
        $rule.Description='not ours'
        Get-LanFirewallRulePlan -Rules @($rule) -PortFilters @($port) | Should Be 'Conflict'
    }
    BeforeEach {
        $script:events = New-Object System.Collections.ArrayList
        $script:shares = @{}
        $script:guestEnabled = $false
        $script:blankPolicy = [pscustomobject]@{Present=$true;Value=1}
        $script:networkProfile = [pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Private'}
        $script:adapter = @{
            GetProfile = { 'Private' }
            GetNetworkProfiles = { @($script:networkProfile) }
            SetNetworkProfile = { param($index) $script:networkProfile.NetworkCategory='Private' }
            GetShare = { param($name) $script:shares[$name] }
            EnableFirewall = { [void]$script:events.Add('firewall-on'); @{Owned=$true; Name='LFS-Test'} }
            RemoveFirewall = { param($snapshot) [void]$script:events.Add('firewall-off') }
            GrantAcl = { param($path,$sids,$mode) [void]$script:events.Add("acl-$mode"); @(@{Path=$path; Before='a'; After='b'}) }
            RevokeAcl = { param($records) [void]$script:events.Add('acl-revoke') }
            NewShare = { param($name,$path,$mode,$sids,$temporary,$id) [void]$script:events.Add("smb-$mode-$temporary"); $script:shares[$name]=@{Name=$name; Path=$path; Description="LanFileSharing:$id"} }
            RemoveShare = { param($name) [void]$script:events.Add('smb-remove'); $script:shares.Remove($name) }
            DisableProtected = { param($userName) [void]$script:events.Add('user-disable') }
            EnsureWorker = { [void]$script:events.Add('worker-ready') }
            GetGuestPolicy = { param($role) @{Managed=$false;RequireSigning=$false;RequireEncryption=$false;GuestEnabled=$script:guestEnabled;UnrelatedSharesAtRisk=@()} }
            ApplyGuestChange = { param($role,$key,$value) $script:guestEnabled=[bool]$value }
            GetBlankPasswordPolicy = { $script:blankPolicy }
            SetBlankPasswordPolicy = { param($present,$value) $script:blankPolicy=[pscustomobject]@{Present=[bool]$present;Value=[int]$value} }
        }
        $script:folder = Join-Path $TestDrive 'host'
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        $script:selection = Resolve-LanSelection -Kind Folder -Path $script:folder
        $script:statePath = Join-Path $TestDrive 'host-state.json'
        if (Test-Path $script:statePath) { Remove-Item $script:statePath }
        $script:access = [pscustomobject]@{AuthMode='WindowsCurrent';AllowedSids=@('S-1-5-21-2-2');CredentialInfo=$null}
    }

    It 'records a stopped share even when the cleanup after it fails' {
        # The status "Stopping" was written before the work and the record removed at the very end, so a failure
        # in between — an ACL that could not be revoked, an account that could not be removed — left a record
        # with that status for good. A share stuck at "Stopping" then blocked the next install and uninstall,
        # because the leftover record described a share that no longer existed.
        $statePath = Join-Path $TestDrive 'stop-failure.json'
        $state = [pscustomobject]@{
            Version = 1
            Shares = @([pscustomobject]@{
                Id='share-1'; Name='Stuck'; Kind='Folder'; SourcePath='C:\data'; SharePath='C:\data'
                VolumeRoot='C:\'; Mode='Read'; AuthMode='Protected'
                AllowedSids=@('S-1-5-21-1-2-3-1001')
                CredentialInfo=[pscustomobject]@{ UserName='LFS_abc'; Sid='S-1-5-21-1-2-3-1001'; PasswordCipher=$null }
                AutoStart=$false; Status='Running'; AclRecords=@([pscustomobject]@{ Path='C:\data'; Before='x'; After='y' })
                FirewallSnapshot=$null; SingleFile=$null; NtfsPolicy='Managed'
            })
            Journal=@(); GuestSnapshots=@(); FirewallSnapshots=@(); BlankPasswordSnapshot=$null
        }
        Write-LanState -Path $statePath -State $state
        $adapter = @{
            GetShare = { param($n) [pscustomobject]@{ Name=$n; Path='C:\data'; Description='LanFileSharing:share-1' } }
            RemoveShare = { param($n) }
            # Revoking the rights is what fails here. The share is already off the network, so the stop has to
            # be recorded anyway.
            RevokeAcl = { param($r) throw 'ACL could not be revoked.' }
            RemoveFirewall = { param($s) }
            DisableProtected = { param($u) throw 'The account could not be removed.' }
        }
        $result = Stop-LanHostShareCore -Id 'share-1' -StatePath $statePath -Adapter $adapter
        $result.Stopped | Should Be $true
        @($result.CleanupErrors).Count | Should Be 2
        # The record is gone, so nothing is left describing a share that no longer exists.
        @((Read-LanState -Path $statePath).Shares).Count | Should Be 0
    }
    It 'records and restores the original blank-password network policy' {
        Enable-LanBlankPasswordNetworkLogon -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:blankPolicy.Value | Should Be 0
        (Read-LanState $script:statePath).BlankPasswordSnapshot.Value | Should Be 1
        Restore-LanBlankPasswordNetworkLogon -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:blankPolicy.Value | Should Be 1
        (Read-LanState $script:statePath).BlankPasswordSnapshot | Should BeNullOrEmpty
    }

    It 'does not overwrite a policy changed by something else after this app enabled it' {
        Enable-LanBlankPasswordNetworkLogon -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:blankPolicy.Value = 2
        { Restore-LanBlankPasswordNetworkLogon -StatePath $script:statePath -Adapter $script:adapter } | Should Throw 'changed outside'
        (Read-LanState $script:statePath).BlankPasswordSnapshot.Value | Should Be 1
    }

    It 'waits for the lock instead of failing when a caller asks for a longer wait' {
        # NTFS granting happens while the lock is held, so a user action must be able to wait for
        # a busy worker rather than fail. The timeout parameter must not reach the inner splat.
        $script:adapter.EnsureWorker = { [void]$script:events.Add('worker-ready') }
        $created = Start-LanHostShare -Selection $script:selection -Name 'LongWait' -Mode Read `
            -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter `
            -LockTimeoutMilliseconds 180000
        $created.Name | Should Be 'LongWait'
        (Read-LanState $script:statePath).Shares[0].Name | Should Be 'LongWait'
    }
    It 'fails fast when the lock cannot be taken and the caller allows no wait' {
        $held = Enter-LanStateLock -StatePath $script:statePath -TimeoutMilliseconds 0
        try {
            { Start-LanHostShare -Selection $script:selection -Name 'NoWait' -Mode Read `
                -Access $script:access -AutoStart $false -StatePath $script:statePath -Adapter $script:adapter `
                -LockTimeoutMilliseconds 0 } | Should Throw 'Timed out waiting for the host state lock'
        } finally { $held.Dispose() }
    }

    It 'checks worker readiness before holding the host state lock' {
        $script:adapter.EnsureWorker = {
            $workerLock = Enter-LanStateLock -StatePath $script:statePath -TimeoutMilliseconds 0
            $workerLock.Dispose()
            [void]$script:events.Add('worker-ready')
        }
        $created = Start-LanHostShare -Selection $script:selection -Name 'ReadyBeforeLock' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter
        $created.Name | Should Be 'ReadyBeforeLock'
        ($script:events -join ',') | Should Match '^worker-ready,firewall-on'
    }

    It 'creates a temporary Read share only after ACL and Private firewall' {
        $result = Start-LanHostShare -Selection $script:selection -Name 'ReadTest' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter
        $result.AutoStart | Should Be $true
        ($script:events -join ',') | Should Be 'worker-ready,firewall-on,acl-Read,smb-Read-True'
        (Read-LanState $script:statePath).Shares[0].Name | Should Be 'ReadTest'
    }

    It 'prepares a Public LAN and remembers it for automatic sharing after boot' {
        $script:networkProfile.NetworkCategory='Public'
        $script:adapter.SetNetworkProfile = { param($index) $script:networkProfile.NetworkCategory='Private'; [void]$script:events.Add('network-private') }
        $entry = Start-LanHostShare -Selection $script:selection -Name 'AutoNetwork' -Mode Read -Access $script:access -StatePath $script:statePath -Adapter $script:adapter
        $entry.NetworkProfile.Name | Should Be 'Home LAN'
        ($script:events -join ',') | Should Be 'worker-ready,network-private,firewall-on,acl-Read,smb-Read-True'
    }

    It 'passes Modify rights to both ACL and SMB' {
        Start-LanHostShare -Selection $script:selection -Name 'WriteTest' -Mode Modify -Access $script:access -AutoStart $false -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Match 'acl-Modify,smb-Modify-True'
    }

    It 'shares the Windows drive root without changing its NTFS ACL' {
        $root = [IO.Path]::GetPathRoot($env:windir)
        $selection = Resolve-LanSelection -Kind Drive -Path $root
        $entry = Start-LanHostShare -Selection $selection -Name 'SystemDriveTest' -Mode Modify -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter
        $entry.NtfsPolicy | Should Be 'Preserved'
        @($entry.AclRecords).Count | Should Be 0
        ($script:events -join ',') | Should Be 'worker-ready,firewall-on,smb-Modify-True'
    }

    It 'requires a running worker before exposing a single File share' {
        $source = Join-Path $script:folder 'only.txt'
        [IO.File]::WriteAllText($source, 'original')
        $selection = Resolve-LanSelection -Kind File -Path $source
        $script:adapter.EnsureWorker = { throw 'worker unavailable' }
        { Start-LanHostShare -Selection $selection -Name 'OnlyFile' -Mode Modify -Access $script:access -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        @($script:events | Where-Object { $_ -like 'smb-*' }).Count | Should Be 0
        @((Read-LanState $script:statePath).Shares).Count | Should Be 0
    }

    It 'requires a running worker before exposing an automatic Folder share' {
        $script:adapter.EnsureWorker = { throw 'worker unavailable' }
        { Start-LanHostShare -Selection $script:selection -Name 'AutoFolder' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter } | Should Throw 'worker unavailable'
        @($script:events | Where-Object { $_ -like 'smb-*' }).Count | Should Be 0
        @((Read-LanState $script:statePath).Shares).Count | Should Be 0
    }

    It 'does not change ACL or firewall when Windows refuses Private' {
        $script:networkProfile.NetworkCategory='Public'
        $script:adapter.SetNetworkProfile = { throw 'Network policy forbids Private.' }
        { Start-LanHostShare -Selection $script:selection -Name 'PublicTest' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        ($script:events -join ',') | Should Be 'worker-ready'
    }

    It 'disables a newly created Protected account if preflight rejects sharing' {
        $script:access = [pscustomobject]@{AuthMode='Protected';AllowedSids=@('S-1-5-21-3-3');CredentialInfo=@{UserName='LFS_test';Sid='S-1-5-21-3-3';Password='secret'}}
        $script:networkProfile.NetworkCategory='Public'
        $script:adapter.SetNetworkProfile = { throw 'Network policy forbids Private.' }
        { Start-LanHostShare -Selection $script:selection -Name 'ProtectedReject' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        ($script:events -join ',') | Should Match 'user-disable'
    }

    It 'never overwrites an existing share name' {
        $script:shares['Taken'] = @{Name='Taken';Path='C:\other'}
        { Start-LanHostShare -Selection $script:selection -Name 'Taken' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        $script:shares['Taken'].Path | Should Be 'C:\other'
        ($script:events -join ',') | Should Be 'worker-ready'
    }

    It 'rolls back firewall and ACL when SMB creation fails' {
        $script:adapter.NewShare = { param($name,$path,$mode,$sids,$temporary) throw 'injected SMB error' }
        { Start-LanHostShare -Selection $script:selection -Name 'FailTest' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        ($script:events -join ',') | Should Be 'worker-ready,firewall-on,acl-Read,acl-revoke,firewall-off'
        @((Read-LanState $script:statePath).Shares).Count | Should Be 0
    }

    It 'persists each ACL intention before applying it and can roll it back on interruption' {
        $script:adapter.GrantAcl = {
            param($path,$sids,$mode,$beforeApply)
            & $beforeApply @{Path=$path;Before='a';After='b'}
            @((Read-LanState $script:statePath).Journal[0].AclRecords).Count | Should Be 1
            throw 'injected interruption after first ACL'
        }
        { Start-LanHostShare -Selection $script:selection -Name 'InterruptedAcl' -Mode Read -Access $script:access -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        ($script:events -join ',') | Should Match 'acl-revoke'
        @((Read-LanState $script:statePath).Journal).Count | Should Be 0
    }

    It 'clears AutoStart before stopping and disables the last Protected account' {
        $script:access = [pscustomobject]@{AuthMode='Protected';AllowedSids=@('S-1-5-21-3-3');CredentialInfo=@{UserName='LFS_test';Sid='S-1-5-21-3-3';Password='secret'}}
        $entry = Start-LanHostShare -Selection $script:selection -Name 'StopTest' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter
        Stop-LanHostShare -Id $entry.Id -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        @((Read-LanState $script:statePath).Shares).Count | Should Be 0
        ($script:events -join ',') | Should Match 'smb-remove,acl-revoke,firewall-off,user-disable'
    }
    It 'restores the app-enabled Host Guest account after the last Guest share stops' {
        Enable-LanGuestConfiguration -Role Host -Adapter $script:adapter -StatePath $script:statePath | Out-Null
        $script:guestEnabled | Should Be $true
        $script:access = [pscustomobject]@{AuthMode='Guest';AllowedSids=@('S-1-5-21-3-501');CredentialInfo=$null}
        $entry = Start-LanHostShare -Selection $script:selection -Name 'GuestShare' -Mode Read -Access $script:access -StatePath $script:statePath -Adapter $script:adapter
        Stop-LanHostShare -Id $entry.Id -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:guestEnabled | Should Be $false
    }

    It 'refuses to remove a same-path share without its ownership marker' {
        $entry = Start-LanHostShare -Selection $script:selection -Name 'Foreign' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter
        $script:shares['Foreign'].Description = 'Created elsewhere'
        { Stop-LanHostShare -Id $entry.Id -StatePath $script:statePath -Adapter $script:adapter } | Should Throw
        $script:shares.ContainsKey('Foreign') | Should Be $true
    }

    It 'finishes a cleanup stop while leaving a share it does not own in place' {
        # The window must still refuse, but setup and uninstall pass -ReleaseUnownedName so a
        # takeover cannot leave the machine half cleaned.
        $entry = Start-LanHostShare -Selection $script:selection -Name 'TakenOver' -Mode Read -Access $script:access -AutoStart $true -StatePath $script:statePath -Adapter $script:adapter
        $script:shares['TakenOver'].Description = 'Created elsewhere'
        $script:events.Clear()
        $result = Stop-LanHostShare -Id $entry.Id -StatePath $script:statePath -Adapter $script:adapter -ReleaseUnownedName
        $result.Stopped | Should Be $true
        $script:shares.ContainsKey('TakenOver') | Should Be $true
        ($script:events -join ',') | Should Not Match 'smb-remove'
        # The app's own record is gone, so setup can continue.
        @((Read-LanState $script:statePath).Shares).Count | Should Be 0
    }

    It 'repairs an interrupted setup without deleting a different share' {
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='old';Name='Collision';SharePath=$script:folder;AclRecords=@();FirewallSnapshot=@{Owned=$false}})
        Write-LanState $script:statePath $state
        $script:shares['Collision'] = @{Name='Collision';Path='C:\other'}
        $repair = Repair-LanHostState -StatePath $script:statePath -Adapter $script:adapter
        $script:shares['Collision'].Path | Should Be 'C:\other'
        # The entry is released instead of blocking every later cleanup: waiting can never make
        # someone else's share name free again.
        @($repair.Pending).Count | Should Be 0
        @($repair.Resolved).Count | Should Be 1
        @((Read-LanState $script:statePath).Journal).Count | Should Be 0
    }

    It 'undoes its own NTFS and firewall changes for a share name it no longer owns' {
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='old';Name='Collision';SharePath=$script:folder;
            AclRecords=@(@{Path=$script:folder;Before='a';After='b'});FirewallSnapshot=@{Owned=$true;Name='LFS-Test'}})
        Write-LanState $script:statePath $state
        $script:shares['Collision'] = @{Name='Collision';Path='C:\other'}
        $script:adapter.RevokeAcl = { param($records) [void]$script:events.Add('acl-revoke') }
        $script:adapter.RemoveFirewall = { param($snapshot) [void]$script:events.Add('firewall-off') }
        Repair-LanHostState -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Match 'acl-revoke'
        ($script:events -join ',') | Should Match 'firewall-off'
        ($script:events -join ',') | Should Not Match 'smb-remove'
        $script:shares.ContainsKey('Collision') | Should Be $true
    }

    It 'removes its own stale share when an older state file recorded a different id' {
        # Reinstalling or restoring an older state file must not leave an orphan share behind
        # that later makes the same name unusable.
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='old-id';Name='Reused';SharePath=$script:folder;AclRecords=@();FirewallSnapshot=$null})
        Write-LanState $script:statePath $state
        $script:shares['Reused'] = @{Name='Reused';Path='C:\elsewhere';Description='LanFileSharing:other-install'}
        $repair = Repair-LanHostState -StatePath $script:statePath -Adapter $script:adapter
        $script:shares.ContainsKey('Reused') | Should Be $false
        @($repair.Pending).Count | Should Be 0
        @($repair.Repaired).Count | Should Be 1
    }
}

Describe 'NTFS permission changes on a disposable directory' {
    It 'leaves the Windows volume NTFS ACL unchanged for a full-drive share' {
        $root = [IO.Path]::GetPathRoot($env:windir)
        $before=(Get-Acl -LiteralPath $root).Sddl
        $records=@(Grant-LanNtfsAcl -Path $root -Sids @('S-1-5-11') -Mode Modify -Kind Drive)
        $records.Count | Should Be 0
        (Get-Acl -LiteralPath $root).Sddl | Should Be $before
    }

    It 'ignores a deny that only blocks deleting subfolders, which no share grants' {
        # OneDrive stamps this on every folder it manages. It never stops reading, writing or
        # modifying files, so it must not refuse an otherwise shareable folder.
        $folder = Join-Path $TestDrive 'deny-undeletable'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $acl = Get-Acl -LiteralPath $folder
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
            [Security.AccessControl.AccessControlType]::Deny)))
        Set-Acl -LiteralPath $folder -AclObject $acl
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        { Assert-LanNoDenyAcl -Acl (Get-Acl -LiteralPath $folder) -Path $folder -Mode Modify } | Should Not Throw
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Modify)
        try { $records.Count | Should BeGreaterThan 0 }
        finally { if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records } }
    }
    It 'still refuses a deny that blocks a right the share actually grants' {
        $folder = Join-Path $TestDrive 'deny-real'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $acl = Get-Acl -LiteralPath $folder
        # Not inherited, so it guards the folder itself and Pester can still clear TestDrive.
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny)))
        Set-Acl -LiteralPath $folder -AclObject $acl
        try {
            { Assert-LanNoDenyAcl -Acl (Get-Acl -LiteralPath $folder) -Path $folder -Mode Read } | Should Throw 'Deny ACE'
            { Assert-LanNoDenyAcl -Acl (Get-Acl -LiteralPath $folder) -Path $folder -Mode Modify } | Should Throw 'Deny ACE'
        } finally {
            # Put the folder back so the deny entry cannot block the test harness cleanup.
            $restore = Get-Acl -LiteralPath $folder
            foreach ($rule in @($restore.Access)) {
                if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) { $restore.RemoveAccessRuleSpecific($rule) }
            }
            Set-Acl -LiteralPath $folder -AclObject $restore
        }
    }
    It 'ignores a deny that only applies to descendants of the shared folder' {
        $folder = Join-Path $TestDrive 'deny-inherit-only'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $acl = Get-Acl -LiteralPath $folder
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::InheritOnly,
            [Security.AccessControl.AccessControlType]::Deny)))
        Set-Acl -LiteralPath $folder -AclObject $acl
        { Assert-LanNoDenyAcl -Acl (Get-Acl -LiteralPath $folder) -Path $folder -Mode Read } | Should Not Throw
    }
    It 'rejects a deny ACE even when it belongs to an indirect group' {
        $acl = Get-Acl -LiteralPath $TestDrive
        $group = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $deny = New-Object Security.AccessControl.FileSystemAccessRule($group,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $prefix = Get-LanLocalUserSidPrefix -Sids @($sid)
        { Assert-LanNoDenyAcl -Acl $acl -Path 'child.txt' -LocalUserSidPrefix $prefix } | Should Throw 'Deny ACE'
    }
    It 'ignores a foreign-account Deny ACE for a verified local user without removing it' {
        $folder = Join-Path $TestDrive 'foreign-deny'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $acl = Get-Acl -LiteralPath $folder
        $foreign = New-Object Security.Principal.SecurityIdentifier('S-1-5-21-700553648-146801184-2495223818-3500588343')
        $deny = New-Object Security.AccessControl.FileSystemAccessRule($foreign,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        Set-Acl -LiteralPath $folder -AclObject $acl
        $before = (Get-Acl -LiteralPath $folder).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        { Assert-LanNoDenyAcl -Acl (Get-Acl -LiteralPath $folder) -Path $folder } | Should Throw 'Deny ACE'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        try { $records.Count | Should BeGreaterThan 0 }
        finally { if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records } }
        (Get-Acl -LiteralPath $folder).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) | Should Be $before
    }
    It 'ignores an orphaned Deny SID when granting Authenticated Users without removing it' {
        $folder = Join-Path $TestDrive 'orphan-deny'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $acl = Get-Acl -LiteralPath $folder
        $orphan = New-Object Security.Principal.SecurityIdentifier('S-1-5-21-700553648-146801184-2495223818-3500588343')
        $deny = New-Object Security.AccessControl.FileSystemAccessRule($orphan,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        Set-Acl -LiteralPath $folder -AclObject $acl
        $before = (Get-Acl -LiteralPath $folder).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @('S-1-5-11') -Mode Read)
        try { $records.Count | Should BeGreaterThan 0 }
        finally { if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records } }
        (Get-Acl -LiteralPath $folder).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) | Should Be $before
    }
    It 'still rejects a Deny ACE for the intended local user' {
        $acl = Get-Acl -LiteralPath $TestDrive
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $deny = New-Object Security.AccessControl.FileSystemAccessRule($sid,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        $prefix = $sid.Value.Substring(0,$sid.Value.LastIndexOf('-'))
        { Assert-LanNoDenyAcl -Acl $acl -Path 'child.txt' -LocalUserSidPrefix $prefix } | Should Throw 'Deny ACE'
    }
    It 'records and restores only its own ACL update' {
        $folder = Join-Path $TestDrive 'acl-sample'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $beforeAcl = Get-Acl -LiteralPath $folder
        $before = $beforeAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $beforeRules = @((Get-LanAclRules -Sddl $before).Rules | ForEach-Object { Get-LanAclRuleKey -Rule $_ } | Sort-Object)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        $records.Count | Should BeGreaterThan 0
        Revoke-LanNtfsAcl -Records $records
        $afterAcl = Get-Acl -LiteralPath $folder
        $after = $afterAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $afterRules = @((Get-LanAclRules -Sddl $after).Rules | ForEach-Object { Get-LanAclRuleKey -Rule $_ } | Sort-Object)
        ($afterRules -join "`n") | Should Be ($beforeRules -join "`n")
        $afterAcl.AreAccessRulesProtected | Should Be $beforeAcl.AreAccessRulesProtected
    }

    It 'reads a recorded ACL that carries generic access rights' {
        # A recorded security descriptor can spell rights as GENERIC_ALL and friends. Those have
        # no FileSystemRights member, so parsing used to throw and an interrupted setup could not
        # be undone, which blocked setup and uninstall on the affected machine. The end-to-end
        # revocation of such a record is covered by tests/Repro-GenericAclMask.ps1.
        foreach ($pair in @(
                @('D:(A;;GA;;;S-1-5-11)', 'Allow'),
                @('D:(A;;GR;;;S-1-5-11)', 'Allow'),
                @('D:(A;;GW;;;S-1-5-11)', 'Allow'),
                @('D:(A;;GX;;;S-1-5-11)', 'Allow'),
                @('D:(D;;GA;;;S-1-5-11)', 'Deny'),
                @('D:(A;;0xe0010000;;;S-1-5-11)', 'Allow'))) {
            $list = (Get-LanAclRules -Sddl $pair[0]).Rules
            $list.Count | Should Be 1
            # The generic bits are translated, so the rule can be built and keyed.
            (Get-LanAclRuleKey -Rule $list[0]) | Should Match "\|$($pair[1])$"
            ([int]$list[0].FileSystemRights -band [int]0xF0000000) | Should Be 0
        }
        # A generic spelling must describe the same access as its expanded literal, otherwise
        # recovery would not recognise the entry it needs to remove.
        $pairs = @(
            @('D:(A;;GA;;;S-1-5-11)', 'D:(A;;FA;;;S-1-5-11)'),
            @('D:(A;;GR;;;S-1-5-11)', 'D:(A;;0x120089;;;S-1-5-11)'),
            @('D:(A;;GW;;;S-1-5-11)', 'D:(A;;0x120116;;;S-1-5-11)'),
            @('D:(A;;GX;;;S-1-5-11)', 'D:(A;;0x1200a0;;;S-1-5-11)'),
            @('D:(A;;0xe0010000;;;S-1-5-11)', 'D:(A;;0x1301bf;;;S-1-5-11)'))
        foreach ($pair in $pairs) {
            $generic = (Get-LanAclRules -Sddl $pair[0]).Rules[0]
            $explicit = (Get-LanAclRules -Sddl $pair[1]).Rules[0]
            (Get-LanAclRuleKey -Rule $generic) | Should Be (Get-LanAclRuleKey -Rule $explicit)
        }
    }
    It 'records an ACL intention before the native ACL is changed' {
        $folder = Join-Path $TestDrive 'acl-prewrite'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $script:recordedBefore = $false
        $beforeApply = {
            param($record)
            $current = (Get-Acl -LiteralPath $record.Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            $current | Should Be $record.Before
            $script:recordedBefore = $true
        }
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read -BeforeApply $beforeApply)
        $script:recordedBefore | Should Be $true
        Revoke-LanNtfsAcl -Records $records
        Revoke-LanNtfsAcl -Records $records
    }
    It 'does not traverse volume metadata while granting a Drive share' {
        $root = Join-Path $TestDrive 'drive-acl'
        $metadata = Join-Path $root 'System Volume Information'
        $outside = Join-Path $TestDrive 'outside-acl'
        New-Item -ItemType Directory -Path $metadata -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $link = Join-Path $metadata 'protected-link'
        cmd /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { return }
        [IO.File]::WriteAllText((Join-Path $root 'data.txt'), 'data')
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $root -Sids @($sid) -Mode Read -Kind Drive)
        try { $records.Count | Should BeGreaterThan 0 }
        finally { if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records } }
    }
    It 'never records an ACL inside a Windows-owned volume container' {
        $root = Join-Path $TestDrive 'drive-prune'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $user = New-Object Security.Principal.SecurityIdentifier($sid)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        # A protected folder is what the traversal records. Both Windows-owned containers and
        # the ordinary folder below are protected, as such folders are on a real volume.
        $visible = Join-Path $root 'shared-folder'
        foreach ($dir in @((Join-Path $root '$RECYCLE.BIN'), (Join-Path $root 'System Volume Information'), $visible)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $acl = Get-Acl -LiteralPath $dir
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $user,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow)))
            Set-Acl -LiteralPath $dir -AclObject $acl
        }
        $records = @(Grant-LanNtfsAcl -Path $root -Sids @($sid) -Mode Read -Kind Drive)
        try {
            # Nothing inside a Windows-owned container is recorded any more...
            @($records | Where-Object { $_.Path -like '*$RECYCLE.BIN*' -or $_.Path -like '*System Volume Information*' }).Count | Should Be 0
            # ...while the ordinary protected folder is still managed.
            @($records | Where-Object { $_.Path -eq $visible }).Count | Should Be 1
        } finally { if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records } }
    }
    It 'leaves a Windows-owned container untouched when it is the selected root itself' {
        $root = Join-Path $TestDrive 'recycle-root'
        $recycle = Join-Path $root '$RECYCLE.BIN'
        New-Item -ItemType Directory -Path $recycle -Force | Out-Null
        $before = (Get-Acl -LiteralPath $recycle).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $recycle -Sids @($sid) -Mode Read)
        $records.Count | Should Be 0
        (Get-Acl -LiteralPath $recycle).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) | Should Be $before
    }
    It 'skips a subtree it cannot enumerate instead of failing the whole share' {
        $root = Join-Path $TestDrive 'grant-unreadable'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'data.txt'),'x')
        # A junction with a missing target cannot be enumerated; the walk must step over it.
        $broken = Join-Path $root 'broken-link'
        cmd /c "mklink /J `"$broken`" `"$TestDrive\does-not-exist`"" | Out-Null
        if (-not (Test-Path -LiteralPath $broken)) { return }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = $null
        { $script:records = @(Grant-LanNtfsAcl -Path $root -Sids @($sid) -Mode Read) } | Should Not Throw
        @($script:records | Where-Object { $_.Path -eq $root }).Count | Should Be 1
        if ($script:records.Count -gt 0) { Revoke-LanNtfsAcl -Records $script:records }
    }
    It 'resolves an ACL record whose path was deleted after activation' {
        $folder = Join-Path $TestDrive 'acl-deleted'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        $records.Count | Should BeGreaterThan 0
        Remove-Item -LiteralPath $folder -Recurse -Force
        { Revoke-LanNtfsAcl -Records $records } | Should Not Throw
    }
    It 'resolves an ACL record whose granted entry an outside change already removed' {
        $folder = Join-Path $TestDrive 'acl-outside-removed'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        $records.Count | Should BeGreaterThan 0
        $reset = Get-Acl -LiteralPath $folder
        foreach ($rule in @($reset.Access)) {
            if ($rule.IdentityReference.Value -eq ([Security.Principal.SecurityIdentifier]::new($sid)).Translate([Security.Principal.NTAccount]).Value) {
                $reset.RemoveAccessRuleSpecific($rule)
            }
        }
        Set-Acl -LiteralPath $folder -AclObject $reset
        { Revoke-LanNtfsAcl -Records $records } | Should Not Throw
    }
    It 'removes only its own entry when the ACL changed outside the app and keeps the outside change' {
        $folder = Join-Path $TestDrive 'acl-outside-kept'
        $outside = New-Object Security.Principal.SecurityIdentifier('S-1-5-21-1111111111-2222222222-3333333333-4444')
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        $records.Count | Should BeGreaterThan 0
        $changed = Get-Acl -LiteralPath $folder
        $changed.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $outside,[Security.AccessControl.FileSystemRights]::ReadAndExecute,
            [Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -LiteralPath $folder -AclObject $changed
        { Revoke-LanNtfsAcl -Records $records } | Should Not Throw
        $after = Get-Acl -LiteralPath $folder
        # The owner's own entry survives...
        @($after.Access | Where-Object {
            (Get-LanAclPrincipalSid -IdentityReference $_.IdentityReference) -eq $outside.Value -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq
                [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
        }).Count | Should Be 1
        # ...and this app's entry is the only thing that was taken back out.
        (Test-LanAclHoldsNoAppGrant -Acl $after -AddedRules (Get-LanAccessRuleDelta -Before $records[0].Before -After $records[0].After).Rules) | Should Be $true
    }
    It 'undoes only the entries this app added, computed from the journal pair' {
        $folder = Join-Path $TestDrive 'acl-delta'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        $records.Count | Should BeGreaterThan 0
        $added = (Get-LanAccessRuleDelta -Before $records[0].Before -After $records[0].After).Rules
        $added.Count | Should BeGreaterThan 0
        (Test-LanAclHoldsNoAppGrant -Acl (Get-Acl -LiteralPath $folder) -AddedRules $added) | Should Be $false
        Revoke-LanNtfsAcl -Records $records
        $restoredAcl = Get-Acl -LiteralPath $folder
        $restored = $restoredAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $expectedRules = @((Get-LanAclRules -Sddl $records[0].Before).Rules | ForEach-Object { Get-LanAclRuleKey -Rule $_ } | Sort-Object)
        $restoredRules = @((Get-LanAclRules -Sddl $restored).Rules | ForEach-Object { Get-LanAclRuleKey -Rule $_ } | Sort-Object)
        ($restoredRules -join "`n") | Should Be ($expectedRules -join "`n")
    }
    It 'still recognises its own grant after the owner changes another entry' {
        # The activation check used to compare the whole security descriptor as a string, so a user
        # adding an unrelated entry (or changing the owner) made the app believe its own grant had
        # been altered, and the share was blocked with "NTFS permissions changed after activation".
        # Verification must ask whether THIS APP'S entry is still present, by identity.
        $folder = Join-Path $TestDrive 'acl-unrelated-change'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $folder -Sids @($sid) -Mode Read)
        $records.Count | Should BeGreaterThan 0
        $added = (Get-LanAccessRuleDelta -Before $records[0].Before -After $records[0].After).Rules

        # The owner adds a permission of their own, unrelated to this app.
        $acl = Get-Acl -LiteralPath $folder
        $other = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),
            [Security.AccessControl.FileSystemRights]::Read,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($other) | Out-Null
        Set-Acl -LiteralPath $folder -AclObject $acl

        # A string comparison would now differ from $records[0].After; identity still matches.
        $current = (Get-Acl -LiteralPath $folder).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $current | Should Not Be $records[0].After
        (Test-LanAclHoldsNoAppGrant -Acl (Get-Acl -LiteralPath $folder) -AddedRules $added) | Should Be $false
    }
    It 'does not grant ACL through a reparse child of a Drive share' {
        $root = Join-Path $TestDrive 'drive-junction-acl'
        $outside = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Path $root,$outside -Force | Out-Null
        $link = Join-Path $root 'node_modules'
        cmd /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { return }
        $before = (Get-Acl -LiteralPath $outside).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $records = @(Grant-LanNtfsAcl -Path $root -Sids @($sid) -Mode Read -Kind Drive)
        try {
            @($records | Where-Object { $_.Path -eq $link -or $_.Path -eq $outside }).Count | Should Be 0
            (Get-Acl -LiteralPath $outside).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) | Should Be $before
        } finally { if ($records.Count -gt 0) { Revoke-LanNtfsAcl -Records $records } }
    }
}

Describe 'Native SMB share account mapping' {
    It 'maps Authenticated Users to the actual Windows account for SMB permissions' {
        Mock New-SmbShare { }
        $adapter = New-LanHostAdapter
        $expected = ([Security.Principal.SecurityIdentifier]::new('S-1-5-11')).Translate([Security.Principal.NTAccount]).Value

        & $adapter.NewShare 'NativeTest' $TestDrive 'Modify' @('S-1-5-11') $true 'abc' | Out-Null

        Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It -ParameterFilter {
            @($ChangeAccess)[0] -eq ([Security.Principal.SecurityIdentifier]::new('S-1-5-11').Translate([Security.Principal.NTAccount]).Value)
        }
        @(Resolve-LanSmbAccountNames -Sids @('S-1-5-11'))[0] | Should Be $expected
    }
    It 'passes resolvable account names rather than raw SIDs to New-SmbShare' {
        Mock New-SmbShare { }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $expected = ([Security.Principal.SecurityIdentifier]::new($sid)).Translate([Security.Principal.NTAccount]).Value
        $administrators = ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
        $adapter = New-LanHostAdapter

        & $adapter.NewShare 'NativeTest' $TestDrive 'Modify' @($sid) $true 'abc' | Out-Null

        Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It -ParameterFilter {
            @($ChangeAccess)[0] -eq ([Security.Principal.WindowsIdentity]::GetCurrent().User.Translate([Security.Principal.NTAccount]).Value) -and
            @($FullAccess)[0] -eq ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value)
        }
        @(Resolve-LanSmbAccountNames -Sids @($sid))[0] | Should Be $expected
        @(Resolve-LanSmbAccountNames -Sids @('S-1-5-32-544'))[0] | Should Be $administrators
    }

    It 'rejects an unresolvable SID before calling New-SmbShare' {
        Mock New-SmbShare { }
        $adapter = New-LanHostAdapter
        $foreign = 'S-1-5-21-700553648-146801184-2495223818-3500588343'

        { & $adapter.NewShare 'NativeTest' $TestDrive 'Read' @($foreign) $true 'abc' } | Should Throw 'Cannot resolve SMB account SID'
        Assert-MockCalled New-SmbShare -Times 0 -Exactly -Scope It
    }
}
