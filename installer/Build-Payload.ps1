[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+$')][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseBuild.psm1') -Force
$root = Split-Path -Parent $PSScriptRoot
New-LanUnsignedPayload -SourceRoot $root -Version $Version -OutputDirectory $OutputDirectory
