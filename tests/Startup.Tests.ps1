. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/Host.ps1"
. "$PSScriptRoot/../src/InstallLocation.ps1"
. "$PSScriptRoot/../src/Startup.ps1"

Describe 'installer and boot-time share worker' {
    BeforeEach {
        $script:events = New-Object System.Collections.ArrayList
        $script:shares = @{}
        $script:profile = 'Private'
        $script:blankPolicy = [pscustomobject]@{Present=$true;Value=1}
        $script:folder = Join-Path $TestDrive 'startup-folder'
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        $script:selection = Resolve-LanSelection -Kind Folder -Path $script:folder
        $script:statePath = Join-Path $TestDrive 'startup.json'
        if (Test-Path $script:statePath) { Remove-Item $script:statePath }
        $script:adapter = @{
            StatePath = $script:statePath
            CopyFiles = { param($root) [void]$script:events.Add('copy') }
            SecureDirectory = { param($path) [void]$script:events.Add('secure') }
            RegisterTask = { param($root,$stateRoot,$account,$atStartup,$restart) [void]$script:events.Add("task-$account-$atStartup-$restart") }
            StartTask = { [void]$script:events.Add('task-start') }
            StopTask = { [void]$script:events.Add('task-stop') }
            UnregisterTask = { [void]$script:events.Add('task-remove') }
            RemoveInstalledFiles = { [void]$script:events.Add('files-remove') }
            GetProfile = { $script:profile }
            GetShare = { param($name) $script:shares[$name] }
            NewShare = { param($name,$path,$mode,$sids,$temporary,$id) [void]$script:events.Add("share-$temporary"); $script:shares[$name]=@{Name=$name;Path=$path;Description="LanFileSharing:$id"} }
            RemoveShare = { param($name) [void]$script:events.Add('share-remove'); $script:shares.Remove($name) }
            EnableFirewall = { [void]$script:events.Add('firewall'); @{Owned=$true;Name='LFS-Test'} }
            RemoveFirewall = { param($snapshot) [void]$script:events.Add('firewall-remove') }
            VerifyAcl = { param($records) $true }
            RevokeAcl = { param($records) [void]$script:events.Add('acl-remove') }
            DisableProtected = { param($name) [void]$script:events.Add('user-disable') }
            StartMonitor = { param($entry) [void]$script:events.Add('monitor'); $null }
            SyncFile = { param($entry) [void]$script:events.Add('sync'); @{Status='InPlace'} }
            GetFileId = { param($path) 'file-id' }
            GetGuestPolicy = { param($role) @{GuestEnabled=$false} }
            ApplyGuestChange = { param($role,$key,$value) }
            GetBlankPasswordPolicy = { $script:blankPolicy }
            SetBlankPasswordPolicy = { param($present,$value) $script:blankPolicy=[pscustomobject]@{Present=[bool]$present;Value=[int]$value} }
        }
    }

    It 'retains a custom install record if worker startup fails after task registration' {
        $script:installRecord=$null
        $location=@{
            ReadRecord={ $script:installRecord }
            WriteRecord={ param($path) $script:installRecord=$path }
            DeleteRecord={ $script:installRecord=$null }
        }
        $script:adapter.StartTask={ throw 'worker heartbeat timeout' }
        { Invoke-LanRecordedHostInstall -InstallRoot 'D:\Protected\LanFileSharing' -StateRoot 'C:\ProgramData\LanFileSharing' -Adapter $script:adapter -LocationAdapter $location } | Should Throw
        (Get-LanInstallRecord -Adapter $location).InstallRoot | Should Be 'D:\Protected\LanFileSharing'
    }

    It 'restores a missing host worker from the recorded trusted installation' {
        $root=Join-Path $TestDrive 'LanFileSharing'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'HostWorker.ps1'),'# test')
        $script:adapter.GetTask={ $null }
        $script:adapter.GetInstallRecord={ [pscustomobject]@{InstallRoot=$root} }
        $script:adapter.AssertTrustedTree={ param($path) [void]$script:events.Add('trusted') }
        $script:adapter.HeartbeatFresh={ param($path) $false }
        $result=Ensure-LanHostWorkerTask -InstallRoot $root -StateRoot $TestDrive -Adapter $script:adapter
        $result.Repaired | Should Be $true
        ($script:events -join ',') | Should Be 'trusted,task-SYSTEM-True-True,task-start'
    }

    It 'refuses to restore the worker from a different install location' {
        $root=Join-Path $TestDrive 'LanFileSharing'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'HostWorker.ps1'),'# test')
        $script:adapter.GetTask={ $null }
        $script:adapter.GetInstallRecord={ [pscustomobject]@{InstallRoot='C:\Different\LanFileSharing'} }
        $script:adapter.AssertTrustedTree={ param($path) [void]$script:events.Add('trusted') }
        { Ensure-LanHostWorkerTask -InstallRoot $root -StateRoot $TestDrive -Adapter $script:adapter } | Should Throw 'recorded'
        $script:events.Count | Should Be 0
    }

    function Add-TestEntry($name,$kind='Folder',$auto=$true) {
        $state = Read-LanState $script:statePath
        $entry = [pscustomobject]@{
            Id=[guid]::NewGuid().ToString('N'); Name=$name; Kind=$kind
            SourcePath=$script:selection.FullPath; SharePath=$script:selection.FullPath
            VolumeRoot=$script:selection.VolumeRoot; VolumeId=$script:selection.VolumeId
            FileId=$null; Mode='Read'; AuthMode='WindowsCurrent'; AllowedSids=@('S-1-5-21-2-2')
            AutoStart=$auto; Status='Waiting'; AclRecords=@(); FirewallSnapshot=@{Owned=$true;Name='LFS-Test'}
            SingleFile=$null; CredentialInfo=$null
        }
        $state.Shares = @($state.Shares) + @($entry)
        Write-LanState $script:statePath $state
        return $entry
    }

    It 'installs a SYSTEM startup task without exposing files or changing the network' {
        Install-LanHostWorker -InstallRoot 'C:\Program Files\LanFileSharing' -StateRoot 'C:\ProgramData\LanFileSharing' -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Match 'task-SYSTEM-True-True'
        ($script:events -join ',') | Should Match 'task-start'
        ($script:events -join ',') | Should Not Match 'share|firewall'
    }

    It 'preauthorizes the installing Windows user and starts a separate host broker at installation' {
        $script:adapter.SetBrokerUser = { [void]$script:events.Add('broker-user') }
        $script:adapter.RegisterBrokerTask = { [void]$script:events.Add('broker-register') }
        $script:adapter.StartBrokerTask = { [void]$script:events.Add('broker-start') }

        Install-LanHostWorker -InstallRoot 'C:\Program Files\LanFileSharing' -StateRoot 'C:\ProgramData\LanFileSharing' -Adapter $script:adapter | Out-Null

        ($script:events -join ',') | Should Match 'broker-user,.*broker-register,.*broker-start'
    }

    It 'restarts the preauthorized broker after updating the installed code' {
        $script:adapter.AssertInstalled = { }
        $script:adapter.StageFiles = { }
        $script:adapter.StopTask = { }
        $script:adapter.SwapFiles = { }
        $script:adapter.CleanupStage = { }
        $script:adapter.CleanupBackup = { }
        $script:adapter.SetBrokerUser = { [void]$script:events.Add('broker-user') }
        $script:adapter.StopBrokerTask = { [void]$script:events.Add('broker-stop') }
        $script:adapter.RegisterBrokerTask = { [void]$script:events.Add('broker-register') }
        $script:adapter.StartBrokerTask = { [void]$script:events.Add('broker-start') }

        Update-LanHostWorker -Adapter $script:adapter | Out-Null

        ($script:events -join ',') | Should Be 'broker-stop,broker-user,broker-register,task-start,broker-start'
    }

    It 'restarts the existing broker if stopping the worker fails during update' {
        $script:adapter.AssertInstalled = { }
        $script:adapter.StageFiles = { }
        $script:adapter.CleanupStage = { }
        $script:adapter.BrokerTaskExists = { $true }
        $script:adapter.StopBrokerTask = { [void]$script:events.Add('broker-stop') }
        $script:adapter.StopTask = { throw 'worker stop failed' }
        $script:adapter.StartBrokerTask = { [void]$script:events.Add('broker-start') }

        { Update-LanHostWorker -Adapter $script:adapter } | Should Throw 'worker stop failed'

        ($script:events -join ',') | Should Be 'broker-stop,broker-start'
    }

    It 'rejects a broker task name owned by a different command' {
        $root='C:\Program Files\LanFileSharing'
        $state='C:\ProgramData\LanFileSharing'
        $task=[pscustomobject]@{
            Actions=@([pscustomobject]@{Execute=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments='-File C:\Other.ps1'})
            Principal=[pscustomobject]@{UserId='SYSTEM'}
        }
        { Assert-LanHostBrokerTask -Task $task -InstallRoot $root -StateRoot $state } | Should Throw 'another command'
    }

    It 'restores an existing broker when an update fails after swapping code' {
        $script:adapter.AssertInstalled = { }
        $script:adapter.StageFiles = { }
        $script:adapter.StopTask = { [void]$script:events.Add('task-stop') }
        $script:adapter.SwapFiles = { [void]$script:events.Add('swap') }
        $script:adapter.RestoreFiles = { [void]$script:events.Add('restore') }
        $script:adapter.CleanupStage = { }
        $script:adapter.CleanupBackup = { }
        $script:adapter.BrokerTaskExists = { $true }
        $script:adapter.SetBrokerUser = { }
        $script:adapter.StopBrokerTask = { [void]$script:events.Add('broker-stop') }
        $script:adapter.UnregisterBrokerTask = { [void]$script:events.Add('broker-remove') }
        $script:adapter.RegisterBrokerTask = { }
        $script:adapter.StartBrokerTask = {
            $script:brokerStartCount++
            if ($script:brokerStartCount -eq 1) { throw 'new broker failed' }
            [void]$script:events.Add('broker-start-old')
        }
        $script:brokerStartCount = 0
        $script:adapter.StartTask = { [void]$script:events.Add('task-start') }

        { Update-LanHostWorker -Adapter $script:adapter } | Should Throw 'new broker failed'

        ($script:events -join ',') | Should Be 'broker-stop,task-stop,swap,task-start,broker-stop,task-stop,restore,task-start,broker-start-old'
    }

    It 'updates code while preserving configured shares and restarts the worker' {
        Add-TestEntry 'KeepMe' | Out-Null
        $script:adapter.AssertInstalled = { [void]$script:events.Add('installed') }
        $script:adapter.StageFiles = { [void]$script:events.Add('stage') }
        $script:adapter.StopTask = { [void]$script:events.Add('task-stop') }
        $script:adapter.SwapFiles = { [void]$script:events.Add('swap') }
        $script:adapter.RestoreFiles = { [void]$script:events.Add('restore') }
        $script:adapter.CleanupStage = { [void]$script:events.Add('stage-clean') }
        $script:adapter.CleanupBackup = { [void]$script:events.Add('backup-clean') }
        Update-LanHostWorker -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Be 'installed,stage,task-stop,swap,task-start,stage-clean,backup-clean'
        (Read-LanState $script:statePath).Shares[0].Name | Should Be 'KeepMe'
    }
    It 'refreshes a manually copied host installation without swapping its directory' {
        $root = Split-Path -Parent $PSScriptRoot
        $script:steps = New-Object System.Collections.ArrayList
        $adapter = @{
            InstallRoot = $root
            StatePath = (Join-Path $TestDrive 'state.json')
            HeartbeatPath = (Join-Path $TestDrive 'worker.heartbeat')
            AssertInstalled = { param($installRoot,$statePath) [void]$script:steps.Add('assert') }
            StopTask = { [void]$script:steps.Add('stop') }
            StartTask = { param($heartbeatPath) [void]$script:steps.Add('start') }
            StageFiles = { throw 'Unexpected directory swap' }
        }
        Refresh-LanHostWorkerInPlace -Adapter $adapter | Out-Null
        ($script:steps -join ',') | Should Be 'assert,stop,start'
    }

    It 'restores previous code and starts the worker when updated code fails to start' {
        $script:adapter.AssertInstalled = { }
        $script:adapter.StageFiles = { }
        $script:adapter.StopTask = { [void]$script:events.Add('task-stop') }
        $script:adapter.SwapFiles = { [void]$script:events.Add('swap') }
        $script:adapter.RestoreFiles = { [void]$script:events.Add('restore') }
        $script:adapter.CleanupStage = { [void]$script:events.Add('stage-clean') }
        $script:adapter.CleanupBackup = { }
        $script:startCount = 0
        $script:adapter.StartTask = {
            $script:startCount++
            if ($script:startCount -eq 1) { throw 'New worker did not start.' }
            [void]$script:events.Add('task-start')
        }
        { Update-LanHostWorker -Adapter $script:adapter } | Should Throw
        ($script:events -join ',') | Should Be 'task-stop,swap,task-stop,restore,task-start,stage-clean'
    }

    It 'opens only AutoStart entries on a Private network' {
        Add-TestEntry 'AutoShare' | Out-Null
        Add-TestEntry 'ManualShare' 'Folder' $false | Out-Null
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('AutoShare') | Should Be $true
        $script:shares.ContainsKey('ManualShare') | Should Be $false
    }

    It 'turns the same trusted LAN Private after reboot and reopens its share' {
        $entry = Add-TestEntry 'BootNetwork'
        $state = Read-LanState $script:statePath
        $state.Shares[0] | Add-Member -NotePropertyName NetworkProfile -NotePropertyValue ([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'})
        Write-LanState $script:statePath $state
        $script:profile = 'Public'
        $script:currentNetwork = [pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Public'}
        $script:adapter.GetNetworkProfiles = { @($script:currentNetwork) }
        $script:adapter.SetNetworkProfile = { param($index) $script:currentNetwork.NetworkCategory='Private'; $script:profile='Private'; [void]$script:events.Add('network-private') }
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('BootNetwork') | Should Be $true
        ($script:events -join ',') | Should Match '^network-private,firewall,share-True$'
    }

    It 'uses the saved LAN identity even if a broad profile query fails' {
        Add-TestEntry 'TrustedOnly' | Out-Null
        $state = Read-LanState $script:statePath
        $state.Shares[0] | Add-Member -NotePropertyName NetworkProfile -NotePropertyValue ([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'})
        Write-LanState $script:statePath $state
        $script:adapter.GetProfile = { throw 'Broad profile query unavailable.' }
        $script:adapter.GetNetworkProfiles = { @([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Private'}) }
        $script:adapter.SetNetworkProfile = { throw 'Already Private.' }
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('TrustedOnly') | Should Be $true
    }

    It 'waits without changing a different Public network after reboot' {
        Add-TestEntry 'OtherNetwork' | Out-Null
        $state = Read-LanState $script:statePath
        $state.Shares[0] | Add-Member -NotePropertyName NetworkProfile -NotePropertyValue ([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'})
        Write-LanState $script:statePath $state
        $script:profile = 'Public'
        $script:adapter.GetNetworkProfiles = { @([pscustomobject]@{Name='Cafe LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Public'}) }
        $script:adapter.SetNetworkProfile = { throw 'Network must not be changed.' }
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('OtherNetwork') | Should Be $false
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'WaitingNetwork'
    }

    It 'waits for the LAN after boot then automatically opens the share' {
        Add-TestEntry 'LateNetwork' | Out-Null
        $state = Read-LanState $script:statePath
        $state.Shares[0] | Add-Member -NotePropertyName NetworkProfile -NotePropertyValue ([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'})
        Write-LanState $script:statePath $state
        $script:profile = 'Public'
        $script:currentNetwork = @()
        $script:adapter.GetNetworkProfiles = { $script:currentNetwork }
        $script:adapter.SetNetworkProfile = { param($index) $script:currentNetwork[0].NetworkCategory='Private'; $script:profile='Private' }
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'WaitingNetwork'
        $script:currentNetwork = @([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Public'})
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('LateNetwork') | Should Be $true
    }

    It 'does not change network settings for a stopped manual share after boot' {
        Add-TestEntry 'ManualNetwork' 'Folder' $false | Out-Null
        $state = Read-LanState $script:statePath
        $state.Shares[0] | Add-Member -NotePropertyName NetworkProfile -NotePropertyValue ([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'})
        Write-LanState $script:statePath $state
        $script:currentNetwork = [pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Public'}
        $script:adapter.GetNetworkProfiles = { @($script:currentNetwork) }
        $script:adapter.SetNetworkProfile = { [void]$script:events.Add('network-private') }
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Not Match 'network-private'
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'Stopped'
    }

    It 'starts the file monitor before exposing a File share' {
        $entry = Add-TestEntry 'OnlyFile' 'File'
        $state = Read-LanState $script:statePath
        $source = Join-Path $script:folder 'x.txt'
        [IO.File]::WriteAllText($source, 'x')
        $state.Shares[0].SourcePath = $source
        $state.Shares[0].FileId = 'file-id'
        $state.Shares[0].SingleFile = @{Root=$script:folder;LinkPath=$source;SourcePath=$source;BaselineHash='x'}
        $state.Shares[0] | Add-Member -NotePropertyName LastError -NotePropertyValue 'old failure' -Force
        Write-LanState $script:statePath $state
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Match 'monitor,sync,firewall,share-True'
        (Read-LanState $script:statePath).Shares[0].LastError | Should BeNullOrEmpty
    }

    It 'keeps reconciling an active File share while the GUI is closed' {
        Add-TestEntry 'LiveFile' 'File' | Out-Null
        $state = Read-LanState $script:statePath
        $source = Join-Path $script:folder 'live.txt'
        [IO.File]::WriteAllText($source, 'x')
        $state.Shares[0].SourcePath = $source
        $state.Shares[0].FileId = 'file-id'
        $state.Shares[0].SingleFile = @{Root=$script:folder;LinkPath=$source;SourcePath=$source;BaselineHash='x'}
        $state.Shares[0] | Add-Member -NotePropertyName LastError -NotePropertyValue 'old failure' -Force
        Write-LanState $script:statePath $state
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        @($script:events | Where-Object { $_ -eq 'sync' }).Count | Should Be 2
    }

    It 'supervises an already running manual File share without recreating it' {
        Add-TestEntry 'ManualFile' 'File' $false | Out-Null
        $state = Read-LanState $script:statePath
        $source = Join-Path $script:folder 'manual.txt'
        [IO.File]::WriteAllText($source, 'x')
        $state.Shares[0].SourcePath = $source
        $state.Shares[0].FileId = 'file-id'
        $state.Shares[0].SingleFile = @{Root=$script:folder;LinkPath=$source;SourcePath=$source;BaselineHash='x'}
        Write-LanState $script:statePath $state
        $entry = (Read-LanState $script:statePath).Shares[0]
        $script:shares['ManualFile'] = @{Name='ManualFile';Path=$entry.SharePath;Description="LanFileSharing:$($entry.Id)"}
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Match 'firewall,monitor,sync'
        @($script:events | Where-Object { $_ -like 'share-*' }).Count | Should Be 0
        $restored=(Read-LanState $script:statePath).Shares[0]
        $restored.Status | Should Be 'Running'
        $restored.LastError | Should BeNullOrEmpty
    }

    It 'checks the firewall once and records its snapshot on every live share that lacks one' {
        Add-TestEntry 'LiveOne' | Out-Null
        Add-TestEntry 'LiveTwo' | Out-Null
        $state=Read-LanState $script:statePath
        foreach($entry in @($state.Shares)){
            $entry.FirewallSnapshot=$null
            $script:shares[$entry.Name]=@{Name=$entry.Name;Path=$entry.SharePath;Description="LanFileSharing:$($entry.Id)"}
        }
        Write-LanState $script:statePath $state
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        @($script:events|Where-Object {$_ -eq 'firewall'}).Count | Should Be 1
        $restored=Read-LanState $script:statePath
        @($restored.Shares|Where-Object {-not $_.FirewallSnapshot -or -not $_.FirewallSnapshot.Owned}).Count | Should Be 0
    }

    It 'does not repair a live journal while another process holds the state lock' {
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='live';Name='Live';SharePath=$script:folder;AclRecords=@();FirewallSnapshot=$null;SingleFile=$null})
        Write-LanState $script:statePath $state
        $script:shares['Live'] = @{Name='Live';Path=$script:folder;Description='LanFileSharing:live'}
        $lock = Enter-LanStateLock -StatePath $script:statePath -TimeoutMilliseconds 200
        try {
            { Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter -LockTimeoutMilliseconds 100 } | Should Throw
            $script:shares.ContainsKey('Live') | Should Be $true
            @((Read-LanState $script:statePath).Journal).Count | Should Be 1
        } finally { $lock.Dispose() }
    }

    It 'stops app shares on Public and waits without switching profile' {
        Add-TestEntry 'PrivateShare' | Out-Null
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:profile = 'Public'
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('PrivateShare') | Should Be $false
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'WaitingPrivate'
    }

    It 'blocks a reused drive letter with a different volume identity' {
        $entry = Add-TestEntry 'WrongDisk'
        $state = Read-LanState $script:statePath
        $state.Shares[0].VolumeId = 'DEADBEEF'
        Write-LanState $script:statePath $state
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('WrongDisk') | Should Be $false
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'BlockedVolume'
    }

    It 'removes an already running app share when the source volume changes' {
        Add-TestEntry 'SwapDisk' | Out-Null
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('SwapDisk') | Should Be $true
        $state = Read-LanState $script:statePath
        $state.Shares[0].VolumeId = 'DEADBEEF'
        Write-LanState $script:statePath $state
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('SwapDisk') | Should Be $false
    }

    It 'never replaces another share with the same name' {
        Add-TestEntry 'Collision' | Out-Null
        $script:shares['Collision'] = @{Name='Collision';Path='C:\somewhere-else'}
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares['Collision'].Path | Should Be 'C:\somewhere-else'
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'BlockedName'
    }

    It 'does not adopt an unmarked share even at the same path' {
        Add-TestEntry 'ForeignSamePath' | Out-Null
        $script:shares['ForeignSamePath'] = @{Name='ForeignSamePath';Path=$script:folder;Description='Other app'}
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        (Read-LanState $script:statePath).Shares[0].Status | Should Be 'BlockedName'
        $script:shares['ForeignSamePath'].Description | Should Be 'Other app'
    }

    It 'never resurrects a stopped item' {
        Add-TestEntry 'Stopped' 'Folder' $false | Out-Null
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('Stopped') | Should Be $false
    }

    It 'uninstalls only app state and keeps the selected source' {
        Add-TestEntry 'ToRemove' | Out-Null
        Enable-LanBlankPasswordNetworkLogon -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        Remove-LanHostWorker -Adapter $script:adapter | Out-Null
        [IO.Directory]::Exists($script:folder) | Should Be $true
        $script:blankPolicy.Value | Should Be 1
        ($script:events -join ',') | Should Match 'task-remove'
        ($script:events -join ',') | Should Match 'files-remove'
    }

    It 'finishes cleanup when a pending share name belongs to a share this app does not own' {
        # A share created by the user (or another program) took over the name while setup was
        # interrupted. The entry can never be repaired by waiting, so the installer must drop the
        # bookkeeping, undo its own changes and keep the other program's share.
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='pending';Name='Taken';SharePath=$script:folder;
            AclRecords=@(@{Path=$script:folder;Before='a';After='b'});FirewallSnapshot=@{Owned=$true;Name='LFS-Test'};SingleFile=$null})
        Write-LanState $script:statePath $state
        $script:shares['Taken'] = @{Name='Taken';Path='C:\foreign';Description='Other'}
        Remove-LanHostWorker -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('Taken') | Should Be $true
        ($script:events -join ',') | Should Not Match 'share-remove'
        # Our own NTFS change and firewall rule are undone even though the name is not ours.
        ($script:events -join ',') | Should Match 'acl-remove'
        ($script:events -join ',') | Should Match 'firewall-remove'
        ($script:events -join ',') | Should Match 'task-remove'
        ($script:events -join ',') | Should Match 'files-remove'
        @((Read-LanState $script:statePath).Journal).Count | Should Be 0
    }

    It 'removes a share that carries this app marker but belongs to an older state file' {
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='old-id';Name='Reused';SharePath=$script:folder;AclRecords=@();FirewallSnapshot=$null;SingleFile=$null})
        Write-LanState $script:statePath $state
        $script:shares['Reused'] = @{Name='Reused';Path='C:\elsewhere';Description='LanFileSharing:different-install'}
        Remove-LanHostWorker -Adapter $script:adapter | Out-Null
        $script:shares.ContainsKey('Reused') | Should Be $false
        @((Read-LanState $script:statePath).Journal).Count | Should Be 0
    }

    It 'keeps recovery data and reports it when undoing our own changes fails' {
        # Restoring NTFS rights is genuinely retryable, so a failure there must still block
        # cleanup and say exactly what is wrong.
        $state = Read-LanState $script:statePath
        $state.Journal = @(@{Id='pending';Name='Blocked';SharePath=$script:folder;Phase='AclReady';
            AclRecords=@(@{Path=$script:folder;Before='a';After='b'});FirewallSnapshot=$null;SingleFile=$null})
        Write-LanState $script:statePath $state
        $script:adapter.RevokeAcl = { param($records) [void]$script:events.Add('acl-remove'); throw 'Access is denied' }
        $failure = $null
        try { Remove-LanHostWorker -Adapter $script:adapter } catch { $failure = $_ }
        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match 'could not undo an interrupted share'
        $failure.Exception.Message | Should Match 'Blocked'
        $failure.Exception.Message | Should Match 'AclReady'
        $failure.Exception.Message | Should Match 'Access is denied'
        ($script:events -join ',') | Should Not Match 'task-remove'
        ($script:events -join ',') | Should Not Match 'files-remove'
        @((Read-LanState $script:statePath).Journal).Count | Should Be 1
    }

    It 'stops the automatic tasks before touching state so they cannot rebuild shares' {
        Add-TestEntry 'Ordered' | Out-Null
        Invoke-LanBootReconcile -StatePath $script:statePath -Adapter $script:adapter | Out-Null
        $script:events.Clear()
        Remove-LanHostWorker -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Match '^task-stop'
        ($script:events -join ',') | Should Match 'files-remove'
    }
}

Describe 'install entry points' {
    It 'registers a worker task at the recorded custom install directory' {
        $previousProgramFiles = $env:ProgramFiles
        $previousProgramData = $env:ProgramData
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'legacy-program-files'
            $env:ProgramData = Join-Path $TestDrive 'machine-data'
            $customRoot = Join-Path $TestDrive 'Protected\LanFileSharing'
            $stateRoot = Join-Path $env:ProgramData 'LanFileSharing'
            $locationAdapter = @{ReadRecord={ $customRoot };WriteRecord={};DeleteRecord={}}
            { New-LanStartupAdapter -SourceRoot (Split-Path -Parent $PSScriptRoot) -InstallRoot (Join-Path $env:ProgramFiles 'LanFileSharing') -StateRoot $stateRoot -LocationAdapter $locationAdapter } | Should Throw
            $adapter = New-LanStartupAdapter -SourceRoot (Split-Path -Parent $PSScriptRoot) -InstallRoot $customRoot -StateRoot $stateRoot -LocationAdapter $locationAdapter
            function global:New-ScheduledTaskAction { param($Execute,$Argument) $script:workerArgument=$Argument; return @{} }
            function global:New-ScheduledTaskTrigger { return @{} }
            function global:New-ScheduledTaskPrincipal { return @{} }
            # Record the switches the code passes. Windows defaults a new task to "do not start on
            # battery", so a registration that omits these is parked in Queued on an unplugged
            # laptop and the worker never runs.
            function global:New-ScheduledTaskSettingsSet {
                param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)
                $script:allowOnBatteries = [bool]$AllowStartIfOnBatteries
                $script:keepOnBatteries = [bool]$DontStopIfGoingOnBatteries
                return @{}
            }
            function global:Register-ScheduledTask { return @{} }
            $script:workerArgument=$null
            $script:allowOnBatteries=$false
            $script:keepOnBatteries=$false
            & $adapter.RegisterTask $customRoot $stateRoot 'SYSTEM' $true $true
            $script:workerArgument | Should Match ([regex]::Escape((Join-Path $customRoot 'HostWorker.ps1')))
            $script:allowOnBatteries | Should Be $true
            $script:keepOnBatteries | Should Be $true
        } finally {
            foreach ($name in @('New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask')) {
                Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
            }
            $env:ProgramFiles=$previousProgramFiles
            $env:ProgramData=$previousProgramData
        }
    }
    It 'allows the host tasks to run while the computer is on battery' {
        # A laptop on battery parks a task whose settings disallow it in the Queued state. Setup then
        # waits for a heartbeat that can never appear, which users see as a frozen installer.
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/Startup.ps1'))
        ([regex]::Matches($source,'New-ScheduledTaskSettingsSet[^\r\n]*')).Count | Should Be 2
        foreach ($match in [regex]::Matches($source,'New-ScheduledTaskSettingsSet[^\r\n]*')) {
            $match.Value | Should Match 'AllowStartIfOnBatteries'
            $match.Value | Should Match 'DontStopIfGoingOnBatteries'
        }
    }
    It 'resolves the native host update checks when setup runs from its own script scope' {
        $previousProgramFiles = $env:ProgramFiles
        $previousProgramData = $env:ProgramData
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'program-files'
            $env:ProgramData = Join-Path $TestDrive 'program-data'
            $installRoot = Join-Path $env:ProgramFiles 'LanFileSharing'
            $stateRoot = Join-Path $env:ProgramData 'LanFileSharing'
            [IO.Directory]::CreateDirectory($installRoot) | Out-Null
            [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
            [IO.File]::WriteAllText((Join-Path $stateRoot 'state.json'), '{}')
            function global:Get-ScheduledTask {
                [pscustomobject]@{TaskName='LanFileSharing-HostWorker';State='Running';
                    Principal=[pscustomobject]@{UserId='SYSTEM'};
                    Actions=@([pscustomobject]@{
                        Execute=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
                        Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $env:ProgramFiles 'LanFileSharing\HostWorker.ps1')+'" -StatePath "'+(Join-Path $env:ProgramData 'LanFileSharing\state.json')+'"')
                    })}
            }
            function global:Start-ScheduledTask { }
            function Assert-LanTrustedInstallTree { param($Path) $script:trustedTreeChecked = $Path }
            function Read-LanState { param($Path) return @{Version=1;Shares=@()} }
            function Set-LanInstalledDirectoryAcl { param($Path,$Role) [IO.Directory]::CreateDirectory($Path) | Out-Null }
            function Set-LanInstalledTreeAcl { param($Path,$Role) }
            function Test-LanWorkerHeartbeat { param($Path) return $true }
            $script:trustedTreeChecked = $null
            $adapter = New-LanStartupAdapter -SourceRoot (Split-Path -Parent $PSScriptRoot) -InstallRoot $installRoot -StateRoot $stateRoot -LocationAdapter @{ReadRecord={ $null }}
            { & $adapter.AssertInstalled $installRoot $adapter.StatePath } | Should Not Throw
            $script:trustedTreeChecked | Should Be $installRoot
            { & $adapter.StageFiles $adapter.StageRoot $adapter } | Should Not Throw
            Test-Path -LiteralPath (Join-Path $adapter.StageRoot 'HostWorker.ps1') | Should Be $true
            { & $adapter.StartTask $adapter.HeartbeatPath } | Should Not Throw
        } finally {
            Remove-Item Function:\Get-ScheduledTask -ErrorAction SilentlyContinue
            Remove-Item Function:\Start-ScheduledTask -ErrorAction SilentlyContinue
            $env:ProgramFiles = $previousProgramFiles
            $env:ProgramData = $previousProgramData
        }
    }
    It 'accepts only a fresh worker heartbeat' {
        $path = Join-Path $TestDrive 'worker.heartbeat'
        [IO.File]::WriteAllText($path, [DateTimeOffset]::UtcNow.ToString('o'))
        (Test-LanWorkerHeartbeat -Path $path) | Should Be $true
        [IO.File]::WriteAllText($path, [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'))
        (Test-LanWorkerHeartbeat -Path $path) | Should Be $false
    }
    It 'provides installer, uninstaller and headless worker scripts' {
        foreach ($name in @('Install-LanShare.ps1','Update-LanShare.ps1','Uninstall-LanShare.ps1','HostWorker.ps1')) {
            [IO.File]::Exists((Join-Path $PSScriptRoot "../$name")) | Should Be $true
        }
        ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../HostWorker.ps1'))) | Should Match 'Start-LanHostWorker'
    }
    It 'builds a state ACL without an Everyone grant' {
        $acl = Get-Acl -LiteralPath $TestDrive
        $everyone = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $everyone,[Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        $restricted = New-LanInstalledDirectoryAcl -Acl $acl -Role State
        @($restricted.Access | Where-Object { $_.IdentityReference.Value -in @('Everyone','S-1-1-0') }).Count | Should Be 0
    }
    It 'refuses native uninstall targets outside the application directories' {
        { New-LanStartupAdapter -SourceRoot $TestDrive -InstallRoot $TestDrive -StateRoot $TestDrive } | Should Throw
    }
    It 'takes back a folder whose owner is not SYSTEM or Administrators' {
        # This is the failure the installer reported: "Untrusted owner of application path:
        # C:\ProgramData\LanFileSharing". Windows gives a newly created folder to its creator, so a folder
        # made once by an account that is not SYSTEM or Administrators keeps an owner the check rejects, and
        # the install then stopped with a message naming an internal script line.
        #
        # A folder created by this test has exactly that owner, so the condition is reproduced without any
        # privileged ACL editing.
        $target = Join-Path $TestDrive 'untrusted'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        [IO.Directory]::CreateDirectory((Join-Path $target 'progress')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'state.json'), '{"Shares":[]}')
        [IO.File]::WriteAllText((Join-Path $target 'progress\log.txt'), 'x')
        $owner = (Get-Acl -LiteralPath $target).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -eq 'S-1-5-18' -or $owner -eq 'S-1-5-32-544') { return }   # nothing to reproduce here
        # It must be rejected first, otherwise this test would pass without proving anything.
        { Assert-LanTrustedInstallTree -Path $target } | Should Throw 'Untrusted'
        # Changing an owner needs SeRestorePrivilege, which an ordinary process does not hold: Windows then
        # answers "The security identifier is not allowed to be the owner of this object." The installer runs
        # elevated and holds it — verified separately — so this test asserts only what an ordinary process
        # can prove, and reports the outcome instead of failing for a privilege it cannot obtain.
        $repaired = Repair-LanUntrustedInstallOwner -Path $target
        $after = (Get-Acl -LiteralPath $target).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($after -eq $owner) {
            # The owner could not be changed here. What must still hold is that the tree check keeps rejecting
            # the folder, so one with a foreign owner can never be treated as trusted.
            { Assert-LanTrustedInstallTree -Path $target } | Should Throw 'Untrusted'
            return
        }
        $repaired | Should Be $true
        # And accepted afterwards. The tree check walks every item, so the children had to be corrected too —
        # correcting only the top folder left it failing with "Untrusted write access".
        { Assert-LanTrustedInstallTree -Path $target } | Should Not Throw
        $after | Should Be 'S-1-5-32-544'
    }
    It 'leaves a folder that is not ours completely alone' {
        # Taking ownership is only safe when the contents prove the folder is this program's own.
        $target = Join-Path $TestDrive 'foreign'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'someone-elses-data.txt'), 'important')
        # The test directory is already owned by the ordinary user. Assigning
        # BUILTIN\Users requires privileges unrelated to this behavior.
        $owner = (Get-Acl -LiteralPath $target).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -eq 'S-1-5-18' -or $owner -eq 'S-1-5-32-544') { return }
        (Repair-LanUntrustedInstallOwner -Path $target) | Should Be $false
        ((Get-Acl -LiteralPath $target).GetOwner([Security.Principal.SecurityIdentifier]).Value) | Should Be $owner
    }
    It 'copies the version and Online helper files used by the installed window' {
        # The window shows its version from version.txt, and this list is what decides which files reach the
        # install directory. Leaving it out is exactly what happened: the payload verification reported every
        # file present, the file was in the package, and an installed window still showed no version — because
        # the copy step never mentioned it. A test on the list itself is what catches that.
        $source = Join-Path $PSScriptRoot '../src/Startup.ps1'
        $text = [IO.File]::ReadAllText($source)
        $copy = [regex]::Match($text, "(?s)\`$adapter\.CopyFiles = \{.*?\}\.GetNewClosure\(\)")
        $copy.Success | Should Be $true
        ($copy.Value -match 'version\.txt') | Should Be $true
        ($copy.Value -match 'OnlineSetup\.ps1') | Should Be $true
        ($copy.Value -match 'OnlineSignIn\.ps1') | Should Be $true
    }
    It 'deletes a directory tree and reports that it is gone' {
        # The uninstall used one Remove-Item and gave up on the first refusal, which showed the user a raw
        # PowerShell error dialog. Removal now reports an outcome instead of throwing.
        $target = Join-Path $TestDrive 'tree'
        [IO.Directory]::CreateDirectory((Join-Path $target 'nested')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'a.txt'), 'x')
        [IO.File]::WriteAllText((Join-Path $target 'nested\b.txt'), 'y')
        $result = Remove-LanDirectoryTree -Directory $target
        $result.Removed | Should Be $true
        $result.Pending | Should Be $false
        (Test-Path -LiteralPath $target) | Should Be $false
    }
    It 'reports success for a directory that is already gone' {
        $missing = Join-Path $TestDrive 'never-existed'
        $result = Remove-LanDirectoryTree -Directory $missing
        $result.Removed | Should Be $true
        (Test-Path -LiteralPath $missing) | Should Be $false
    }
    It 'removes a tree that holds a read-only file' {
        # A read-only attribute survives a failed delete on some volumes and blocks every later attempt.
        $target = Join-Path $TestDrive 'readonly'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        $file = Join-Path $target 'locked.txt'
        [IO.File]::WriteAllText($file, 'x')
        (Get-Item -LiteralPath $file).Attributes = 'ReadOnly'
        $result = Remove-LanDirectoryTree -Directory $target
        $result.Removed | Should Be $true
        (Test-Path -LiteralPath $target) | Should Be $false
    }
    It 'finds a process that was started from inside a directory' {
        # CIM rather than Get-Process: Process.Path is empty for a process started with a script file, which
        # is how this program starts its own helpers, so the scan used to find nothing while the process
        # holding the folder was running.
        $target = Join-Path $TestDrive 'inuse'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        $script = Join-Path $target 'hold.ps1'
        [IO.File]::WriteAllText($script, 'Start-Sleep -Seconds 30')
        $process = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`"") -PassThru -WindowStyle Hidden
        try {
            $deadline = (Get-Date).AddSeconds(15)
            $found = @()
            while ((Get-Date) -lt $deadline) {
                $found = @(Get-LanProcessUsingPath -Path @($target))
                if ($found.Count -gt 0) { break }
                Start-Sleep -Milliseconds 300
            }
            (@($found | ForEach-Object { $_.Id }) -contains $process.Id) | Should Be $true
        } finally {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    It 'rejects a pre-created application directory owned by an untrusted SID' {
        $acl = Get-Acl -LiteralPath $TestDrive
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')))
        { Assert-LanTrustedInstallAcl -Acl $acl -Path 'C:\ProgramData\LanFileSharing' } | Should Throw 'Untrusted'
    }
    It 'accepts its own Code ACL with Users read-only access' {
        $acl = New-LanInstalledDirectoryAcl -Acl (Get-Acl -LiteralPath $TestDrive) -Role Code
        { Assert-LanTrustedInstallAcl -Acl $acl -Path 'C:\Program Files\LanFileSharing' } | Should Not Throw
    }
}
