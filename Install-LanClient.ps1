param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\LanFileSharingClient')
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::Equals($sourceRoot, $destination, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "Client files are already at $destination"
    return
}
$files = @('LanShare.ps1', 'Start-LanShare.cmd', 'Diagnose-LanClient.ps1', 'Diagnose-LanClient.cmd')
$modules = @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'src') -Filter '*.ps1' -File -ErrorAction Stop)
foreach ($name in $files) {
    if (-not [IO.File]::Exists((Join-Path $sourceRoot $name))) { throw "Client source file is missing: $name" }
}
if ($modules.Count -eq 0) { throw 'Client source modules are missing.' }
[IO.Directory]::CreateDirectory($destination) | Out-Null
$moduleDestination = Join-Path $destination 'src'
[IO.Directory]::CreateDirectory($moduleDestination) | Out-Null
foreach ($name in $files) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $destination $name) -Force -ErrorAction Stop
}
foreach ($module in $modules) {
    Copy-Item -LiteralPath $module.FullName -Destination (Join-Path $moduleDestination $module.Name) -Force -ErrorAction Stop
}
Write-Host "Client installed to $destination"
Write-Host "Open: $(Join-Path $destination 'Start-LanShare.cmd')"
