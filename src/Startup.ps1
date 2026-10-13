$script:LanActiveMonitors = @{}

function Get-LanScheduledTask {
    param([string]$TaskName = 'LanFileSharing-HostWorker')
    # Defined here as well as in InstallLocation.ps1, and that is deliberate.
    #
    # The adapter script blocks below call this, and a script block does not reliably see a function that was
    # defined in a different module: an update run through Update-LanShare.ps1 failed with "The term
    # 'Get-LanScheduledTask' is not recognized" and stopped the install, leaving the program on its old version
    # with no way forward from the installer. Defining it in the same file as the callers removes the
    # dependency on load order instead of relying on it.
    #
    # The name has a default because the function is also called with no argument at all, and a mandatory one
    # was refused by parameter binding with "Cannot bind argument to parameter 'TaskName' because it is an empty
    # string" — which failed the install at the last step, after the files had already been put in place.
    #
    # This machine's CIM bridge raises a terminating error for a missing task even with -ErrorAction
    # SilentlyContinue, which aborted installs and resets. Return $null instead.
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = 'LanFileSharing-HostWorker' }
    try { return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch { return $null }
}

function Get-LanProcessUsingPath {
    # Every running process whose program file lives inside one of these directories.
    #
    # A worker, a broker, a tray window or a leftover PowerShell host started from the install folder holds
    # a handle on it, and Windows then refuses to delete the folder with "the file is being used by another
    # process" — which is exactly what the uninstall reported. Stopping them is the first thing to try.
    #
    # CIM is used rather than Get-Process: Process.Path is empty for a process started with a script file,
    # which is precisely how this program starts its own helpers, so the scan found nothing while the
    # offending process was running.
    param([Parameter(Mandatory)][string[]]$Path)
    $roots = @($Path | ForEach-Object { ([IO.Path]::GetFullPath($_)).TrimEnd('\') })
    $found = @()
    try {
        foreach ($item in @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)) {
            if ([int]$item.ProcessId -eq $PID) { continue }
            $file = [string]$item.ExecutablePath
            $command = [string]$item.CommandLine
            $scriptPath = ''
            if ([string]$item.Name -match '^(powershell|pwsh)(\.exe)?$') {
                $scriptArgument = [regex]::Match($command, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))')
                if ($scriptArgument.Success) {
                    $scriptPath = if ($scriptArgument.Groups[1].Success) { $scriptArgument.Groups[1].Value } else { $scriptArgument.Groups[2].Value }
                }
            }
            foreach ($root in $roots) {
                $inPath = $file -and $file.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
                # A process whose command line names the folder is holding it too, even when its program file
                # lives elsewhere — an elevated helper started with -File is the common case.
                $inCommand = $scriptPath -and $scriptPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
                if ($inPath -or $inCommand) {
                    $found += [pscustomobject]@{ Id=[int]$item.ProcessId; Name=[string]$item.Name }
                    break
                }
            }
        }
    } catch { }
    return $found
}

function Close-LanProcessesUsingPath {
    # Stops those processes and waits briefly for their handles to be released.
    param([Parameter(Mandatory)][string[]]$Path,
          [scriptblock]$Log)
    $stopped = @()
    foreach ($process in @(Get-LanProcessUsingPath -Path $Path)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $stopped += $process.Id
            if ($Log) { & $Log "ปิดโปรแกรมที่ยังทำงานอยู่: $($process.Name) ($($process.Id))" }
        } catch { }
    }
    if (@($stopped).Count -gt 0) {
        # Windows releases the directory handle asynchronously after a process ends; deleting immediately
        # would race it and fail with the same message the process itself caused.
        foreach ($wait in @(300, 700, 1500)) {
            Start-Sleep -Milliseconds $wait
            if (@(Get-LanProcessUsingPath -Path $Path).Count -eq 0) { break }
        }
    }
    return $stopped
}

