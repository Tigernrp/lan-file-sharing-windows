. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/Host.ps1"
. "$PSScriptRoot/../src/InstallLocation.ps1"
. "$PSScriptRoot/../src/Startup.ps1"
. "$PSScriptRoot/../src/HostBridge.ps1"

Describe 'broker list latency regression' {
    It 'uses a short deadline and checks installation liveness for synchronous list requests' {
        Mock Invoke-LanHostBrokerExchange {
            param($Action,$Payload,[int]$WaitMilliseconds=180000,[switch]$HasHeartbeatPath)
            if ($WaitMilliseconds -gt 1000 -or -not $HasHeartbeatPath) { throw 'List would block the UI for minutes' }
            [pscustomobject]@{Available=$true;Result=@()}
        }
        { Invoke-LanHostPreferredExchange -Action List -Payload @{} -HelperPath 'unused.ps1' } | Should Not Throw
    }
}

Describe 'missing installation recovery regression' {
    It 'reports the original repair failure without restarting the missing-code baseline' {
        $script:repairStarts = 0
        $adapter = @{
            InstallRoot='C:\missing\LanFileSharing';StatePath='state';StageRoot='stage';HeartbeatPath='heartbeat';HadInstallDirectory=$false
            AssertInstalled={ };BrokerTaskExists={ $false };StageFiles={ };StopBrokerTask={ };StopTask={ };SwapFiles={ };RestoreFiles={ };CleanupStage={ }
            StartTask={
                $script:repairStarts++
                if ($script:repairStarts -eq 1) { throw 'new files rejected during repair' }
                throw 'cannot restart missing files'
            }
        }
        { Update-LanHostWorker -Adapter $adapter } | Should Throw 'new files rejected during repair'
        $script:repairStarts | Should Be 1
    }

    It 'restores missing application files through the real update adapter while preserving state' {
        $script:repairInstallRoot = Join-Path $TestDrive 'LanFileSharing'
        $script:repairStateRoot = Join-Path $env:ProgramData 'LanFileSharing'
        $location = @{ReadRecord={ $script:repairInstallRoot }}
        Mock Get-ScheduledTask {
            param($TaskName)
            [pscustomobject]@{TaskName=$TaskName;State='Ready';Principal=[pscustomobject]@{UserId='SYSTEM'};
                Actions=@([pscustomobject]@{Execute=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$script:repairInstallRoot+'\HostWorker.ps1" -StatePath "'+$script:repairStateRoot+'\state.json"')})}
        }
        Mock Get-CimInstance { @() }
        $statePath = Join-Path $TestDrive 'preserved-state.json'
        $state = New-LanEmptyState
        $state.BlankPasswordSnapshot = [pscustomobject]@{Present=$true;Value=42}
        Write-LanState $statePath $state
        $adapter = New-LanStartupAdapter -SourceRoot (Split-Path -Parent $PSScriptRoot) -InstallRoot $script:repairInstallRoot -StateRoot $script:repairStateRoot -LocationAdapter $location
        & $adapter.AssertInstalled $script:repairInstallRoot $statePath
        [IO.Directory]::CreateDirectory($adapter.StageRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $adapter.StageRoot 'version.txt'),'new')
        & $adapter.SwapFiles
        [IO.File]::ReadAllText((Join-Path $script:repairInstallRoot 'version.txt')) | Should Be 'new'
        (Read-LanState $statePath).BlankPasswordSnapshot.Value | Should Be 42
        & $adapter.RestoreFiles
        [IO.Directory]::Exists($script:repairInstallRoot) | Should Be $false
    }
}

