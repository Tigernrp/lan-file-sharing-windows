function Get-LanDefinedFunction {
    # Lists the functions a script defines, ignoring anything inside a here-string.
    #
    # This exists in one place only, on purpose. The same check was written twice with different rules
    # — the deploy script stripped here-strings and the window did not — so the window warned about
    # "Add-Trace" and "Set-Result", which live in a here-string that is written out as a helper process
    # and are never loaded here. A false alarm like that is indistinguishable from a real one, so the
    # rule now has a single definition and both callers use it.
    param([Parameter(Mandatory)][string]$Path)
    $names = New-Object System.Collections.Generic.List[string]
    if (-not [IO.File]::Exists($Path)) { return $names }
    try {
        $text = [IO.File]::ReadAllText($Path)
        # Here-strings first: that content is another program's source, not this one's.
        $text = [regex]::Replace($text,'(?s)@''.*?''@','')
        $text = [regex]::Replace($text,'(?s)@".*?"@','')
        # Comment lines are removed too: a commented-out definition must not be reported as missing.
        $text = [regex]::Replace($text,'(?m)^\s*#.*$','')
        foreach ($match in [regex]::Matches($text,'(?m)^function\s+([A-Za-z][A-Za-z0-9-]*)')) {
            [void]$names.Add($match.Groups[1].Value)
        }
    } catch { }
    return $names
}

function Get-LanVersion {
    # The version this installation was built as, stamped into version.txt by installer\Build-Release.ps1.
    #
    # It is a file rather than a constant inside the window so there is one place to change: the installer, the
    # release file name and the title bar all come from the same build step and can never disagree. The owner
    # asked to see the version in the title bar exactly to tell one build from another.
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'version.txt'),
        (Join-Path $PSScriptRoot 'version.txt')
    )
    foreach ($path in $candidates) {
        try {
            if (Test-Path -LiteralPath $path) {
                $value = ([IO.File]::ReadAllText($path)).Trim()
                if ($value) { return $value }
            }
        } catch { }
    }
    return ''
}

function Get-LanVersionSuffix {
    # The text appended to every window title: "  V.3.44". Empty when the version is unknown, so a title is
    # never left with a stray label.
    $version = Get-LanVersion
    if (-not $version) { return '' }
    return "  V.$version"
}
function Get-LanLoadedModuleNames {
    # The modules a running window loads. Installer-only scripts are deliberately absent, so their
    # functions must never be reported as missing.
    return @('Selection','State','Progress','Auth','SingleFile','ClientMap','Host','InstallLocation',
             'Startup','HostBridge','UserStartup','Network','Online','OnlineUi','Ui')
}
if (-not ('LanSelectionNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LanSelectionNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool GetVolumeInformation(string root, StringBuilder name, int nameSize,
        out uint serial, out uint maxComponent, out uint flags, StringBuilder fs, int fsSize);
}
'@
}

