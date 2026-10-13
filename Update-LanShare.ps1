param(
    [string]$InstallRoot,
    [string]$StateRoot = (Join-Path $env:ProgramData 'LanFileSharing')
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -InstallRoot "' + $InstallRoot + '" -StateRoot "' + $StateRoot + '"'
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $child.ExitCode
}
foreach ($module in @('Selection','State','Online','Auth','SingleFile','Host','InstallLocation','Startup')) {
    . (Join-Path $PSScriptRoot "src/$module.ps1")
}
$record = Get-LanInstallRecord
if (-not $InstallRoot) { $InstallRoot = if ($record) { $record.InstallRoot } else { Join-Path $env:ProgramFiles 'LanFileSharing' } }
if ($record -and -not [string]::Equals((ConvertTo-LanInstallRoot $InstallRoot),$record.InstallRoot,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The update target differs from the recorded installation.'
}
$adapter = New-LanStartupAdapter -SourceRoot $PSScriptRoot -InstallRoot $InstallRoot -StateRoot $StateRoot
Update-LanHostWorker -Adapter $adapter | Out-Null
Write-Host "Updated $InstallRoot; existing share settings were preserved."