Describe 'broker create scope regression' {
    It 'reuses the account through the real broker Create action without losing function scope' {
        $folder = Join-Path $TestDrive 'broker-create'
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        Mock Start-LanProgress { }
        Mock Write-LanProgress { }
        Mock Find-LanHostShareAccount { [pscustomobject]@{UserName='LanShare_existing';Sid='S-1-5-21-1-2-3-1001';Password='Existing#Pass1'} }
        Mock Get-LocalUser {
            param($Name)
            if ($Name -ne 'LanShare_existing') { throw 'Unexpected account lookup' }
            [pscustomobject]@{Name='LanShare_existing';Description='LAN File Sharing app account';Enabled=$true;
                SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')}
        }
        # The real adapter now repairs expiry on positively owned reused accounts.
        # Keep that OS operation mocked so this broker regression never changes Windows accounts.
        Mock Set-LocalUser { }
        Mock New-LocalUser { throw 'Must reuse the existing account' }
        Mock Get-LanPublicShares { @() }
        $script:brokerAccess = $null
        Mock Start-LanHostShare {
            param($Access,$Name)
            $script:brokerAccess = $Access
            [pscustomobject]@{Name=$Name;CredentialInfo=$Access.CredentialInfo;InitialPassword=$Access.CredentialInfo.Password;NtfsPolicy='Managed'}
        }
        $result = Invoke-LanHostActionCore -Action Create -Payload @{
            Kind='Folder';Path=$folder;Name='Second';Mode='Read';AuthMode='Protected';
            Principals='';PasswordMethod='Random';Password='Generated#Pass2';AccountName='LanShare_existing';AutoStart=$true
        }
        $result.UserName | Should Be 'LanShare_existing'
        $result.InitialPassword | Should Be 'Existing#Pass1'
        $script:brokerAccess.AllowedSids[0] | Should Be 'S-1-5-21-1-2-3-1001'
    }
}

Describe 'sharing stability regressions' {
    It 'allows only UI observation of a held lease when SYSTEM process query is denied' {
        $id=[guid]::NewGuid().ToString('N');$name='Global\LanFileSharing-Share-'+$id
        $lease=[Threading.Mutex]::new($false,$name);[void]$lease.WaitOne(0)
        $journal=[pscustomobject]@{Id=$id;ActiveLeaseName=$name;ActiveProcessId=$PID;ActiveProcessStartTicks=1}
        $job=$null
        try {
            $job=Start-Job -ArgumentList (Join-Path $PSScriptRoot '../src/Host.ps1'),$journal -ScriptBlock {
                param($module,$journal);. $module
                function Get-LanHostProcessStartTicks { param($Id) return 0 }
                [pscustomobject]@{Strict=(Test-LanActiveJournal $journal);Observed=(Test-LanActiveJournal $journal -AllowLeaseOnly)}
            }
            Wait-Job $job -Timeout 15|Out-Null
            $result=Receive-Job $job -ErrorAction Stop
            $result.Strict|Should Be $false;$result.Observed|Should Be $true
            $lease.ReleaseMutex();$released=$true
            Remove-Job $job -Force;$job=$null
            $job=Start-Job -ArgumentList (Join-Path $PSScriptRoot '../src/Host.ps1'),$journal -ScriptBlock {
                param($module,$journal);. $module
                function Get-LanHostProcessStartTicks { param($Id) return 0 }
                $free=Test-LanActiveJournal $journal -AllowLeaseOnly
                function Get-LanHostProcessStartTicks { param($Id) return 2 }
                [pscustomobject]@{Free=$free;Mismatch=(Test-LanActiveJournal $journal -AllowLeaseOnly)}
            }
            Wait-Job $job -Timeout 15|Out-Null;$result=Receive-Job $job -ErrorAction Stop
            $result.Free|Should Be $false;$result.Mismatch|Should Be $false
        } finally {if($job){Remove-Job $job -Force -ErrorAction SilentlyContinue};if(-not $released){$lease.ReleaseMutex()};$lease.Dispose()}
    }
    It 'recognizes a live transaction lease from a separate worker process and releases it after completion' {
        $id = [guid]::NewGuid().ToString('N')
        $leaseName = 'Global\LanFileSharing-Share-' + $id
        $lease = New-Object Threading.Mutex($false,$leaseName)
        [void]$lease.WaitOne(0)
        $journal = [pscustomobject]@{Id=$id;ActiveLeaseName=$leaseName;ActiveProcessId=$PID;
            ActiveProcessStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
        $job = $null
        try {
            $job = Start-Job -ArgumentList (Join-Path $PSScriptRoot '../src/Host.ps1'),$journal -ScriptBlock {
                param($module,$journal)
                . $module
                Test-LanActiveJournal -Journal $journal
            }
            Wait-Job $job -Timeout 10 | Out-Null
            $job.State | Should Be 'Completed'
            (Receive-Job $job -ErrorAction Stop) | Should Be $true
            $lease.ReleaseMutex()
            (Test-LanActiveJournal -Journal $journal) | Should Be $false
        } finally {
            if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            $lease.Dispose()
        }
    }


    It 'checks the broker task instead of validating the worker as a broker' {
        $install = Get-LanDefaultInstallRoot -Is64BitOs ([Environment]::Is64BitOperatingSystem)
        $stateRoot = Join-Path $env:ProgramData 'LanFileSharing'
        Mock Get-ScheduledTask {
            param($TaskName)
            $brokerSwitch = if ($TaskName -eq 'LanFileSharing-HostBroker') { ' -Broker' } else { '' }
            [pscustomobject]@{TaskName=$TaskName;Principal=[pscustomobject]@{UserId='SYSTEM';RunLevel='Highest'};
                Actions=@([pscustomobject]@{Execute=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$install+'\HostWorker.ps1" -StatePath "'+$stateRoot+'\state.json"'+$brokerSwitch)})}
        }
        $adapter = New-LanStartupAdapter -SourceRoot (Split-Path -Parent $PSScriptRoot) -InstallRoot $install -StateRoot $stateRoot
        (& $adapter.BrokerTaskExists) | Should Be $true
        Assert-MockCalled Get-ScheduledTask -Times 1 -Exactly -Scope It -ParameterFilter { $TaskName -eq 'LanFileSharing-HostBroker' }
    }

    It 'starts an idle worker and waits for its heartbeat within the same request' {
        $script:workerStarted = $false
        Mock Test-LanWorkerHeartbeat { $script:workerStarted }
        Mock Get-LanScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Start-ScheduledTask { $script:workerStarted = $true }
        $adapter = New-LanHostAdapter
        { & $adapter.EnsureWorker } | Should Not Throw
        $script:workerStarted | Should Be $true
    }

    It 'allows worker reconciliation during NTFS work without rolling back the active journal or losing state changes' {
        $folder = Join-Path $TestDrive 'large-share'
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        $selection = Resolve-LanSelection -Kind Folder -Path $folder
        $script:concurrentStatePath = Join-Path $TestDrive 'concurrent.json'
        $script:liveShares = @{}
        $script:recoveryRevoked = $false
        $script:firewallRemoved = $false
        $script:shareAdapter = @{
            GetShare = { param($name) $script:liveShares[$name] }
            GetProfile = { 'Private' }
            GetNetworkProfiles = { @([pscustomobject]@{Name='Test LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Private'}) }
            EnableFirewall = { @{Owned=$true;Name='test'} }
            RemoveFirewall = { $script:firewallRemoved = $true }
            RevokeAcl = { $script:recoveryRevoked = $true }
            GrantAcl = {
                param($path,$sids,$mode,$beforeApply)
                # Simulate the expensive scan while the actual state lock must be available.
                $lock = Enter-LanStateLock -StatePath $script:concurrentStatePath -TimeoutMilliseconds 0
                $lock.Dispose()
                $record = [pscustomobject]@{Path=$path;Before='before';After='after'}
                & $beforeApply $record
                $stale = Read-LanState $script:concurrentStatePath
                $stale.Journal = @($stale.Journal) + @([pscustomobject]@{Id='crashed';Name='Crashed';
                    SharePath='C:\missing';AclRecords=@();SingleFile=$null;FirewallSnapshot=@{Owned=$true;Name='test'}})
                Write-LanState $script:concurrentStatePath $stale
                Invoke-LanBootReconcile -StatePath $script:concurrentStatePath -Adapter $script:shareAdapter -LockTimeoutMilliseconds 0 | Out-Null
                $during = Read-LanState $script:concurrentStatePath
                @($during.Journal).Count | Should Be 1
                @($during.Journal[0].AclRecords).Count | Should Be 1
                $during.BlankPasswordSnapshot = [pscustomobject]@{Present=$true;Value=1}
                Write-LanState $script:concurrentStatePath $during
                return @($record)
            }
            NewShare = { param($name,$path,$mode,$sids,$temporary,$id) $script:liveShares[$name] = @{Path=$path;Description="LanFileSharing:$id"} }
        }
        $access = [pscustomobject]@{AuthMode='WindowsCurrent';AllowedSids=@('S-1-5-11');CredentialInfo=$null}
        $entry = Start-LanHostShare -Selection $selection -Name 'Large' -Mode Read -Access $access -AutoStart $false -StatePath $script:concurrentStatePath -Adapter $script:shareAdapter
        $entry.Status | Should Be 'Running'
        $script:recoveryRevoked | Should Be $false
        $script:firewallRemoved | Should Be $false
        $saved = Read-LanState $script:concurrentStatePath
        $saved.BlankPasswordSnapshot.Value | Should Be 1
        @($saved.Journal).Count | Should Be 0
        @($saved.Shares).Count | Should Be 1
    }

    It 'keeps the account of an existing share when another share fails' {
        $folder = Join-Path $TestDrive 'existing'
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        $selection = Resolve-LanSelection -Kind Folder -Path $folder
        $path = Join-Path $TestDrive 'state.json'
        $state = New-LanEmptyState
        $state.Shares = @([pscustomobject]@{Id='existing';Name='Existing';SourcePath=$folder;
            CredentialInfo=[pscustomobject]@{UserName='LanShare_test';Sid='S-1-5-21-1-2-3-1001'}})
        Write-LanState -Path $path -State $state
        $script:removedAccount = $false
        $adapter = @{
            EnsureWorker = { throw 'worker unavailable' }
            DisableProtected = { param($name) $script:removedAccount = $true }
        }
        $access = [pscustomobject]@{AuthMode='Protected';AllowedSids=@('S-1-5-21-1-2-3-1001');
            CredentialInfo=[pscustomobject]@{UserName='LanShare_test';Sid='S-1-5-21-1-2-3-1001';Password='Existing#Pass1'}}
        { Start-LanHostShare -Selection $selection -Name 'Second' -Mode Read -Access $access -StatePath $path -Adapter $adapter } | Should Throw 'worker unavailable'
        $script:removedAccount | Should Be $false
        (Read-LanState $path).Shares[0].Name | Should Be 'Existing'
    }

    It 'rejects a different password before changing the account shared by other shares' {
        Mock Get-LocalUser {
            param($Name)
            if ($Name -ne 'LanShare_test') { throw 'Unexpected account lookup' }
            [pscustomobject]@{Name='LanShare_test';Description='LAN File Sharing app account';Enabled=$true;
                SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')}
        }
        Mock Set-LocalUser { }
        Mock New-LocalUser { throw 'Must reuse the existing account' }
        $adapter = New-LanAuthAdapter
        $reuse = [pscustomobject]@{UserName='LanShare_test';Sid='S-1-5-21-1-2-3-1001';Password='Existing#Pass1'}
        { & $adapter.CreateProtected 'Different#Pass2' $reuse } | Should Throw 'existing share account'
        Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
        $credential = & $adapter.CreateProtected '' $reuse
        $credential.Password | Should Be 'Existing#Pass1'
    }

    It 'only closes executables and script hosts actually running inside the install directory' {
        $root = Join-Path $TestDrive 'install'
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ProcessId=$PID;Name='powershell.exe';ExecutablePath='C:\Windows\powershell.exe';CommandLine=('powershell -File "'+$root+'\Installer-Action.ps1"')},
                [pscustomobject]@{ProcessId=10001;Name='powershell.exe';ExecutablePath='C:\Windows\powershell.exe';CommandLine=('powershell -File "C:\Temp\Installer-Action.ps1" -InstallRoot "'+$root+'"')},
                [pscustomobject]@{ProcessId=10002;Name='powershell.exe';ExecutablePath='C:\Windows\powershell.exe';CommandLine=('powershell -File "'+$root+'\HostWorker.ps1"')},
                [pscustomobject]@{ProcessId=10003;Name='LanFileSharing.exe';ExecutablePath=($root+'\LanFileSharing.exe');CommandLine=''},
                [pscustomobject]@{ProcessId=10004;Name='powershell.exe';ExecutablePath='C:\Windows\powershell.exe';CommandLine=('powershell -File "'+$root+'-other\unrelated.ps1"')}
            )
        }
        $found = @(Get-LanProcessUsingPath -Path @($root))
        ($found.Id -join ',') | Should Be '10002,10003'
    }
}

