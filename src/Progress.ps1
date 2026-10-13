# Live progress reporting for long sharing operations.
#
# Sharing a large folder spends most of its time walking the tree and setting NTFS permissions,
# and that work happens either in this process or inside the elevated host broker. Both write a
# status file and an append-only log file under ProgramData, and the sharer window polls them so
# the user can see what is happening instead of a frozen status line.
#
# The files are best effort: progress must never make a share fail, so every write is guarded.
# The module guards its own definitions, so a caller may dot-source it without coordination.

if (-not (Get-Command Get-LanProgressDirectory -ErrorAction SilentlyContinue)) {

function Get-LanProgressDirectory {
    if ($env:LanProgressDirectory) { return [string]$env:LanProgressDirectory }
    # A dedicated subfolder, not the state folder itself. The state folder holds state.json, which
    # carries the credentials for a Protected Password share and is therefore restricted to
    # SYSTEM and Administrators. Progress files must be readable by the signed-in user so the
    # window can show them; keeping them in the restricted folder made every read fail silently and
    # the log pane stayed empty until the user opened that folder with administrator rights.
    return Join-Path (Join-Path $env:ProgramData 'LanFileSharing') 'progress'
}

function Initialize-LanProgressDirectory {
    # Creates the progress folder and makes it readable by every account that can sign in, while
    # leaving the state folder and state.json exactly as restricted as they were.
    param([string]$Directory)
    $target = if ($Directory) { $Directory } else { Get-LanProgressDirectory }
    try {
        if (-not [IO.Directory]::Exists($target)) { [IO.Directory]::CreateDirectory($target) | Out-Null }
        $acl = Get-Acl -LiteralPath $target -ErrorAction Stop
        # Files, not just the folder: the window opens the files, and a folder-only grant would
        # still refuse it.
        $rights = [Security.AccessControl.FileSystemRights]'Read, ReadAndExecute, Write, Delete, Synchronize'
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sidText in @('S-1-5-32-545','S-1-5-11')) {
            $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $sid, $rights, $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $target -AclObject $acl -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-LanProgressPath {
    param([Parameter(Mandatory)][string]$Leaf)
    # Progress is best effort, so an unusable location must still yield a path, not throw.
    try {
        $directory = Get-LanProgressDirectory
        if (-not [IO.Directory]::Exists($directory)) {
            [IO.Directory]::CreateDirectory($directory) | Out-Null
            # Creating it is not enough: whoever creates it first decides who can read it, and the
            # window runs as the signed-in user while the broker runs as SYSTEM. Grant the read
            # access at creation so the pane can always open these files.
            Initialize-LanProgressDirectory -Directory $directory | Out-Null
        }
        return [IO.Path]::Combine($directory,$Leaf)
    }
    catch {
        # Keep readers and the SYSTEM broker on the same path when an ordinary
        # user cannot create its parent. Progress writers already catch failures.
        $directory=Get-LanProgressDirectory
        return [IO.Path]::Combine($directory,$Leaf)
    }
}

function Get-LanProgressStatusPath { return Get-LanProgressPath -Leaf 'progress.status' }
function Get-LanProgressLogPath { return Get-LanProgressPath -Leaf 'progress.log' }

function Get-LanProgressTime {
    return (Get-Date).ToString('HH:mm:ss')
}

function Start-LanProgress {
    param([Parameter(Mandatory)][string]$Message)
    try {
        # Apply the readable ACL before writing, so the first lines are already visible to the
        # signed-in user's window.
        Initialize-LanProgressDirectory | Out-Null
        $header = (Get-LanProgressTime) + "  เริ่มทำงาน`r`n"
        [IO.File]::WriteAllText((Get-LanProgressLogPath),$header,[Text.Encoding]::UTF8)
        Set-LanProgress -Message $Message -Percent 0
    } catch { }
}

function Set-LanProgress {
    param([Parameter(Mandatory)][string]$Message,
          [int]$Percent = -1,
          [int]$Current = -1,
          [int]$Total = -1)
    try {
        $text = (Get-LanProgressTime) + '  ' + $Message
        if ($Current -ge 0 -and $Total -gt 0) { $text += " ($Current/$Total)" }
        $json = [pscustomobject]@{
            Time=$text; Message=$Message; Percent=$Percent
            Current=$Current; Total=$Total; Updated=(Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 3 -Compress
        # Written in one call so a reader never sees a partially written status.
        [IO.File]::WriteAllText((Get-LanProgressStatusPath),$json,[Text.Encoding]::UTF8)
    } catch { }
}

function Add-LanProgressLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        $line = (Get-LanProgressTime) + '  ' + $Message + "`r`n"
        [IO.File]::AppendAllText((Get-LanProgressLogPath),$line,[Text.Encoding]::UTF8)
    } catch { }
}

function Set-LanProgressLogged {
    # Records a step in BOTH the status file and the log. The senders of long operations report
    # through the status file far more often than they should write log lines, so this is what
    # makes a slow phase (a whole-drive walk, for example) visible in the log the window shows.
    param([Parameter(Mandatory)][string]$Message,
          [int]$Percent = -1,
          [int]$Current = -1,
          [int]$Total = -1)
    Set-LanProgress -Message $Message -Percent $Percent -Current $Current -Total $Total
    $previous = $script:LanProgressLastLoggedMessage
    $previousAt = $script:LanProgressLastLoggedAt
    $now = Get-Date
    # Suppress only an exact repeat inside a short window, so a phase that reports "still working"
    # keeps producing lines while a tight loop stays quiet.
    if ($previous -eq $Message -and $previousAt -and ($now - $previousAt).TotalSeconds -lt 10) { return }
    $script:LanProgressLastLoggedMessage = $Message
    $script:LanProgressLastLoggedAt = $now
    Add-LanProgressLog -Message $Message
}

function Write-LanProgress {
    param([Parameter(Mandatory)][string]$Message,
          [int]$Percent = -1,
          [int]$Current = -1,
          [int]$Total = -1)
    # Update the current step and record it once, so the log reads as a history of the operation.
    Set-LanProgress -Message $Message -Percent $Percent -Current $Current -Total $Total
    Add-LanProgressLog -Message $Message
}

function Test-LanProgressDue {
    param([Parameter(Mandatory)]$Throttle,
          [int]$Interval = 25,
          [int]$Seconds = 2)
    # Reports the first item, then every $Interval items or $Seconds, so a 100000 item walk does
    # not write a log line per item.
    $Throttle.Count = [int]$Throttle.Count + 1
    $now = Get-Date
    if ($Throttle.Count -ge $Interval -or ($now - [datetime]$Throttle.Last).TotalSeconds -ge $Seconds) {
        $Throttle.Count = 0
        $Throttle.Last = $now
        return $true
    }
    return $false
}

function New-LanProgressThrottle {
    return @{ Count = 99; Last = (Get-Date).AddMinutes(-1) }
}

function Get-LanProgressStatus {
    param([int]$StaleSeconds = 600)
    try {
        $path = Get-LanProgressStatusPath
        if (-not [IO.File]::Exists($path)) { return $null }
        $status = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)) -ErrorAction Stop
        if (-not $status.Updated) { return $null }
        if (((Get-Date) - [datetime]$status.Updated).TotalSeconds -gt $StaleSeconds) { return $null }
        return $status
    } catch { return $null }
}

function Get-LanProgressLog {
    param([int]$TailLines = 200)
    try {
        $path = Get-LanProgressLogPath
        if (-not [IO.File]::Exists($path)) { return @() }
        $lines = @([IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8) | Where-Object { $_ -ne '' })
        if ($lines.Count -gt $TailLines) { return @($lines[($lines.Count - $TailLines)..($lines.Count - 1)]) }
        return $lines
    } catch { return @() }
}

function Clear-LanProgress {
    try {
        foreach ($path in @((Get-LanProgressStatusPath),(Get-LanProgressLogPath))) {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
    } catch { }
}

}

# The client log lives here rather than in the window: ClientMap.ps1 writes to it when it reconnects
# saved drives at startup, and that module loads before Ui.ps1, so a copy in the window was not defined
# yet and the call failed with "The term 'Add-LanClientLog' is not recognized". Logging is not a UI
# concern; only the pane that displays it is.
if (-not (Get-Command Get-LanClientLogPath -ErrorAction SilentlyContinue)) {
function Get-LanClientLogPath {
    # Per Windows account, under LOCALAPPDATA: the client side needs no elevation and writes only to
    # its own profile, unlike the sharing side whose log must be readable by the broker.
    $directory = Join-Path $env:LOCALAPPDATA 'LanFileSharing'
    if (-not [IO.Directory]::Exists($directory)) {
        try { [IO.Directory]::CreateDirectory($directory) | Out-Null } catch { }
    }
    return Join-Path $directory 'client.log'
}

function Add-LanClientLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $Message + "`r`n"
        [IO.File]::AppendAllText((Get-LanClientLogPath),$line,[Text.Encoding]::UTF8)
    } catch { }
}

function Get-LanClientLog {
    param([int]$TailLines = 200)
    try {
        $path = Get-LanClientLogPath
        if (-not [IO.File]::Exists($path)) { return @() }
        # FileShare.ReadWrite: the window may hold the file open for appending while this reads it.
        $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
            $all = @()
            while (-not $reader.EndOfStream) { $all += $reader.ReadLine() }
            $reader.Dispose()
        } finally { $stream.Dispose() }
        if ($all.Count -le $TailLines) { return $all }
        return @($all[($all.Count - $TailLines)..($all.Count - 1)])
    } catch { return @() }
}

function Clear-LanClientLog {
    try {
        $path = Get-LanClientLogPath
        if ([IO.File]::Exists($path)) { [IO.File]::WriteAllText($path,'',(New-Object Text.UTF8Encoding($false))) }
    } catch { }
}
}
