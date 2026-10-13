Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-LanCanonicalRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($full)) {
        throw "Directory does not exist: $Path"
    }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-LanContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Manifest path must be relative."
    }
    $rootFull = Get-LanCanonicalRoot -Path $Root
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes the source root."
    }
    return $candidate
}

function Test-LanPathForReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = Get-LanCanonicalRoot -Path $Root
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if ($pathFull -ne $rootFull -and -not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the source root."
    }

    $relative = if ($pathFull -eq $rootFull) { '' } else { $pathFull.Substring($prefix.Length) }
    $current = $rootFull
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
    }
    return $false
}

function Read-LanPublicManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not [IO.File]::Exists($ManifestPath)) {
        throw "Public source manifest was not found."
    }
    try {
        return (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "Public source manifest is invalid JSON."
    }
}

function Test-LanDeniedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $normalized = $RelativePath.Replace('/', '\').TrimStart('\')
    $segments = @($normalized -split '\\')
    foreach ($denied in @($Manifest.DeniedDirectories)) {
        if ($segments -contains [string]$denied) { return $true }
    }
    $leaf = [IO.Path]::GetFileName($normalized)
    foreach ($deniedFile in @($Manifest.DeniedFiles)) {
        if ($leaf.Equals([string]$deniedFile, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $extension = [IO.Path]::GetExtension($leaf)
    foreach ($deniedExtension in @($Manifest.DeniedExtensions)) {
        if ($extension.Equals([string]$deniedExtension, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-LanSafeTreeFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TreePath,
        [string[]]$Include = @('*')
    )

    if (Test-LanPathForReparsePoint -Root $Root -Path $TreePath) {
        throw "A reparse point is not allowed in the public source manifest."
    }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($TreePath)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($entry in (Get-ChildItem -LiteralPath $directory -Force)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A reparse point is not allowed in the public source manifest."
            }
            if ($entry.PSIsContainer) {
                $queue.Enqueue($entry.FullName)
                continue
            }
            $matches = $false
            foreach ($filter in @($Include)) {
                if ($entry.Name -like $filter) { $matches = $true; break }
            }
            if ($matches) { $entry.FullName }
        }
    }
}

function Get-LanPublicSourceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $root = Get-LanCanonicalRoot -Path $SourceRoot
    $manifest = Read-LanPublicManifest -ManifestPath $ManifestPath
    $files = New-Object 'System.Collections.Generic.List[string]'

    foreach ($relative in @($manifest.Files)) {
        $full = Resolve-LanContainedPath -Root $root -RelativePath ([string]$relative)
        if (-not [IO.File]::Exists($full)) {
            throw "An allowlisted source file is missing: $relative"
        }
        if (Test-LanPathForReparsePoint -Root $root -Path $full) {
            throw "A reparse point is not allowed in the public source manifest."
        }
        $normalized = $full.Substring($root.Length + 1).Replace('\', '/')
        if (Test-LanDeniedRelativePath -RelativePath $normalized -Manifest $manifest) {
            throw "A private or generated path was included in the public source manifest."
        }
        $files.Add($normalized)
    }

    foreach ($tree in @($manifest.Trees)) {
        $treeRelative = [string]$tree.Path
        $treeFull = Resolve-LanContainedPath -Root $root -RelativePath $treeRelative
        if (-not [IO.Directory]::Exists($treeFull)) {
            throw "An allowlisted source directory is missing: $treeRelative"
        }
        if (Test-LanDeniedRelativePath -RelativePath $treeRelative -Manifest $manifest) {
            throw "A private directory was included in the public source manifest."
        }
        $includes = @($tree.Include)
        if ($includes.Count -eq 0) { $includes = @('*') }
        foreach ($full in @(Get-LanSafeTreeFiles -Root $root -TreePath $treeFull -Include $includes)) {
            $normalized = $full.Substring($root.Length + 1).Replace('\', '/')
            if (Test-LanDeniedRelativePath -RelativePath $normalized -Manifest $manifest) {
                throw "A private or generated file was included in the public source manifest."
            }
            $files.Add($normalized)
        }
    }

    return @($files | Sort-Object -Unique)
}

function Test-LanPublicSourceContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$PatternsPath,
        [string[]]$RelativePaths
    )

    $rootFull = Get-LanCanonicalRoot -Path $Root
    $manifest = Read-LanPublicManifest -ManifestPath $PatternsPath
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $filesScanned = 0

    $scanFiles = if ($PSBoundParameters.ContainsKey('RelativePaths')) {
        @($RelativePaths | ForEach-Object {
            $candidate = Resolve-LanContainedPath -Root $rootFull -RelativePath $_
            if (-not [IO.File]::Exists($candidate)) { throw "A requested scan file is missing." }
            if (Test-LanPathForReparsePoint -Root $rootFull -Path $candidate) { throw "A reparse point is not allowed during content scanning." }
            $candidate
        })
    } else {
        @(Get-LanSafeTreeFiles -Root $rootFull -TreePath $rootFull -Include @('*'))
    }

    foreach ($full in $scanFiles) {
        $relative = $full.Substring($rootFull.Length + 1).Replace('\', '/')
        if (Test-LanDeniedRelativePath -RelativePath $relative -Manifest $manifest) {
            $findings.Add([pscustomobject]@{ File = $relative; Rule = 'private-or-generated-path' })
            continue
        }
        $filesScanned++
        try {
            $content = [IO.File]::ReadAllText($full)
        } catch {
            $findings.Add([pscustomobject]@{ File = $relative; Rule = 'unreadable-text-file' })
            continue
        }
        foreach ($rule in @($manifest.SensitivePatterns)) {
            $excluded = $false
            $excludedPaths = @()
            if ($rule.PSObject.Properties['ExcludePaths']) { $excludedPaths = @($rule.ExcludePaths) }
            foreach ($pathPattern in $excludedPaths) {
                if ($relative -like [string]$pathPattern) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            if ([regex]::IsMatch($content, [string]$rule.Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                $findings.Add([pscustomobject]@{ File = $relative; Rule = [string]$rule.Id })
            }
        }
    }

    return [pscustomobject]@{
        Passed = ($findings.Count -eq 0)
        Findings = $findings.ToArray()
        FilesScanned = $filesScanned
    }
}

function New-LanPublicSourceSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$ManifestPath = (Join-Path $PSScriptRoot 'public-source-files.json')
    )

    $source = Get-LanCanonicalRoot -Path $SourceRoot
    $destination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($destination.StartsWith(($source + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        $relativeDestination = $destination.Substring($source.Length + 1)
        if (-not $relativeDestination.StartsWith('open-source' + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The destination must not be nested inside the private source tree."
        }
    }
    if ([IO.Directory]::Exists($destination)) {
        if (@(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) {
            throw "The public destination already exists and is not empty."
        }
    } elseif ([IO.File]::Exists($destination)) {
        throw "The public destination path is an existing file."
    }

    $parent = Split-Path -Parent $destination
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $staging = $destination + '.staging-' + [guid]::NewGuid().ToString('N')
    $copied = @(Get-LanPublicSourceManifest -SourceRoot $source -ManifestPath $ManifestPath)
    try {
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        foreach ($relative in $copied) {
            $sourcePath = Resolve-LanContainedPath -Root $source -RelativePath $relative
            $targetPath = Join-Path $staging ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $targetDirectory = Split-Path -Parent $targetPath
            if (-not [IO.Directory]::Exists($targetDirectory)) { [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null }
            [IO.File]::Copy($sourcePath, $targetPath, $false)
        }

        $validation = Test-LanPublicSourceContent -Root $staging -PatternsPath $ManifestPath
        if (-not $validation.Passed) {
            $rules = @($validation.Findings | ForEach-Object { "{0}:{1}" -f $_.File, $_.Rule }) -join ', '
            throw "Public source validation rejected the snapshot: $rules"
        }
        if ([IO.Directory]::Exists($destination)) { [IO.Directory]::Delete($destination, $false) }
        [IO.Directory]::Move($staging, $destination)
        return [pscustomobject]@{
            Destination = $destination
            Version = $Version
            CopiedFiles = $copied
            RejectedFindings = @()
        }
    } finally {
        if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
    }
}

Export-ModuleMember -Function Get-LanPublicSourceManifest, Test-LanPublicSourceContent, New-LanPublicSourceSnapshot
