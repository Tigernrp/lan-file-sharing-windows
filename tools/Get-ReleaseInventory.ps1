[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$installer = [IO.Path]::GetFullPath($InstallerPath)
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not [IO.File]::Exists($installer)) { throw 'Installer is missing.' }
if (-not [IO.Path]::IsPathRooted($OutputPath)) { throw 'Inventory output path must be absolute.' }
$process = Start-Process -FilePath $installer -ArgumentList ('--audit "' + $output + '"') -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($output)) { throw 'Installer audit failed.' }
$inventory = Get-Content -LiteralPath $output -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $inventory.version -or @($inventory.files).Count -eq 0) { throw 'Installer audit report is incomplete.' }
$inventory
