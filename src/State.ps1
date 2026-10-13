function New-LanEmptyState {
    return [pscustomobject]@{
        Version = 1
        Shares = @()
        Journal = @()
        GuestSnapshots = @()
        FirewallSnapshots = @()
        BlankPasswordSnapshot = $null
        OnlineSettings = [pscustomobject]@{Version=1;Enabled=$false;Binding=$null;AllowedPeers=@();LastKnownInterface=$null}
    }
}

function Enter-LanStateLock {
    param([Parameter(Mandatory)][string]$StatePath,
          [int]$TimeoutMilliseconds = 30000,
          # Called while the caller waits for the lock. The worker passes its heartbeat writer so a
          # long wait on another process is not mistaken for a dead worker: the heartbeat window is
          # 15 seconds, and a single reconcile pass can wait far longer than that.
          [scriptblock]$WhileWaiting)
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))
    if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $lockPath = [IO.Path]::GetFullPath($StatePath) + '.lock'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            return New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                throw "Timed out waiting for the host state lock: $lockPath"
            }
            if ($WhileWaiting) { try { & $WhileWaiting } catch { } }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function Test-LanWorkerHeartbeat {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        $stamp = [DateTimeOffset]::Parse([IO.File]::ReadAllText($Path), [Globalization.CultureInfo]::InvariantCulture)
        $age = [DateTimeOffset]::UtcNow - $stamp
        return ($age.TotalSeconds -ge 0 -and $age.TotalSeconds -le 15)
    } catch { return $false }
}

function Write-LanWorkerHeartbeat {
    param([Parameter(Mandatory)][string]$Path)
    [IO.File]::WriteAllText($Path, [DateTimeOffset]::UtcNow.ToString('o'), [Text.Encoding]::ASCII)
}