Describe 'state lock reacquisition regression' {
    It 'retains concurrent state and an inactive recovery journal if reacquiring the lock fails' {
        $folder = Join-Path $TestDrive 'reacquire'
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        $selection = Resolve-LanSelection -Kind Folder -Path $folder
        $script:reacquirePath = Join-Path $TestDrive 'reacquire.json'
        $script:realEnterLock = ${function:Enter-LanStateLock}
        $script:lockCalls = 0
        Mock Enter-LanStateLock {
            param($StatePath,$TimeoutMilliseconds)
            $script:lockCalls++
            if ($script:lockCalls -eq 2) { throw 'simulated lock reacquisition timeout' }
            & $script:realEnterLock -StatePath $StatePath -TimeoutMilliseconds 0
        }
        $adapter = @{
            GetShare = { $null }
            GetNetworkProfiles = { @([pscustomobject]@{Name='Test';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Private'}) }
            EnableFirewall = { @{Owned=$true;Name='test'} }
            RemoveFirewall = { }
            GrantAcl = {
                $concurrent = Read-LanState $script:reacquirePath
                $concurrent.BlankPasswordSnapshot = [pscustomobject]@{Present=$true;Value=42}
                Write-LanState $script:reacquirePath $concurrent
                @()
            }
        }
        $access = [pscustomobject]@{AuthMode='WindowsCurrent';AllowedSids=@('S-1-5-11');CredentialInfo=$null}
        { Start-LanHostShare -Selection $selection -Name 'Reacquire' -Mode Read -Access $access -AutoStart $false -StatePath $script:reacquirePath -Adapter $adapter } | Should Throw 'reacquisition timeout'
        $saved = Read-LanState $script:reacquirePath
        $saved.BlankPasswordSnapshot.Value | Should Be 42
        @($saved.Journal).Count | Should Be 1
        (Test-LanActiveJournal -Journal $saved.Journal[0]) | Should Be $false
        $recovery = Repair-LanHostState -StatePath $script:reacquirePath -Adapter $adapter
        @($recovery.Pending).Count | Should Be 0
    }
}
