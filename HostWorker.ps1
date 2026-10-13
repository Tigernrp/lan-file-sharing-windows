param([Parameter(Mandatory)][string]$StatePath,[switch]$Broker)
$ErrorActionPreference = 'Stop'
foreach ($module in @('Selection','State','Progress','Online','Auth','SingleFile','Host','InstallLocation','Startup','HostBridge')) {
    . (Join-Path $PSScriptRoot "src/$module.ps1")
}
$installRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$stateRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))
if ($Broker) { Start-LanHostBroker -StateRoot $stateRoot }
else {
    $adapter = New-LanStartupAdapter -SourceRoot $installRoot -InstallRoot $installRoot -StateRoot $stateRoot
    Start-LanHostWorker -StatePath $StatePath -Adapter $adapter
}