function Register-LanPendingDirectoryDelete {
    # Marks a directory for deletion at the next start, for the case where a handle is still held.
    #
    # None of this program's processes can be found holding the folder, yet Windows still refuses: a scanner,
    # an open Explorer window or a file indexer can hold it too. Rather than failing the whole uninstall and
    # showing a PowerShell error, the folder is queued through PendingFileRenameOperations, which Windows
    # acts on before most drivers load.
    param([Parameter(Mandatory)][string]$Directory)
    try {
        $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $entry = '\??\' + $full
        $existing = @()
        try {
            $existing = @((Get-ItemProperty -LiteralPath $key -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations)
        } catch { }
        if ($existing -contains $entry) { return $true }
        $updated = @($existing) + @($entry, '')
        Set-ItemProperty -LiteralPath $key -Name PendingFileRenameOperations -Value $updated -Type MultiString -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Remove-LanDirectoryTree {
    # Deletes a directory, dealing with the two reasons Windows refuses.
    #
    # The uninstall used a single `Remove-Item -Recurse -Force` and gave up on the first refusal, which
    # surfaced as a raw PowerShell error dialog — "Cannot remove item ... because it is being used by
    # another process" — that told the user nothing they could act on. This stops anything running from the
    # folder, retries while handles are released, and falls back to a deletion at the next start.
    param([Parameter(Mandatory)][string]$Directory,
          [scriptblock]$Log)
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if (-not [IO.Directory]::Exists($full)) { return [pscustomobject]@{ Removed=$true; Pending=$false } }
    $write = { param($text) try { if ($Log) { & $Log $text } } catch { } }
    foreach ($attempt in 1..3) {
        if (-not [IO.Directory]::Exists($full)) { return [pscustomobject]@{ Removed=$true; Pending=$false } }
        try {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
            return [pscustomobject]@{ Removed=$true; Pending=$false }
        } catch {
            $reason = $_.Exception.Message
            if ($attempt -eq 1) {
                & $write "ลบโฟลเดอร์ไม่สำเร็จในครั้งแรก ($reason) — ปิดโปรแกรมที่ค้างอยู่แล้วลองใหม่"
            } else {
                Start-Sleep -Milliseconds (400 * $attempt)
                # A read-only attribute survives a failed delete on some volumes and blocks every later try.
                try {
                    Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
                } catch { }
            }
            [void](Close-LanProcessesUsingPath -Path @($full) -Log $Log)
        }
    }
    if (-not [IO.Directory]::Exists($full)) { return [pscustomobject]@{ Removed=$true; Pending=$false } }
    $queued = Register-LanPendingDirectoryDelete -Directory $full
    if ($queued) { & $write "ลบโฟลเดอร์ตอนนี้ไม่ได้ ตั้งไว้ให้ลบตอนเปิดเครื่องครั้งหน้า: $full" }
    else { & $write "ลบโฟลเดอร์ไม่ได้และตั้งเวลาลบไม่ได้: $full" }
    return [pscustomobject]@{ Removed=$false; Pending=$queued }
}


function Invoke-LanRecordedHostInstall {
    param([Parameter(Mandatory)][string]$InstallRoot,
          [Parameter(Mandatory)][string]$StateRoot,
          [string]$SourceRoot,
          [hashtable]$Adapter,
          [hashtable]$LocationAdapter)
    $record=if($LocationAdapter){Get-LanInstallRecord -Adapter $LocationAdapter}else{Get-LanInstallRecord}
    if($record -and -not [string]::Equals([string]$record.InstallRoot,$InstallRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The install target differs from the recorded installation.'
    }
    if(-not $record) {
        if($LocationAdapter){Write-LanInstallRecord -Path $InstallRoot -Adapter $LocationAdapter}
        else{Write-LanInstallRecord -Path $InstallRoot}
    }
    try {
        if(-not $Adapter){$Adapter=New-LanStartupAdapter -SourceRoot $SourceRoot -InstallRoot $InstallRoot -StateRoot $StateRoot}
        return Install-LanHostWorker -InstallRoot $InstallRoot -StateRoot $StateRoot -Adapter $Adapter
    } catch {
        throw "Host installation failed. The install location record was retained for repair or clean reset: $($_.Exception.Message)"
    }
}

function Ensure-LanHostWorkerTask {
    param([Parameter(Mandatory)][string]$InstallRoot,
          [Parameter(Mandatory)][string]$StateRoot,
          [hashtable]$Adapter)
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $state = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    if (-not $Adapter) {
        $Adapter = New-LanStartupAdapter -SourceRoot $install -InstallRoot $install -StateRoot $state
    }
    $record = if ($Adapter.GetInstallRecord) { & $Adapter.GetInstallRecord } else { Get-LanInstallRecord }
    if (-not $record -or -not [string]::Equals([string]$record.InstallRoot,$install,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Host Worker repair requires the recorded install location.'
    }
    # Same reasoning as the state folder: a folder this program owns but whose owner drifted is repaired
    # rather than reported. Refusing here would leave a machine that cannot install and cannot repair.
    [void](Repair-LanUntrustedInstallOwner -Path $install)
    if ($Adapter.AssertTrustedTree) { & $Adapter.AssertTrustedTree $install }
    else { Assert-LanTrustedInstallTree -Path $install }
    if (-not [IO.File]::Exists((Join-Path $install 'HostWorker.ps1'))) {
        throw 'Host Worker script is missing from the recorded installation.'
    }
    $task = if ($Adapter.GetTask) { & $Adapter.GetTask }
            else { Get-LanScheduledTask -TaskName '' }
    if ($task) {
        if (-not $Adapter.GetTask) {
            $expectedExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $expectedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $install 'HostWorker.ps1') + '" -StatePath "' + (Join-Path $state 'state.json') + '"'
            if (@($task.Actions).Count -ne 1 -or
                -not [string]::Equals([string]$task.Actions[0].Execute,$expectedExe,[StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$task.Actions[0].Arguments,$expectedArgs,[StringComparison]::OrdinalIgnoreCase) -or
                [string]$task.Principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18')) {
                throw 'Host Worker task name belongs to another command; repair was refused.'
            }
        }
        return [pscustomobject]@{Repaired=$false}
    }
    & $Adapter.RegisterTask $install $state 'SYSTEM' $true $true | Out-Null
    $heartbeat = if ($Adapter.HeartbeatPath) { [string]$Adapter.HeartbeatPath }
                 else { Join-Path $state 'worker.heartbeat' }
    & $Adapter.StartTask $heartbeat | Out-Null
    return [pscustomobject]@{Repaired=$true}
}

function Assert-LanHostBrokerTask {
    param([Parameter(Mandatory)]$Task,
          [Parameter(Mandatory)][string]$InstallRoot,
          [Parameter(Mandatory)][string]$StateRoot)
    $expectedExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $expectedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallRoot 'HostWorker.ps1') + '" -StatePath "' + (Join-Path $StateRoot 'state.json') + '" -Broker'
    if (@($Task.Actions).Count -ne 1 -or
        -not [string]::Equals([string]$Task.Actions[0].Execute,$expectedExe,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$Task.Actions[0].Arguments,$expectedArgs,[StringComparison]::OrdinalIgnoreCase) -or
        [string]$Task.Principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18')) {
        throw 'Host broker task name belongs to another command; changing it was refused.'
    }
}

function Install-LanHostWorker {
    param([Parameter(Mandatory)][string]$InstallRoot,
          [Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][hashtable]$Adapter)
    if ($Adapter.AssertNotInstalled) { & $Adapter.AssertNotInstalled }
    & $Adapter.SecureDirectory $InstallRoot 'Code' | Out-Null
    & $Adapter.SecureDirectory $StateRoot 'State' | Out-Null
    & $Adapter.CopyFiles $InstallRoot | Out-Null
    if ($Adapter.SecureTree) { & $Adapter.SecureTree $InstallRoot 'Code' | Out-Null }
    if ($Adapter.SetBrokerUser) { & $Adapter.SetBrokerUser | Out-Null }
    & $Adapter.RegisterTask $InstallRoot $StateRoot 'SYSTEM' $true $true | Out-Null
    & $Adapter.StartTask $Adapter.HeartbeatPath | Out-Null
    if ($Adapter.RegisterBrokerTask) { & $Adapter.RegisterBrokerTask | Out-Null }
    if ($Adapter.StartBrokerTask) { & $Adapter.StartBrokerTask | Out-Null }
    return [pscustomobject]@{Installed=$true;InstallRoot=$InstallRoot;StateRoot=$StateRoot}
}

function Update-LanHostWorker {
    param([Parameter(Mandatory)][hashtable]$Adapter)
    & $Adapter.AssertInstalled $Adapter.InstallRoot $Adapter.StatePath | Out-Null
    $brokerWasInstalled = if ($Adapter.BrokerTaskExists) { [bool](& $Adapter.BrokerTaskExists) } else { $false }
    $staged = $false
    $brokerStopped = $false
    $stopped = $false
    $swapped = $false
    try {
        & $Adapter.StageFiles $Adapter.StageRoot $Adapter | Out-Null
        $staged = $true
        if ($Adapter.StopBrokerTask) {
            & $Adapter.StopBrokerTask | Out-Null
            $brokerStopped = $true
        }
        & $Adapter.StopTask | Out-Null
        $stopped = $true
        & $Adapter.SwapFiles | Out-Null
        $swapped = $true
        if ($Adapter.SetBrokerUser) { & $Adapter.SetBrokerUser | Out-Null }
        if ($Adapter.RegisterBrokerTask) { & $Adapter.RegisterBrokerTask | Out-Null }
        & $Adapter.StartTask $Adapter.HeartbeatPath | Out-Null
        if ($Adapter.StartBrokerTask) { & $Adapter.StartBrokerTask | Out-Null }
    } catch {
        $failure = $_
        if ($swapped) {
            try {
                if ($Adapter.StopBrokerTask) { & $Adapter.StopBrokerTask | Out-Null }
                if (-not $brokerWasInstalled -and $Adapter.UnregisterBrokerTask) { & $Adapter.UnregisterBrokerTask | Out-Null }
                & $Adapter.StopTask | Out-Null
                & $Adapter.RestoreFiles | Out-Null
            }
            catch { throw "Update failed and the old files could not be restored: $($_.Exception.Message)" }
        }
        $canRestartOriginal = -not $Adapter.ContainsKey('HadInstallDirectory') -or [bool]$Adapter.HadInstallDirectory
        if ($stopped -and $canRestartOriginal) {
            try {
                & $Adapter.StartTask $Adapter.HeartbeatPath | Out-Null
                if ($brokerWasInstalled -and $Adapter.StartBrokerTask) { & $Adapter.StartBrokerTask | Out-Null }
            }
            catch { throw "Update failed and the worker could not be restarted: $($_.Exception.Message)" }
        } elseif ($brokerStopped -and $brokerWasInstalled -and $Adapter.StartBrokerTask -and $canRestartOriginal) {
            try { & $Adapter.StartBrokerTask | Out-Null }
            catch { throw "Update failed and the host broker could not be restarted: $($_.Exception.Message)" }
        }
        throw $failure
    } finally {
        if ($staged) { & $Adapter.CleanupStage | Out-Null }
    }
    & $Adapter.CleanupBackup | Out-Null
    return [pscustomobject]@{Updated=$true}
}

function Refresh-LanHostWorkerInPlace {
    param([Parameter(Mandatory)][hashtable]$Adapter)
    $required = @('LanShare.ps1','Start-LanShare.cmd','HostWorker.ps1',
        'Install-LanShare.ps1','Update-LanShare.ps1','Uninstall-LanShare.ps1')
    $required += @('Selection','State','Auth','SingleFile','Host','ClientMap','Startup','Ui','Network' |
        ForEach-Object { "src/$_.ps1" })
    foreach ($name in $required) {
        if (-not [IO.File]::Exists((Join-Path $Adapter.InstallRoot $name))) {
            throw "Installed host file is missing: $name"
        }
    }
    & $Adapter.AssertInstalled $Adapter.InstallRoot $Adapter.StatePath | Out-Null
    if ($Adapter.StopBrokerTask) { & $Adapter.StopBrokerTask | Out-Null }
    & $Adapter.StopTask | Out-Null
    if ($Adapter.SetBrokerUser) { & $Adapter.SetBrokerUser | Out-Null }
    if ($Adapter.RegisterBrokerTask) { & $Adapter.RegisterBrokerTask | Out-Null }
    & $Adapter.StartTask $Adapter.HeartbeatPath | Out-Null
    if ($Adapter.StartBrokerTask) { & $Adapter.StartBrokerTask | Out-Null }
    return [pscustomobject]@{Refreshed=$true;InstallRoot=$Adapter.InstallRoot}
}

function Stop-LanActiveMonitor {
    param([string]$Id)
    if ($script:LanActiveMonitors.ContainsKey($Id)) {
        $monitor = $script:LanActiveMonitors[$Id]
        if ($monitor -is [IDisposable]) { $monitor.Dispose() }
        $script:LanActiveMonitors.Remove($Id)
    }
}

function Suspend-LanOwnedShare {
    param($Entry, $Actual, [hashtable]$Adapter)
    if (Test-LanOwnedShare -Actual $Actual -Path $Entry.SharePath -Id $Entry.Id) {
        & $Adapter.RemoveShare $Entry.Name | Out-Null
    }
    Stop-LanActiveMonitor $Entry.Id
}

function Invoke-LanBootReconcileCore {
    param([Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter)
    Repair-LanHostStateCore -StatePath $StatePath -Adapter $Adapter | Out-Null
    $state = Read-LanState -Path $StatePath
    Update-LanShareOnlineSnapshot -State $state -Adapter $Adapter
    $results = @()
    # Validate/repair the one shared SMB firewall rule at most once per reconcile, whether each
    # saved share already exists or must be recreated. This keeps a live share reachable if Windows
    # or a security utility disables the app-owned rule, without repeating NetSecurity queries per share.
    $firewallReady=$false
    $firewallSnapshot=$null
    foreach ($entry in @($state.Shares)) {
        $actual = & $Adapter.GetShare $entry.Name
        if (-not $entry.AutoStart -and -not $actual) {
            $entry.Status = 'Stopped'
            $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
            continue
        }
        if ($actual -and -not (Test-LanOwnedShare -Actual $actual -Path $entry.SharePath -Id $entry.Id)) {
            $entry.Status = 'BlockedName'
            $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
            continue
        }
        if ($entry.NetworkProfile) {
            try {
                $active = Ensure-LanShareNetwork -Adapter $Adapter -Expected $entry.NetworkProfile
                # The share followed the machine onto another network, so the recorded network is
                # updated. Without this the next reconcile would look for the old one again and the
                # share would flap between working and waiting every time the laptop moved.
                if ($active -and $active.Changed) {
                    $entry.NetworkProfile = $active
                    $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $null -Force
                }
            }
            catch {
                Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
                $entry.Status = 'WaitingNetwork'
                $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $_.Exception.Message -Force
                $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
                continue
            }
        } elseif ($Adapter.OnlineContext -and $Adapter.OnlineContext.Ready) {
            $entry.NetworkProfile=Ensure-LanShareNetwork -Adapter $Adapter
        } else {
            try { $profile = & $Adapter.GetProfile }
            catch { $profile = 'Public' }
            if ($profile -ne 'Private') {
                Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
                $entry.Status = 'WaitingPrivate'
                $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
                continue
            }
        }
        try {
            $selection = Resolve-LanSelection -Kind $entry.Kind -Path $entry.SourcePath
        } catch {
            Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
            $entry.Status = 'WaitingSource'
            $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
            continue
        }
        if ($selection.VolumeId -ne $entry.VolumeId) {
            Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
            $entry.Status = 'BlockedVolume'
            $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
            continue
        }
        try { Assert-LanShareRoot -Selection $selection | Out-Null }
        catch {
            Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
            $entry.Status = 'BlockedScope'
            $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
            continue
        }
        if ($entry.Kind -eq 'File') {
            $fileId = & $Adapter.GetFileId $entry.SourcePath
            if ($entry.FileId -and $entry.FileId -ne $fileId) {
                Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
                $entry.Status = 'BlockedFileIdentity'
                $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
                continue
            }
        }
        if ($entry.AuthMode -eq 'Guest') {
            $guest = Get-LanGuestCompatibility -Role Host -Adapter $Adapter
            if (-not $guest.Supported -or @($guest.RequiredChanges).Count -gt 0) {
                Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
                $entry.Status = 'BlockedGuest'
                $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
                continue
            }
        }
        if ($actual) {
            try {
                if (-not $firewallReady) {
                    $firewallSnapshot=& $Adapter.EnableFirewall $Adapter
                    $firewallReady=$true
                }
                if (-not $entry.FirewallSnapshot) { $entry.FirewallSnapshot=$firewallSnapshot }
                if (-not (& $Adapter.VerifyAcl $entry.AclRecords)) { throw 'NTFS permissions changed after activation.' }
                if ($entry.Kind -eq 'File') {
                    if (-not $script:LanActiveMonitors.ContainsKey($entry.Id)) {
                        $monitor = & $Adapter.StartMonitor $entry.SingleFile
                        if ($monitor) { $script:LanActiveMonitors[$entry.Id] = $monitor }
                    }
                    $sync = & $Adapter.SyncFile $entry.SingleFile
                    if ($sync.Status -in @('Conflict','MissingSource','MissingLink')) { throw "Single-file synchronization: $($sync.Status)" }
                    $entry.FileId = & $Adapter.GetFileId $entry.SourcePath
                }
                $entry.Status = 'Running'
                $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $null -Force
            } catch {
                Suspend-LanOwnedShare -Entry $entry -Actual $actual -Adapter $Adapter
                $entry.Status = 'BlockedStart'
                $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $_.Exception.Message -Force
            }
            $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
            continue
        }
        try {
            if (-not (& $Adapter.VerifyAcl $entry.AclRecords)) { throw 'NTFS permissions changed after activation.' }
            if ($entry.Kind -eq 'File') {
                if (-not $entry.SingleFile -or -not [IO.Directory]::Exists($entry.SingleFile.Root)) { throw 'Single-file root is missing.' }
                if (-not $script:LanActiveMonitors.ContainsKey($entry.Id)) {
                    $monitor = & $Adapter.StartMonitor $entry.SingleFile
                    if ($monitor) { $script:LanActiveMonitors[$entry.Id] = $monitor }
                }
                $sync = & $Adapter.SyncFile $entry.SingleFile
                if ($sync.Status -eq 'Conflict' -or $sync.Status -eq 'MissingSource' -or $sync.Status -eq 'MissingLink') {
                    throw "Single-file synchronization: $($sync.Status)"
                }
                $entry.FileId = & $Adapter.GetFileId $entry.SourcePath
            }
            if (-not $firewallReady) {
                $firewallSnapshot=& $Adapter.EnableFirewall $Adapter
                $firewallReady=$true
            }
            if (-not $entry.FirewallSnapshot) { $entry.FirewallSnapshot=$firewallSnapshot }
            if ($entry.NetworkProfile) {
                $active = Ensure-LanShareNetwork -Adapter $Adapter -Expected $entry.NetworkProfile
                if ($active -and $active.Changed) {
                    $entry.NetworkProfile = $active
                }
            } elseif ((& $Adapter.GetProfile) -ne 'Private') {
                throw 'Network changed during boot reconciliation.'
            }
            & $Adapter.NewShare $entry.Name $entry.SharePath $entry.Mode $entry.AllowedSids $true $entry.Id | Out-Null
            $entry.Status = 'Running'
            $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $null -Force
        } catch {
            $entry.Status = 'BlockedStart'
            $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $_.Exception.Message -Force
        }
        $results += [pscustomobject]@{Id=$entry.Id;Status=$entry.Status}
    }
    Write-LanState -Path $StatePath -State $state
    return $results
}

function Invoke-LanBootReconcile {
    param([Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [int]$LockTimeoutMilliseconds = 30000)
    if ($Adapter.PrepareOnline) { & $Adapter.PrepareOnline $StatePath $Adapter | Out-Null }
    # Keep the heartbeat fresh while waiting for the lock: the worker may spend longer than the
    # heartbeat window simply waiting for the broker to finish, and reporting that as "not ready"
    # made every later share fail.
    $keepAlive = if ($Adapter.HeartbeatPath) {
        { param($path) try { Write-LanWorkerHeartbeat -Path $path } catch { } }.GetNewClosure()
    } else { $null }
    $heartbeatPath = $Adapter.HeartbeatPath
    $stateLock = if ($keepAlive) {
        Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds -WhileWaiting { & $keepAlive $heartbeatPath }
    } else {
        Enter-LanStateLock -StatePath $StatePath -TimeoutMilliseconds $LockTimeoutMilliseconds
    }
    try { return Invoke-LanBootReconcileCore -StatePath $StatePath -Adapter $Adapter }
    finally { $stateLock.Dispose() }
}

function Start-LanHostWorker {
    param([Parameter(Mandatory)][string]$StatePath,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $created = $false
    $mutex = New-Object Threading.Mutex($false, 'Global\LanFileSharing-HostWorker', [ref]$created)
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return }
    $heartbeatWriter = $null
    try {
        # Bring an installation made by an earlier version up to date. The state folder used to be
        # restricted to SYSTEM and Administrators, and the window — which runs unelevated — could not
        # read the share credentials out of state.json, so handing them to another machine failed with
        # "Access denied" while the share list still looked correct, because that list comes from the
        # broker running as SYSTEM. The repair is idempotent and runs as SYSTEM here, which is also the
        # only context allowed to change these permissions.
        $stateRootForAcl = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))
        try { Repair-LanStateDirectoryAccess -Path $stateRootForAcl -StateRoot $stateRootForAcl | Out-Null } catch { }
        # A separate process keeps the heartbeat fresh while this one is busy inside a reconcile
        # that holds the state lock. See Start-LanWorkerHeartbeatWriter for why.
        if ($Adapter.HeartbeatPath) {
            try {
                Write-LanWorkerHeartbeat -Path $Adapter.HeartbeatPath
                $heartbeatWriter = Start-LanWorkerHeartbeatWriter -HeartbeatPath $Adapter.HeartbeatPath -WorkerProcessId $PID
            } catch { }
        }
        while ($true) {
            try {
                Invoke-LanBootReconcile -StatePath $StatePath -Adapter $Adapter | Out-Null
                if ($Adapter.HeartbeatPath) { Write-LanWorkerHeartbeat -Path $Adapter.HeartbeatPath }
            }
            catch { if ($Adapter.Log) { & $Adapter.Log $_.Exception.Message } }
            Start-Sleep -Seconds 5
        }
    } finally {
        foreach ($id in @($script:LanActiveMonitors.Keys)) { Stop-LanActiveMonitor $id }
        # Stop the heartbeat writer too; it also exits by itself when this process is gone.
        if ($heartbeatWriter) {
            try { if (-not $heartbeatWriter.HasExited) { Stop-Process -Id $heartbeatWriter.Id -Force -ErrorAction SilentlyContinue } } catch { }
            try { $heartbeatWriter.Dispose() } catch { }
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Remove-LanHostWorker {
    param([Parameter(Mandatory)][hashtable]$Adapter)
    # Stop the automatic tasks first so they cannot rebuild shares while cleanup runs,
    # but keep them registered until the machine state is known to be clean. A failed
    # cleanup therefore leaves a retryable installation instead of orphaned state.
    if ($Adapter.StopBrokerTask) { & $Adapter.StopBrokerTask | Out-Null }
    if ($Adapter.StopTask) { & $Adapter.StopTask | Out-Null }
    $repair = Repair-LanHostState -StatePath $Adapter.StatePath -Adapter $Adapter
    $pending = @($repair.Pending)
    if ($pending.Count -gt 0) {
        $details = @($pending | ForEach-Object {
            $name = if ($_.Name) { [string]$_.Name } else { '(unnamed share)' }
            $phase = if ($_.Phase) { [string]$_.Phase } else { 'unknown phase' }
            $reason = if ($_.FailureReason) { [string]$_.FailureReason } else { 'no failure reason was recorded' }
            "$name [$phase]: $reason"
        })
        # Only genuinely retryable work reaches this point. A share name taken over by another
        # program is resolved automatically during the repair above, so it never blocks setup.
        throw ("Setup could not undo an interrupted share by itself and stopped before changing anything. " +
            "Fix the reason below and run setup again: $($details -join ' | ')")
    }
    $state = Read-LanState -Path $Adapter.StatePath
    $failures = @()
    foreach ($entry in @($state.Shares)) {
        # Uninstall always finishes: a share name taken over by another program must not leave
        # the machine half cleaned. Our own record and NTFS changes are still undone.
        try { Stop-LanHostShare -Id $entry.Id -StatePath $Adapter.StatePath -Adapter $Adapter -ReleaseUnownedName | Out-Null }
        catch { $failures += "$($entry.Name): $($_.Exception.Message)" }
    }
    if ($failures.Count -gt 0) { throw "Uninstall cleanup incomplete: $($failures -join '; ')" }
    $restoredGuest = Restore-LanGuestConfiguration -Role Host -Adapter $Adapter -StatePath $Adapter.StatePath
    if (@($restoredGuest.Skipped).Count -gt 0) { throw 'Host Guest setting changed outside this app; the recovery snapshot was retained.' }
    Restore-LanBlankPasswordNetworkLogon -StatePath $Adapter.StatePath -Adapter $Adapter | Out-Null
    if ($Adapter.RemoveOnlineFirewall) { & $Adapter.RemoveOnlineFirewall | Out-Null }
    if ($Adapter.UnregisterBrokerTask) { & $Adapter.UnregisterBrokerTask | Out-Null }
    & $Adapter.UnregisterTask | Out-Null
    # The folder removal reports its outcome instead of throwing. When a handle on the folder cannot be
    # released — an open Explorer window, a scanner or a file indexer also holds one — the folder is queued
    # for deletion at the next start, and the uninstall still finishes. Failing here showed the user a raw
    # PowerShell error dialog that named an internal script line and offered nothing to act on.
    $removal = & $Adapter.RemoveInstalledFiles
    if ($removal -and @($removal.PendingRemoval).Count -gt 0) {
        return [pscustomobject]@{
            Removed = $true
            PendingRemoval = @($removal.PendingRemoval)
            Message = ('ลบไฟล์โปรแกรมทั้งหมดแล้ว แต่โฟลเดอร์ ' + (@($removal.PendingRemoval) -join ', ') +
                ' ยังถูกโปรแกรมอื่นใช้งานอยู่ ระบบตั้งไว้ให้ลบอัตโนมัติเมื่อเปิดเครื่องครั้งหน้า')
        }
    }
    return [pscustomobject]@{Removed=$true; PendingRemoval=@()}
}

function Test-LanApplicationPath {
    # Whether a directory is this program's own, judged by what is inside rather than by who owns it.
    #
    # Taking ownership of a folder because it happens to sit at a path we recognise would be reckless. The
    # contents are the proof: only a folder holding our own files is repaired, and anything else is left
    # alone for the installer to report.
    param([Parameter(Mandatory)][string]$Path)
    foreach ($name in @('LanShare.ps1','HostWorker.ps1','state.json','install.json','broker-user.sid','progress')) {
        if (Test-Path -LiteralPath (Join-Path $Path $name)) { return $true }
    }
    # An empty folder at the documented location is also ours to prepare.
    try {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        if ($children.Count -eq 0) { return $true }
    } catch { }
    return $false
}

function Repair-LanUntrustedInstallOwner {
    # Takes back a folder whose owner is not SYSTEM or Administrators, instead of refusing to install.
    #
    # This is the failure the installer reported: "Untrusted owner of application path:
    # C:\ProgramData\LanFileSharing". Windows gives a newly created folder to its creator, so a folder made
    # once by an elevated window that has since been removed from the Administrators group keeps an owner
    # the check rejects — and the install then stops with a message naming an internal script line and no way
    # forward. The folder is this program's own, so the owner is corrected and the correct ACL is applied.
    param([Parameter(Mandatory)][string]$Path,
          [scriptblock]$Log)
    $write = { param($text) try { if ($Log) { & $Log $text } } catch { } }
    if (-not [IO.Directory]::Exists($Path)) { return $false }
    $trusted = @('S-1-5-18','S-1-5-32-544')
    try {
        $current = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $current.GetOwner([Security.Principal.SecurityIdentifier]).Value
    } catch { return $false }
    if ($owner -in $trusted) { return $false }
    if (-not (Test-LanApplicationPath -Path $Path)) { return $false }
    & $write "โฟลเดอร์ $Path มีเจ้าของที่ไม่ใช่ SYSTEM/Administrators — กำลังคืนสิทธิ์ให้ใหม่"
    try {
        # Seize the folder, then replace the whole ACL rather than editing it: an ACL left by another owner
        # can carry entries this account cannot remove, and a merge would keep them.
        $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetOwner($administrators)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($administrators)
        $acl.SetGroup($administrators)
        # Inheritance is switched off and the inherited entries are discarded. Leaving it on kept an
        # inherited rule from the parent folder — the test case sits under %TEMP%, where Users may write —
        # and the tree check then failed with "Untrusted write access" even though every explicit rule had
        # been replaced. On the real machine the same thing happens wherever the folder was created.
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagate = [Security.AccessControl.PropagationFlags]::None
        foreach ($entry in @(
                @{ Sid='S-1-5-18'; Rights=[Security.AccessControl.FileSystemRights]::FullControl },
                @{ Sid='S-1-5-32-544'; Rights=[Security.AccessControl.FileSystemRights]::FullControl },
                @{ Sid='S-1-5-32-545'; Rights=[Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize' })) {
            $identity = New-Object Security.Principal.SecurityIdentifier($entry.Sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $entry.Rights, $inherit, $propagate, [Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        # Children keep their own owners AND their own access rules, so correcting only the top folder left
        # the tree check failing on the first file inside it ("Untrusted write access on application path").
        # Every child gets the same trusted rules, applied directly rather than inherited, so no entry from
        # the previous owner survives. Shallowest first, so a directory is corrected before its contents.
        $childPropagate = [Security.AccessControl.PropagationFlags]::None
        $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
        foreach ($child in @($items | Sort-Object { $_.FullName.Length })) {
            try {
                $childAcl = Get-Acl -LiteralPath $child.FullName -ErrorAction Stop
                $childAcl.SetOwner($administrators)
                # Same reason as the root: inherited entries have to be dropped, not merged.
                $childAcl.SetAccessRuleProtection($true, $false)
                try {
                    if ($childAcl.GetGroup([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
                        $childAcl.SetGroup($administrators)
                    }
                } catch { }
                # Remove every rule whose principal is not trusted; the standard rules are added straight after.
                foreach ($rule in @($childAcl.Access)) {
                    try {
                        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                        if ($sid -notin $trusted) { [void]$childAcl.RemoveAccessRule($rule) }
                    } catch { }
                }
                $inherit = if ($child.PSIsContainer) {
                    [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
                } else { [Security.AccessControl.InheritanceFlags]::None }
                foreach ($entry in @(
                        @{ Sid='S-1-5-18'; Rights=[Security.AccessControl.FileSystemRights]::FullControl },
                        @{ Sid='S-1-5-32-544'; Rights=[Security.AccessControl.FileSystemRights]::FullControl },
                        @{ Sid='S-1-5-32-545'; Rights=[Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize' })) {
                    $identity = New-Object Security.Principal.SecurityIdentifier($entry.Sid)
                    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $entry.Rights, $inherit, $childPropagate, [Security.AccessControl.AccessControlType]::Allow)
                    $childAcl.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $child.FullName -AclObject $childAcl -ErrorAction Stop
            } catch { }
        }
        & $write "คืนสิทธิ์โฟลเดอร์ $Path เรียบร้อย"
        return $true
    } catch {
        & $write "คืนสิทธิ์โฟลเดอร์ $Path ไม่สำเร็จ: $($_.Exception.Message)"
        return $false
    }
}

function Set-LanInstalledDirectoryAcl {
    param([string]$Path, [ValidateSet('Code','State')][string]$Role, [string]$StateRoot)
    if ([IO.Directory]::Exists($Path)) {
        # Repair first, then check.
        #
        # Checking alone threw "Untrusted owner of application path" and stopped the install with nothing the
        # user could do about it from the installer. The repair only fixed the owner of the top folder, though,
        # while the check walks every file and folder below it — so an ACL written by an older version, or by a
        # half-finished install, kept the install failing with "Untrusted write access on application path" and
        # no way forward. The rules are therefore rewritten over the whole existing tree before the check runs,
        # which is also what makes a repair actually repair.
        [void](Repair-LanUntrustedInstallOwner -Path $Path)
        Set-LanInstalledTreeAcl -Path $Path -Role $Role -StateRoot $StateRoot
        Assert-LanTrustedInstallTree -Path $Path
        return
    }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    # Only the state role carries a rule for the signed-in user, and it must be the account that will
    # run the window — not SYSTEM, which is what the worker and broker see as "current".
    $userSid = if ($Role -eq 'State') { Get-LanStateUserSid -StateRoot $StateRoot } else { $null }
    $acl = New-LanInstalledDirectoryAcl -Acl $acl -Role $Role -UserSid $userSid -Path $Path -StateRoot $StateRoot
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Assert-LanTrustedInstallAcl {
    param([Parameter(Mandatory)]$Acl,[Parameter(Mandatory)][string]$Path)
    $trusted = @('S-1-5-18','S-1-5-32-544')
    $owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trusted) { throw "Untrusted owner of application path: $Path" }
    $writeRights = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    foreach ($ace in @($Acl.Access)) {
        if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($ace.FileSystemRights -band $writeRights) -eq 0) { continue }
        $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $trusted -and -not (Test-LanExpectedSharedWrite -Path $Path -Sid $sid)) {
            throw "Untrusted write access on application path: $Path"
        }
    }
}

function Test-LanExpectedSharedWrite {
    # Two places under the state root are writable by other principals on purpose, and treating them as
    # a tampering signal blocked the very repair that was needed: the progress folder is written by the
    # window and the broker (which run as different accounts), and the state folder is now readable by
    # the signed-in user because the window must read the share credentials. Everything else under the
    # root must stay owned by SYSTEM and Administrators alone.
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Sid)
    $normalized = $Path.TrimEnd('\')
    $stateRoot = ([IO.Path]::GetFullPath((Join-Path $env:ProgramData 'LanFileSharing'))).TrimEnd('\')
    if (-not $normalized.StartsWith($stateRoot,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $relative = $normalized.Substring($stateRoot.Length).Trim('\')
    if ([string]::IsNullOrEmpty($relative)) { return $false }          # the root itself stays restricted
    $leaf = ($relative -split '\\')[0]
    if ($leaf -eq 'progress') { return $true }                          # written by window and broker
    if ($leaf -eq 'state.json' -or $leaf -eq 'state.json.lock') {
        # Only the account that installed the application may hold write access here.
        return ($Sid -eq (Get-LanStateUserSid -StateRoot $stateRoot))
    }
    return $false
}

function Assert-LanTrustedInstallTree {
    param([Parameter(Mandatory)][string]$Path)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $info = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Untrusted reparse point in application tree: $current" }
        Assert-LanTrustedInstallAcl -Acl (Get-Acl -LiteralPath $current -ErrorAction Stop) -Path $current
        if ($info.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) { $pending.Push($child.FullName) }
        }
    }
}

function Set-LanInstalledTreeAcl {
    param([Parameter(Mandatory)][string]$Path,[ValidateSet('Code','State')][string]$Role,[string]$StateRoot)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    # Resolved once for the whole walk: the state role needs the signed-in account, and the worker
    # running as SYSTEM would otherwise resolve it to SYSTEM itself.
    $userSid = if ($Role -eq 'State') { Get-LanStateUserSid -StateRoot $StateRoot } else { $null }
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $info = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Untrusted reparse point in application tree: $current" }
        $acl = New-LanInstalledDirectoryAcl -Acl (Get-Acl -LiteralPath $current -ErrorAction Stop) -Role $Role -IsDirectory ([bool]$info.PSIsContainer) -UserSid $userSid -Path $current -StateRoot $StateRoot
        Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
        if ($info.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) { $pending.Push($child.FullName) }
        }
    }
}

function New-LanInstalledDirectoryAcl {
    param([Parameter(Mandatory)]$Acl, [ValidateSet('Code','State')][string]$Role,
          [bool]$IsDirectory = $true, [string]$UserSid,
          [string]$Path, [string]$StateRoot)
    $acl = $Acl
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($ace in @($acl.Access)) { $acl.PurgeAccessRules($ace.IdentityReference) }
    foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $inheritance = if ($IsDirectory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,[Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    if ($Role -eq 'Code') {
        $sid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,[Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    } else {
        # The signed-in user needs the state directory. The window runs without elevation, and the
        # client tab reads the share credentials out of state.json to hand them to another machine;
        # with only SYSTEM and Administrators on the folder, that read failed with "Access denied"
        # while the share list still looked fine, because the list comes from the broker running as
        # SYSTEM. Only this account is added, and with specific rights rather than the Modify enum:
        # the file holds share passwords and must not become readable by every account on the machine.
        if ($UserSid) {
            # Write only where the unelevated window writes, and no rule at all for the root.
            #
            # The rule used to be "Write everywhere in the state tree, plus a Read rule on the root". The tree
            # checker refused that — correctly, because the root holds the share passwords and one account being
            # able to rewrite all of it is a tampering path. The refusal then blocked the install with
            # "Untrusted write access on application path", which names the folder but not the rule that broke.
            # Write is now limited to the two places the window must write: the folder the log and progress
            # files live in, and the state file with its lock. The root gets nothing, and every other directory
            # is readable so the window can reach the files below it.
            $stateRootFull = if ($StateRoot) { ([IO.Path]::GetFullPath($StateRoot)).TrimEnd('\') } else { '' }
            $currentFull = if ($Path) { ([IO.Path]::GetFullPath($Path)).TrimEnd('\') } else { '' }
            $relative = ''
            $inside = $false
            if ($stateRootFull -and $currentFull -and
                $currentFull.StartsWith($stateRootFull, [StringComparison]::OrdinalIgnoreCase)) {
                $relative = $currentFull.Substring($stateRootFull.Length).Trim('\')
                $inside = $true
            }
            $writable = $inside -and (
                ($IsDirectory -and $relative -eq 'progress') -or
                (-not $IsDirectory -and ($relative -eq 'state.json' -or $relative -eq 'state.json.lock')))
            $grantRead = $inside -and -not $writable
            if ($writable -or $grantRead) {
                # Explicit rights, because an ACL already converted to specific bits must not be handed a
                # generic mask — .NET refuses to build a rule from it. Same reason
                # ConvertTo-LanSpecificAclMask exists.
                $rights = [Security.AccessControl.FileSystemRights](
                    [int][Security.AccessControl.FileSystemRights]::ReadData -bor
                    [int][Security.AccessControl.FileSystemRights]::ReadAttributes -bor
                    [int][Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor
                    [int][Security.AccessControl.FileSystemRights]::ReadPermissions -bor
                    [int][Security.AccessControl.FileSystemRights]::Synchronize)
                if ($writable) {
                    $rights = [Security.AccessControl.FileSystemRights](
                        [int]$rights -bor
                        [int][Security.AccessControl.FileSystemRights]::WriteData -bor
                        [int][Security.AccessControl.FileSystemRights]::AppendData -bor
                        [int][Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                        [int][Security.AccessControl.FileSystemRights]::WriteExtendedAttributes)
                }
                $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                    (New-Object Security.Principal.SecurityIdentifier($UserSid)),$rights,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow)
                $acl.AddAccessRule($rule)
            }
        }
    }
    return $acl
}

function Get-LanStateUserSid {
    # Which account the state directory must also be readable by. The recorded user is preferred: the
    # worker and the broker run as SYSTEM, so the account that started them is the only correct answer
    # there, and the installing account is the one the window will run as.
    param([string]$StateRoot)
    try {
        if ($StateRoot) {
            $record = Join-Path $StateRoot 'broker-user.sid'
            if ([IO.File]::Exists($record)) {
                $sid = ([IO.File]::ReadAllText($record)).Trim()
                if ($sid -match '^S-\d-\d+(-\d+)+$') { return $sid }
            }
        }
    } catch { }
    try {
        $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($current) { return $current.Value }
    } catch { }
    return $null
}

function Repair-LanStateDirectoryAccess {
    # Brings an existing installation up to date: state directories created by an earlier version have
    # no rule for the signed-in user, so the window could not read the share credentials out of
    # state.json. Idempotent — it does nothing once the rule is present.
    param([Parameter(Mandatory)][string]$Path,[string]$StateRoot)
    try {
        if (-not [IO.Directory]::Exists($Path)) { return $false }
        $sid = Get-LanStateUserSid -StateRoot $StateRoot
        if (-not $sid) { return $false }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        foreach ($rule in @($acl.Access)) {
            try { if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid) { return $false } }
            catch { }
        }
        Set-LanInstalledDirectoryAcl -Path $Path -Role 'State' -StateRoot $StateRoot
        # A file written under the old rules carries an explicitly protected ACL of its own, so the
        # directory's new rule does not reach it and it stays unreadable until it is updated too.
        foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
            try {
                # The ACL is read from the file itself, not from the folder: setting the folder's rules onto
                # the file discarded the file's own, and passing the folder's path also told the builder this
                # was the directory rather than state.json — so the file never received the write access it
                # needs, and the tree check refused the result for having none.
                $fresh = New-LanInstalledDirectoryAcl -Acl (Get-Acl -LiteralPath $file.FullName) -Role 'State' `
                    -IsDirectory $false -UserSid $sid -Path $file.FullName -StateRoot $StateRoot
                Set-Acl -LiteralPath $file.FullName -AclObject $fresh -ErrorAction Stop
            } catch { }
        }
        return $true
    } catch { return $false }
}

function New-LanStartupAdapter {
    param([Parameter(Mandatory)][string]$SourceRoot,
          [Parameter(Mandatory)][string]$InstallRoot,
          [Parameter(Mandatory)][string]$StateRoot,
          [hashtable]$LocationAdapter)
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $StateRoot = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    $legacyInstall = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'LanFileSharing')).TrimEnd('\')
    $newDefaultInstall = Get-LanDefaultInstallRoot -Is64BitOs ([Environment]::Is64BitOperatingSystem)
    $record = if ($LocationAdapter) { Get-LanInstallRecord -Adapter $LocationAdapter } else { Get-LanInstallRecord }
    $approvedInstall = if ($record) { [string]$record.InstallRoot } else { $null }
    $allowedRoots = if ($record) { @($approvedInstall) } else { @($legacyInstall,$newDefaultInstall) }
    $expectedState = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'LanFileSharing')).TrimEnd('\')
    if ($InstallRoot -notin $allowedRoots -or
        -not [string]::Equals($StateRoot,$expectedState,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Install directory must be the recorded application path or a legacy default; state must remain under ProgramData.'
    }
    $adapter = New-LanHostAdapter
    $adapter.InstallRoot = $InstallRoot
    $adapter.HadInstallDirectory = [IO.Directory]::Exists($InstallRoot)
    $adapter.StateRoot = $StateRoot
    $adapter.StatePath = Join-Path $StateRoot 'state.json'
    $adapter.HeartbeatPath = Join-Path $StateRoot 'worker.heartbeat'
    $adapter.BrokerHeartbeatPath = Join-Path $StateRoot 'broker.heartbeat'
    $adapter.SetBrokerUser = {
        $path = Join-Path $StateRoot 'broker-user.sid'
        if ([IO.File]::Exists($path)) { return }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        [IO.File]::WriteAllText($path,$sid,[Text.Encoding]::ASCII)
    }.GetNewClosure()
    $adapter.SecureDirectory = { param($path,$role) Set-LanInstalledDirectoryAcl -Path $path -Role $role -StateRoot $StateRoot }
    $adapter.SecureTree = { param($path,$role) Set-LanInstalledTreeAcl -Path $path -Role $role -StateRoot $StateRoot }
    $adapter.AssertNotInstalled = {
        if (Get-LanScheduledTask -TaskName '') {
            throw 'Host worker is already installed; uninstall it before reinstalling.'
        }
    }
    $adapter.CopyFiles = {
        param($root)
        foreach ($file in @('LanShare.ps1','Start-LanShare.cmd','HostWorker.ps1','Install-LanShare.ps1','Update-LanShare.ps1','Uninstall-LanShare.ps1')) {
            Copy-Item -LiteralPath (Join-Path $SourceRoot $file) -Destination (Join-Path $root $file) -Force -ErrorAction Stop
        }
        foreach ($file in @('HostHelper.ps1','Reset-LanShare.ps1','OnlineSetup.ps1','OnlineSignIn.ps1','LanFileSharing.exe')) {
            $source = Join-Path $SourceRoot $file
            if ([IO.File]::Exists($source)) { Copy-Item -LiteralPath $source -Destination (Join-Path $root $file) -Force -ErrorAction Stop }
        }
        # The version file the window shows in its title bar. It is produced by the build, so it is not in the
        # source tree — but it is in the payload, and this list is what decides what reaches the install
        # directory. Leaving it out is why an installed window showed no version at all while the payload
        # verification reported every file present.
        $versionSource = Join-Path $SourceRoot 'version.txt'
        if ([IO.File]::Exists($versionSource)) {
            Copy-Item -LiteralPath $versionSource -Destination (Join-Path $root 'version.txt') -Force -ErrorAction Stop
        }
        $targetSrc = Join-Path $root 'src'
        [IO.Directory]::CreateDirectory($targetSrc) | Out-Null
        Copy-Item -Path (Join-Path $SourceRoot 'src\*.ps1') -Destination $targetSrc -Force -ErrorAction Stop
        $targetIcon = Join-Path $root 'icon'
        [IO.Directory]::CreateDirectory($targetIcon) | Out-Null
        foreach ($file in @('Tiger_Tech_Share_File.ico','Tiger_Tech_Share_File.png')) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $SourceRoot 'icon') $file) -Destination (Join-Path $targetIcon $file) -Force -ErrorAction Stop
        }
    }.GetNewClosure()
    $stageRoot = "$InstallRoot.update-$([guid]::NewGuid().ToString('N'))"
    $adapter.StageRoot = $stageRoot
    $backupRoot = "$InstallRoot.backup-$([guid]::NewGuid().ToString('N'))"
    $failedRoot = "$InstallRoot.failed-$([guid]::NewGuid().ToString('N'))"
    $adapter.AssertInstalled = {
        param($installedRoot,$statePath)
        $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostWorker'
        if (-not $task) { throw 'Host worker is not installed.' }
        $expectedExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $expectedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installedRoot 'HostWorker.ps1') + '" -StatePath "' + (Join-Path $env:ProgramData 'LanFileSharing\state.json') + '"'
        if (-not $task.Actions -or @($task.Actions).Count -ne 1 -or
            -not [string]::Equals([string]$task.Actions[0].Execute,$expectedExe,[StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$task.Actions[0].Arguments,$expectedArgs,[StringComparison]::OrdinalIgnoreCase) -or
            [string]$task.Principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18')) {
            throw 'Host worker task name belongs to another command; update was refused.'
        }
        # A retained registry/task pair is also a repairable installation when
        # its code directory was removed. Stage verified files and keep state.
        if ([IO.Directory]::Exists($installedRoot)) {
            [void](Repair-LanUntrustedInstallOwner -Path $installedRoot)
            Assert-LanTrustedInstallTree -Path $installedRoot
        }
        if (-not [IO.File]::Exists($statePath)) { throw 'Host state is missing; update was not started.' }
        Read-LanState -Path $statePath | Out-Null
    }
    $adapter.StageFiles = {
        param($stageRoot,$adapter)
        try {
            Set-LanInstalledDirectoryAcl -Path $stageRoot -Role Code
            & $adapter.CopyFiles $stageRoot | Out-Null
            Set-LanInstalledTreeAcl -Path $stageRoot -Role Code
        } catch {
            if ([IO.Directory]::Exists($stageRoot)) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
            throw
        }
    }
    $adapter.StopTask = {
        $task = Get-LanScheduledTask -TaskName ''
        if (-not $task -or $task.State -ne 'Running') { return }
        Stop-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -ErrorAction Stop
        for ($attempt=0; $attempt -lt 80; $attempt++) {
            $task = Get-LanScheduledTask -TaskName ''
            if (-not $task -or $task.State -ne 'Running') { return }
            Start-Sleep -Milliseconds 250
        }
        throw 'Host worker did not stop for update.'
    }
    $adapter.SwapFiles = {
        # Close everything running out of the install directory before renaming it.
        #
        # The host worker and the broker are Windows tasks that start again by themselves, and the window holds
        # its own scripts open. Renaming the directory while any of them is alive fails with "the process cannot
        # access the file because it is being used by another process" — which is what made an install fail with
        # no way forward: the tasks reported Ready, the window could be closed by hand, and the worker kept
        # coming back. Installing is a deliberate act, so the program closes itself first.
        if (@(Get-LanProcessUsingPath -Path @($InstallRoot)).Count -gt 0) {
            [void](Close-LanProcessesUsingPath -Path @($InstallRoot) -Log $Log)
            for ($attempt = 0; $attempt -lt 40; $attempt++) {
                if (@(Get-LanProcessUsingPath -Path @($InstallRoot)).Count -eq 0) { break }
                Start-Sleep -Milliseconds 250
            }
        }
        try {
            if ([IO.Directory]::Exists($InstallRoot)) { [IO.Directory]::Move($InstallRoot,$backupRoot) }
        } catch {
            # A process that appeared between the close and the rename — the worker task starting again — is
            # worth one more attempt rather than failing the whole install.
            [void](Close-LanProcessesUsingPath -Path @($InstallRoot) -Log $Log)
            Start-Sleep -Milliseconds 1500
            [IO.Directory]::Move($InstallRoot,$backupRoot)
        }
        try { [IO.Directory]::Move($stageRoot,$InstallRoot) }
        catch {
            if ([IO.Directory]::Exists($backupRoot)) { [IO.Directory]::Move($backupRoot,$InstallRoot) }
            throw
        }
    }.GetNewClosure()
    $adapter.RestoreFiles = {
        [IO.Directory]::Move($InstallRoot,$failedRoot)
        try { if ([IO.Directory]::Exists($backupRoot)) { [IO.Directory]::Move($backupRoot,$InstallRoot) } }
        catch {
            [IO.Directory]::Move($failedRoot,$InstallRoot)
            throw
        }
        if ([IO.Directory]::Exists($failedRoot)) { Remove-Item -LiteralPath $failedRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }.GetNewClosure()
    $adapter.CleanupStage = {
        if ([IO.Directory]::Exists($stageRoot)) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction Stop }
    }.GetNewClosure()
    $adapter.CleanupBackup = {
        if ([IO.Directory]::Exists($backupRoot)) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction Stop }
    }.GetNewClosure()
    $adapter.RegisterTask = {
        param($root,$stateRoot,$account,$atStartup,$restart)
        $scriptPath = Join-Path $root 'HostWorker.ps1'
        $statePath = Join-Path $stateRoot 'state.json'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -StatePath "' + $statePath + '"'
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        # Windows defaults a new task to "do not start on battery", which silently parks it in the
        # Queued state on a laptop that is not plugged in. The worker then never runs, the heartbeat
        # never appears, and setup waits for it until it gives up — reported as a frozen installer
        # and as shares that never start. Sharing a folder must not depend on the power source.
        $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    }
    $adapter.RegisterBrokerTask = {
        $taskName = 'LanFileSharing-HostBroker'
        $existing = Get-LanScheduledTask -TaskName $taskName
        if ($existing) {
            Assert-LanHostBrokerTask -Task $existing -InstallRoot $InstallRoot -StateRoot $StateRoot
            return
        }
        $scriptPath = Join-Path $InstallRoot 'HostWorker.ps1'
        $statePath = Join-Path $StateRoot 'state.json'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -StatePath "' + $statePath + '" -Broker'
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        # Same battery default as the worker task: without these two the broker is parked in Queued
        # on an unplugged laptop and every share action fails with "broker is unavailable".
        $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    }.GetNewClosure()
    $adapter.BrokerTaskExists = {
        $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostBroker'
        if (-not $task) { return $false }
        Assert-LanHostBrokerTask -Task $task -InstallRoot $InstallRoot -StateRoot $StateRoot
        return $true
    }.GetNewClosure()
    $adapter.StartBrokerTask = {
        $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostBroker'
        if (-not $task) { throw 'Host broker task is not installed.' }
        Assert-LanHostBrokerTask -Task $task -InstallRoot $InstallRoot -StateRoot $StateRoot
        if ([IO.File]::Exists($adapter.BrokerHeartbeatPath)) { [IO.File]::Delete($adapter.BrokerHeartbeatPath) }
        Start-ScheduledTask -TaskName 'LanFileSharing-HostBroker' -ErrorAction Stop
        for ($attempt=0; $attempt -lt 80; $attempt++) {
            $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostBroker'
            if ($task -and $task.State -eq 'Running' -and (Test-LanWorkerHeartbeat -Path $adapter.BrokerHeartbeatPath)) { return }
            Start-Sleep -Milliseconds 250
        }
        $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostBroker'
        $state = if ($task) { [string]$task.State } else { 'missing' }
        throw ("Host broker did not start after installation (task state: " + $state + ').' +
            $(if ($state -eq 'Queued') { ' A queued task on an unplugged laptop is the Windows battery default.' } else { '' }))
    }.GetNewClosure()
    $adapter.StopBrokerTask = {
        $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostBroker'
        if (-not $task) { return }
        Assert-LanHostBrokerTask -Task $task -InstallRoot $InstallRoot -StateRoot $StateRoot
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName 'LanFileSharing-HostBroker' -ErrorAction Stop }
    }.GetNewClosure()
    $adapter.UnregisterBrokerTask = {
        $task = Get-LanScheduledTask -TaskName 'LanFileSharing-HostBroker'
        if (-not $task) { return }
        Assert-LanHostBrokerTask -Task $task -InstallRoot $InstallRoot -StateRoot $StateRoot
        Stop-ScheduledTask -TaskName 'LanFileSharing-HostBroker' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'LanFileSharing-HostBroker' -Confirm:$false -ErrorAction Stop
    }.GetNewClosure()
    $adapter.StartTask = {
        param($heartbeatPath)
        if ([IO.File]::Exists($heartbeatPath)) { [IO.File]::Delete($heartbeatPath) }
        Start-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -ErrorAction Stop
        $started = $false
        for ($attempt=0; $attempt -lt 60; $attempt++) {
            $task = Get-LanScheduledTask -TaskName ''
            if ($task -and $task.State -eq 'Running' -and (Test-LanWorkerHeartbeat -Path $heartbeatPath)) { $started = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $started) {
            # Say WHY instead of just failing. A task parked in Queued is the signature of the
            # Windows battery default, which silently refuses to run a task on an unplugged laptop.
            $task = Get-LanScheduledTask -TaskName ''
            $state = if ($task) { [string]$task.State } else { 'missing' }
            $onBattery = $false
            try {
                $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($battery -and [int]$battery.BatteryStatus -eq 1) { $onBattery = $true }
            } catch { }
            $reason = if ($state -eq 'Queued') {
                'the scheduled task is queued and never starts' +
                $(if ($onBattery) { ' because this computer is running on battery and Windows refuses to start it' } else { '' })
            } else { "the scheduled task is '$state'" }
            throw ("Host worker did not start after installation: " + $reason + '.')
        }
    }
    $adapter.UnregisterTask = {
        Stop-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -Confirm:$false -ErrorAction SilentlyContinue
    }
    $adapter.RemoveInstalledFiles = {
        # Both directories are cleared before either is reported: the application folder and the state
        # folder. A single refusal used to end the uninstall with a PowerShell error dialog, so each one is
        # removed through the retrying helper and the outcome is summarised afterwards.
        $pending = New-Object System.Collections.Generic.List[string]
        foreach ($path in @($InstallRoot,$StateRoot)) {
            $resolved = [IO.Path]::GetFullPath($path).TrimEnd('\')
            if ($resolved -ne $InstallRoot -and $resolved -ne $expectedState) { throw 'Unexpected uninstall path.' }
            $result = Remove-LanDirectoryTree -Directory $resolved
            if (-not $result.Removed -and $result.Pending) { $pending.Add($resolved) }
        }
        # The installer unpacks itself into %TEMP%\LanFileSharingSetup-* and those copies are left behind by
        # every run that could not delete them. They are this program's own leftovers, so clearing the older
        # ones here keeps a machine that has been installed and removed repeatedly from filling up with them.
        try {
            $cutoff = (Get-Date).AddDays(-1)
            foreach ($leftover in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'LanFileSharingSetup-*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff })) {
                [void](Remove-LanDirectoryTree -Directory $leftover.FullName)
            }
        } catch { }
        if ($pending.Count -gt 0) {
            # Not a failure: the folders are queued for deletion at the next start, so the uninstall is
            # complete from the user's point of view and nothing is left registered.
            return [pscustomobject]@{ PendingRemoval=@($pending) }
        }
        return [pscustomobject]@{ PendingRemoval=@() }
    }.GetNewClosure()
    $adapter.VerifyAcl = {
        param($records)
        foreach ($record in @($records)) {
            if (-not (Test-Path -LiteralPath $record.Path)) { return $false }
            $current = Get-Acl -LiteralPath $record.Path -ErrorAction Stop
            $before = [string]$record.Before
            $after = [string]$record.After
            if ($before -eq $after) { continue }
            # Ask whether THIS APP'S grant is still present, by identity, instead of comparing the
            # whole security descriptor as a string. A string comparison also fails when the owner
            # or an unrelated entry changes — for example a user adding another person to the
            # folder — and the share was then marked "NTFS permissions changed after activation"
            # and blocked even though our own access was untouched.
            #
            # If the exact comparison is unavailable for any reason, fall back to the presence of
            # the principals this app granted. An unrelated permission change must never block a
            # share: the guarantee that matters is that nobody else gained access, and a missing
            # entry is caught by the exact check on every later reconcile.
            #
            # Note: .Rules is a List[object] and @($x.Rules) throws "Argument types do not match"
            # in PowerShell 5.1, so the list is read into a variable and enumerated directly.
            $exact = $true
            try {
                $delta = Get-LanAccessRuleDelta -Before $before -After $after
                $added = $delta.Rules
                if ($added.Count -eq 0) { $exact = $false }
                elseif (Test-LanAclHoldsNoAppGrant -Acl $current -AddedRules $added) { return $false }
            } catch { $exact = $false }
            if (-not $exact) {
                $wanted = New-Object System.Collections.Generic.List[string]
                foreach ($ace in (Get-LanAclRules -Sddl $after).Rules) {
                    $wanted.Add((Get-LanAclPrincipalSid -IdentityReference $ace.IdentityReference))
                }
                $present = New-Object System.Collections.Generic.List[string]
                foreach ($ace in $current.Access) {
                    $present.Add((Get-LanAclPrincipalSid -IdentityReference $ace.IdentityReference))
                }
                foreach ($sid in $wanted) {
                    if ($present -notcontains $sid) { return $false }
                }
            }
        }
        return $true
    }
    $adapter.GetFileId = { param($path) Get-LanFileId $path }
    $adapter.StartMonitor = { param($entry) Start-LanSingleFileMonitor -Entry $entry }
    $adapter.SyncFile = { param($entry) Sync-LanSingleFile -Entry $entry }
    $adapter.Log = {
        param($message)
        Add-Content -LiteralPath (Join-Path $StateRoot 'worker.log') -Value ((Get-Date -Format o) + ' ' + $message)
    }.GetNewClosure()
    # GetNewClosure creates a dynamic module that cannot see script-scope
    # functions loaded by the installer. Bind its LAN dependencies explicitly.
    $lanFunctions = @{}
    foreach ($command in @(Get-Command -CommandType Function -Name '*-Lan*')) {
        $lanFunctions[$command.Name] = $command.ScriptBlock
    }
    foreach ($value in @($adapter.Values)) {
        if ($value -is [scriptblock] -and $value.Module -and $value.Module.Name -like '__DynamicModule*') {
            & $value.Module {
                param($definitions)
                foreach ($name in $definitions.Keys) {
                    Set-Item -Path ('Function:script:' + $name) -Value $definitions[$name]
                }
            } $lanFunctions
        }
    }
    return $adapter
}
