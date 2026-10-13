param([Parameter(Mandatory)][string]$PipeName)
$ErrorActionPreference='Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator rights are required for sharer actions.'
}
foreach ($module in @('Selection','State','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge')) {
    . (Join-Path $PSScriptRoot "src/$module.ps1")
}
Start-LanHostHelper -PipeName $PipeName