function Start-LanWorkerHeartbeatWriter {
    # Keeps the heartbeat file fresh from its own process. A reconcile pass over a large share can
    # hold the state lock for minutes while it verifies thousands of NTFS entries; writing the
    # heartbeat from the worker itself would then stop for that whole time, the window would see a
    # stale heartbeat, and every later share would fail with "worker is not ready".
    param([Parameter(Mandatory)][string]$HeartbeatPath,
          [Parameter(Mandatory)][int]$WorkerProcessId)
    $tempDirectory = $env:TEMP
    # A worker that was restarted leaves its previous writer and its script behind. Remove stale
    # scripts and stop writers whose worker is gone, so repeated restarts cannot pile them up.
    try {
        foreach ($stale in @(Get-ChildItem -LiteralPath $tempDirectory -Filter 'LanFileSharing-heartbeat-*.ps1' -File -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
    try {
        foreach ($stray in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'LanFileSharing-heartbeat' })) {
            $alive = $false
            $match = [regex]::Match($stray.CommandLine, '-WorkerProcessId\s+(\d+)')
            if ($match.Success) {
                $alive = [bool](Get-Process -Id ([int]$match.Groups[1].Value) -ErrorAction SilentlyContinue)
            }
            if (-not $alive) {
                try { Stop-Process -Id $stray.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
    $scriptPath = Join-Path $tempDirectory ('LanFileSharing-heartbeat-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = @'
param([string]$HeartbeatPath,[int]$WorkerProcessId)
$utf8 = New-Object Text.UTF8Encoding($false)
while ($true) {
    try {
        if (-not (Get-Process -Id $WorkerProcessId -ErrorAction SilentlyContinue)) { break }
        [IO.File]::WriteAllText($HeartbeatPath, [DateTimeOffset]::UtcNow.ToString('o'), $utf8)
    } catch { }
    Start-Sleep -Seconds 3
}
try { Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue } catch { }
'@
    [IO.File]::WriteAllText($scriptPath, $body, (New-Object Text.UTF8Encoding($true)))
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),
        '-HeartbeatPath',('"' + $HeartbeatPath + '"'),'-WorkerProcessId',[string]$WorkerProcessId)
    return Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList $arguments
}

function Read-LanState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return New-LanEmptyState }
    try {
        # The state is rewritten atomically (temp file plus File.Replace) roughly every five
        # seconds by the worker, so a reader that demands exclusive access fails during the
        # swap. Share everything including delete, and retry briefly for the remaining window.
        $raw = $null
        $attempts = 0
        while ($true) {
            $attempts++
            try {
                $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                try {
                    $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
                    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
                } finally { $stream.Dispose() }
                break
            } catch [IO.IOException] {
                if ($attempts -ge 20) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
        $state = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if ($null -eq $state -or $state.Version -ne 1 -or $null -eq $state.Shares -or
            $null -eq $state.Journal -or $null -eq $state.GuestSnapshots) {
            throw 'Missing or unsupported manifest fields.'
        }
        if (-not ($state.PSObject.Properties.Name -contains 'BlankPasswordSnapshot')) {
            $state | Add-Member -NotePropertyName BlankPasswordSnapshot -NotePropertyValue $null
        }
        if (-not ($state.PSObject.Properties.Name -contains 'OnlineSettings')) {
            $state | Add-Member -NotePropertyName OnlineSettings -NotePropertyValue ([pscustomobject]@{Version=1;Enabled=$false;Binding=$null;AllowedPeers=@();LastKnownInterface=$null})
        }
        return $state
    } catch {
        throw "Cannot read LAN share state at $Path`: $($_.Exception.Message)"
    }
}

function Write-LanState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    if ($State.Version -ne 1) { throw 'Unsupported LAN share state version.' }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $temp = Join-Path $directory ('.lanstate-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $temp + '.bak'
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 32 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temp, $Path, $backup)
            [IO.File]::Delete($backup)
        }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Test-LanGhostShare {
    param($Entry)
    if ($null -eq $Entry) { return $true }
    foreach ($name in @('Id','Name','Kind','SourcePath','SharePath','VolumeRoot','VolumeId','FileId','Mode','AuthMode')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Entry.$name)) { return $false }
    }
    foreach ($name in @('AclRecords','FirewallSnapshot','SingleFile','CredentialInfo','NetworkProfile')) {
        $value = $Entry.$name
        if ($null -eq $value) { continue }
        if ($value -is [array] -and $value.Count -eq 0) { continue }
        return $false
    }
    return $true
}

function Remove-LanGhostShares {
    param([Parameter(Mandatory)][string]$StatePath)
    $stateLock = Enter-LanStateLock -StatePath $StatePath
    try {
        $state = Read-LanState -Path $StatePath
        $kept = New-Object 'System.Collections.Generic.List[object]'
        $removed = 0
        foreach ($entry in @($state.Shares)) {
            if (Test-LanGhostShare -Entry $entry) { $removed++; continue }
            $kept.Add($entry)
        }
        if ($removed -gt 0) {
            $state.Shares = @($kept.ToArray())
            Write-LanState -Path $StatePath -State $state
        }
        return [pscustomobject]@{Removed=$removed}
    } finally { $stateLock.Dispose() }
}

function Protect-LanSecret {
    param([Parameter(Mandatory)][string]$Text)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return 'dpapi-machine:' + [Convert]::ToBase64String($protected)
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-LanSecret {
    param([Parameter(Mandatory)][string]$CipherText)
    if (-not $CipherText.StartsWith('dpapi-machine:')) { throw 'Unknown secret format.' }
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String($CipherText.Substring(14))
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { return [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Read-LanClientMappings {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $result = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop
        if ($null -eq $result) { return }
        return @($result)
    } catch { throw "Cannot read client mappings at $Path`: $($_.Exception.Message)" }
}

function Write-LanClientMappings {
    param([Parameter(Mandatory)][string]$Path, [object[]]$Mappings = @())
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $temp = Join-Path $directory ('.lanmaps-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $temp + '.bak'
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject @($Mappings) -Depth 8 -Compress), [Text.Encoding]::UTF8)
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temp, $Path, $backup)
            [IO.File]::Delete($backup)
        }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
