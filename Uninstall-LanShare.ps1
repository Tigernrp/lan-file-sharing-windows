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
    throw 'The uninstall target differs from the recorded installation.'
}
$adapter = New-LanStartupAdapter -SourceRoot $PSScriptRoot -InstallRoot $InstallRoot -StateRoot $StateRoot
Remove-LanHostWorker -Adapter $adapter | Out-Null
if ($record) { Remove-LanInstallRecord -ExpectedPath $InstallRoot }
$guestPath = Get-LanClientGuestStatePath
if (Test-Path -LiteralPath $guestPath) {
    $restore = Restore-LanGuestConfiguration -Role Client -Adapter (New-LanAuthAdapter) -StatePath $guestPath
    if (@($restore.Skipped).Count -gt 0) { throw 'Guest client policy was changed outside this app; its snapshot was retained for manual review.' }
}
Write-Host 'LAN File Sharing was removed. The original shared files were not deleted.'
