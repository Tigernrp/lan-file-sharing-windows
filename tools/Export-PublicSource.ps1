[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $PSScriptRoot 'PublicSource.psm1'
$manifestPath = Join-Path $PSScriptRoot 'public-source-files.json'
Import-Module $modulePath -Force

$result = New-LanPublicSourceSnapshot -SourceRoot $sourceRoot -DestinationRoot $DestinationRoot -Version $Version -ManifestPath $manifestPath
$result | ConvertTo-Json -Depth 6
