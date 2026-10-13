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
if (-not $InstallRoot) {
    $InstallRoot = if ($record) { $record.InstallRoot } else { Get-LanDefaultInstallRoot -Is64BitOs ([Environment]::Is64BitOperatingSystem) }
}
$InstallRoot = Assert-LanSafeInstallRoot -Path $InstallRoot
Initialize-LanInstallParent -Path $InstallRoot
$InstallRoot = Assert-LanSafeInstallRoot -Path $InstallRoot
if ($record -and -not [string]::Equals($record.InstallRoot,$InstallRoot,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The install target differs from the recorded installation.'
}
if (-not $record -and [IO.Directory]::Exists($InstallRoot)) {
    $existing=@(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction Stop)
    $marker=[IO.File]::Exists((Join-Path $InstallRoot 'LanShare.ps1')) -and
        [IO.File]::Exists((Join-Path $InstallRoot 'HostWorker.ps1'))
    if ($existing.Count -gt 0 -and -not $marker) {
        throw 'The install directory contains files that are not a recognized LAN File Sharing installation.'
    }
}
Invoke-LanRecordedHostInstall -InstallRoot $InstallRoot -StateRoot $StateRoot -SourceRoot $PSScriptRoot | Out-Null
Write-Host "Installed to $InstallRoot. No files have been shared yet."