function Resolve-LanPathManually {
    # Resolves a path without [IO.Path]::GetFullPath, for the paths that method refuses. Kept
    # separate so the rules below can be tested directly: the framework accepts the hostile inputs,
    # so a test that goes through Resolve-LanFullPath would never reach this code.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is empty.' }
    $text = $Path.Replace('/','\')
    if (-not [IO.Path]::IsPathRooted($text)) {
        $separator = [string][IO.Path]::DirectorySeparatorChar
        $text = [IO.Path]::Combine((Get-Location).ProviderPath, $text)
    } else {
        $separator = [string][IO.Path]::DirectorySeparatorChar
    }
    $root = [IO.Path]::GetPathRoot($text)
    if ([string]::IsNullOrEmpty($root)) { throw 'Could not resolve the path root.' }
    $rest = $text.Substring($root.Length)
    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $rest.Split('\')) {
        if ($segment -eq '' -or $segment -eq '.') { continue }
        # ".." is honoured only when something is left to remove; a ".." that reaches the root is
        # refused rather than silently dropped, so nothing can address outside the named volume.
        if ($segment -eq '..') {
            if ($segments.Count -eq 0) { throw 'The path escapes its root.' }
            $segments.RemoveAt($segments.Count - 1)
            continue
        }
        $segments.Add($segment)
    }
    $resolved = $root + ($segments -join $separator)
    if ($segments.Count -gt 0 -and $text.EndsWith('\')) { $resolved += $separator }
    return $resolved
}

function Resolve-LanFullPath {
    # [IO.Path]::GetFullPath throws on a path that is too long, that contains a component longer
    # than 255 characters, or that contains a character Win32 forbids. Those paths do exist: tools
    # such as OneDrive or robocopy create them, and Explorer simply cannot show them. Resolve the
    # common cases ourselves so a share that contains one unusable name is still shareable, and
    # report which path was unusable instead of failing with a bare framework exception.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is empty.' }
    try { return [IO.Path]::GetFullPath($Path) } catch { }
    try { return Resolve-LanPathManually $Path }
    catch {
        $preview = if ($Path.Length -gt 90) { $Path.Substring(0,90) + '…' } else { $Path }
        throw ("This path cannot be used: $preview ($($Path.Length) characters). " +
               'A folder or file name inside it is longer than Windows allows (255 characters), or it contains a character Windows forbids.')
    }
}

function Get-LanCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is empty.' }
    $full = Resolve-LanFullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if (-not $root -or $root.StartsWith('\\')) { throw 'Only local Windows volumes are supported.' }
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Get-LanVolumeIdentity {
    param([Parameter(Mandatory)][string]$Root)
    $name = New-Object Text.StringBuilder 260
    $fs = New-Object Text.StringBuilder 260
    [uint32]$serial = 0; [uint32]$max = 0; [uint32]$flags = 0
    $ok = [LanSelectionNative]::GetVolumeInformation($Root, $name, $name.Capacity,
        [ref]$serial, [ref]$max, [ref]$flags, $fs, $fs.Capacity)
    if (-not $ok) { throw "Cannot read volume identity for $Root (Win32: $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
    return [pscustomobject]@{ Id = ('{0:X8}' -f $serial); FileSystem = $fs.ToString() }
}

function Resolve-LanSelection {
    param(
        [Parameter(Mandatory)][ValidateSet('Drive','Folder','File')][string]$Kind,
        [Parameter(Mandatory)][string]$Path
    )
    $full = Get-LanCanonicalPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ($Kind -eq 'Drive') {
        if (-not [string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Drive selection must be the volume root.' }
        if (-not [IO.Directory]::Exists($full)) { throw "Drive is unavailable: $full" }
    } elseif ($Kind -eq 'Folder') {
        if (-not [IO.Directory]::Exists($full)) { throw "Folder does not exist: $full" }
    } else {
        if (-not [IO.File]::Exists($full)) { throw "File does not exist: $full" }
    }
    $volume = Get-LanVolumeIdentity $root
    return [pscustomobject]@{
        Kind = $Kind; FullPath = $full; VolumeRoot = $root
        VolumeId = $volume.Id; FileSystem = $volume.FileSystem
    }
}

function Assert-LanShareName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.Length -lt 1 -or $Name.Length -gt 80 -or
        $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]*$' -or
        $Name.EndsWith(' ') -or $Name.EndsWith('.')) {
        throw 'Share name must be 1–80 characters and contain only letters, digits, spaces, underscores, hyphens or dots.'
    }
    if ($Name -match '^(ADMIN|IPC|[A-Z])\$$') { throw 'Windows reserved share name.' }
    return $Name
}

function Test-LanOverlap {
    param([Parameter(Mandatory)][string]$Candidate, [string[]]$Existing = @())
    $candidatePath = (Get-LanCanonicalPath $Candidate).TrimEnd('\')
    foreach ($path in $Existing) {
        if (-not $path) { continue }
        $existingPath = (Get-LanCanonicalPath $path).TrimEnd('\')
        if ([string]::Equals($candidatePath, $existingPath, [StringComparison]::OrdinalIgnoreCase) -or
            $candidatePath.StartsWith($existingPath + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $existingPath.StartsWith($candidatePath + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-LanDriveMetadataChild {
    param([Parameter(Mandatory)][string]$SharePath,
          [Parameter(Mandatory)][string]$Folder,
          [Parameter(Mandatory)]$Item,
          [string]$Kind = 'Folder')
    # Windows owns these containers on every volume and rebuilds or re-protects them on its
    # own, which leaves recorded ACL pairs that can never be reconciled again. They are
    # skipped wherever they appear, not only directly under a shared drive root.
    if (($Item.Attributes -band [IO.FileAttributes]::Directory) -eq 0) { return $false }
    return ($Item.Name -in @('System Volume Information','$RECYCLE.BIN'))
}

function Test-LanSystemDriveRoot {
    param([Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)][string]$Kind,
          [string]$WindowsDirectory=$env:windir)
    if ($Kind -ne 'Drive' -or [string]::IsNullOrWhiteSpace($WindowsDirectory)) { return $false }
    $sharePath = Get-LanCanonicalPath $Path
    $windowsRoot = [IO.Path]::GetPathRoot((Get-LanCanonicalPath $WindowsDirectory))
    return [string]::Equals($sharePath,$windowsRoot,[StringComparison]::OrdinalIgnoreCase)
}

function Test-LanSystemDirectory {
    param([Parameter(Mandatory)][string]$Path,
          [string]$WindowsDirectory=$env:windir)
    # The Windows directory is the one place this app never shares: its ACLs are owned by the
    # OS and changing them can break the machine or expose system binaries over SMB.
    if ([string]::IsNullOrWhiteSpace($WindowsDirectory) -or -not [IO.Directory]::Exists($WindowsDirectory)) { return $false }
    $candidate = Get-LanCanonicalPath $Path
    $windows = Get-LanCanonicalPath $WindowsDirectory
    return ([string]::Equals($candidate,$windows,[StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($windows + '\',[StringComparison]::OrdinalIgnoreCase))
}

function Test-LanReparseDirectory {
    param([Parameter(Mandatory)]$Item)
    # A redirected or linked directory (junction, symlink, OneDrive Known Folder Move) is not
    # entered: sharing stays on the selected path instead of following the link elsewhere.
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    return (($Item.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
}

function Assert-LanShareRoot {
    param([Parameter(Mandatory)]$Selection)
    $path = Get-LanCanonicalPath $Selection.FullPath
    if (Test-LanSystemDirectory -Path $path) {
        throw "The Windows directory cannot be shared: $path"
    }
    # This check concerns the selected root only. The former descendant walk
    # never validated or changed anything, yet the worker held the state lock
    # throughout it on every pass. Grant-LanNtfsAcl still performs the required
    # descendant permission checks, with metadata and reparse pruning.
    return $true
}
