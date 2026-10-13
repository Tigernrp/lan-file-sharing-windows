[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+$')][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$RequireSignedPayload,
    [string]$ExpectedSignerPattern = 'SignPath Foundation'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseBuild.psm1') -Force
New-LanInstallerFromPayload -PayloadPath $PayloadPath -Version $Version -OutputDirectory $OutputDirectory -RequireSignedPayload ([bool]$RequireSignedPayload) -ExpectedSignerPattern $ExpectedSignerPattern
