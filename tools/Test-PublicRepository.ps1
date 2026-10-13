[CmdletBinding()]
param(
    [string]$Root,
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
$modulePath = Join-Path $rootFull 'tools\PublicSource.psm1'
$manifestPath = Join-Path $rootFull 'tools\public-source-files.json'
Import-Module $modulePath -Force

$errors = New-Object 'System.Collections.Generic.List[string]'
$actualFiles = New-Object 'System.Collections.Generic.List[string]'
$queue = New-Object 'System.Collections.Generic.Queue[string]'
$queue.Enqueue($rootFull)
while ($queue.Count -gt 0) {
    $directory = $queue.Dequeue()
    foreach ($entry in (Get-ChildItem -LiteralPath $directory -Force)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $errors.Add(('reparse-point:{0}' -f $entry.Name))
            continue
        }
        if ($entry.PSIsContainer) {
            if ($entry.Name -eq '.git') { continue }
            $queue.Enqueue($entry.FullName)
            continue
        }
        $actualFiles.Add($entry.FullName.Substring($rootFull.Length + 1).Replace('\', '/'))
    }
}

try {
    $allowedFiles = @(Get-LanPublicSourceManifest -SourceRoot $rootFull -ManifestPath $manifestPath)
    $allowedLookup = @{}
    foreach ($relative in $allowedFiles) { $allowedLookup[$relative.ToLowerInvariant()] = $true }
    foreach ($relative in $actualFiles) {
        if (-not $allowedLookup.ContainsKey($relative.ToLowerInvariant())) {
            $errors.Add(('not-allowlisted:{0}' -f $relative))
        }
    }
    $actualLookup = @{}
    foreach ($relative in $actualFiles) { $actualLookup[$relative.ToLowerInvariant()] = $true }
    foreach ($relative in $allowedFiles) {
        if (-not $actualLookup.ContainsKey($relative.ToLowerInvariant())) {
            $errors.Add(('missing-allowlisted:{0}' -f $relative))
        }
    }
} catch {
    $errors.Add(('manifest:{0}' -f $_.Exception.Message))
}

$readmePath = Join-Path $rootFull 'README.md'
if (-not [IO.File]::Exists($readmePath)) {
    $errors.Add('missing:README.md')
} else {
    $readme = [IO.File]::ReadAllText($readmePath)
    if ($readme -notmatch ('(?im)Current source version:\s*' + [regex]::Escape($Version) + '\*{0,2}\s*$')) {
        $errors.Add('version:README.md')
    }
}

foreach ($required in @('LICENSE','PRIVACY.md','SECURITY.md','CONTRIBUTING.md','CODE_SIGNING_POLICY.md','THIRD_PARTY_NOTICES.md')) {
    if (-not [IO.File]::Exists((Join-Path $rootFull $required))) { $errors.Add(('missing:{0}' -f $required)) }
}

try {
    $contentResult = Test-LanPublicSourceContent -Root $rootFull -PatternsPath $manifestPath -RelativePaths $actualFiles.ToArray()
    foreach ($finding in @($contentResult.Findings)) {
        $errors.Add(('content:{0}:{1}' -f $finding.File, $finding.Rule))
    }
} catch {
    $errors.Add(('content-scan:{0}' -f $_.Exception.Message))
}

if ($errors.Count -gt 0) {
    Write-Host 'PUBLIC REPOSITORY VALIDATION FAILED'
    $errors | Sort-Object -Unique | ForEach-Object { Write-Host ('  ' + $_) }
    exit 1
}

Write-Host ('PUBLIC REPOSITORY VALIDATION PASSED: version={0} files={1}' -f $Version, $actualFiles.Count)
exit 0
