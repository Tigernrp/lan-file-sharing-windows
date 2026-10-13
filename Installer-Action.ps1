param(
    [ValidateSet('Preview','Apply','Uninstall')][string]$Phase='Preview',
    [Parameter(Mandatory)][string]$InstallRoot,
    [switch]$CleanReset,
    [switch]$Uninstall,
    # Switches are what `powershell -File` can bind without a value, so the desktop shortcut
    # is on unless the installer explicitly asks for no shortcut.
    [switch]$NoDesktopShortcut
)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Installer actions require administrator rights.'
}
foreach($module in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','UserStartup','Reset')) {
    . (Join-Path $PSScriptRoot "src/$module.ps1")
}
$target=Assert-LanSafeInstallRoot -Path $InstallRoot
$preview=Get-LanResetPreview
$record=Get-LanInstallRecord
if (-not $CleanReset -and $record -and
    -not [string]::Equals([string]$record.InstallRoot,$target,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'An installation exists at another location. Select Clean reset to change its location.'
}
$hasExisting=[bool]($preview.HasInstallRecord -or $preview.HostTaskExists -or @($preview.Shares).Count -gt 0 -or $preview.HasCode)
$hasClientGuestSnapshot=[IO.File]::Exists((Get-LanClientGuestStatePath))
if ($Phase -eq 'Preview') {
    $names=(@($preview.Shares | ForEach-Object { [string]$_.Name }) -join ', ')
    if (-not $names) { $names='(none)' }
    Write-Output "Existing directory: $($preview.InstallRoot)"
    Write-Output "Existing application code: $($preview.HasCode)"
    Write-Output "Host startup task: $($preview.HostTaskExists)"
    Write-Output "Client Guest policy snapshot: $hasClientGuestSnapshot"
    Write-Output "Shares to remove on clean reset: $names"
    if ($Uninstall) { Write-Output "Directory to uninstall: $target" }
    else { Write-Output "New install directory: $target" }
    exit 0
}
if ($CleanReset -or $Phase -eq 'Uninstall') {
    if ($hasExisting) { Invoke-LanMachineReset -Preview $preview | Out-Null }
    elseif ($hasClientGuestSnapshot) { Invoke-LanClientGuestReset | Out-Null }
}
if ($Phase -eq 'Uninstall') {
    Write-Output 'LAN File Sharing removed for this computer and current Windows user.'
    exit 0
}
if ($CleanReset -or -not $record -or -not $preview.HostTaskExists) {
    & (Join-Path $PSScriptRoot 'Install-LanShare.ps1') -InstallRoot $target | Out-Null
} else {
    & (Join-Path $PSScriptRoot 'Update-LanShare.ps1') -InstallRoot $target | Out-Null
}
$launcher=Join-Path $target 'LanFileSharing.exe'
if (-not [IO.File]::Exists($launcher)) { throw 'The installed application launcher is missing.' }
$shortcutDir=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath=Join-Path $shortcutDir 'LanFileSharing.lnk'
$shell=New-Object -ComObject WScript.Shell
# Take the icon from the launcher itself. It is compiled with /win32icon, so the icon lives inside
# the executable and cannot go missing. Pointing the shortcut at the separate .ico file instead
# left some machines showing a blank page icon: Explorer caches a shortcut's icon when it first
# draws it, so a shortcut written before that file is in place keeps the generic icon forever, and
# anything that moves or cleans the icon folder breaks it again.
$shortcut=$shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath=$launcher
$shortcut.WorkingDirectory=$target
$shortcut.IconLocation="$launcher,0"
$shortcut.Description='LAN File Sharing'
$shortcut.Save()
if (-not $NoDesktopShortcut) {
    # The user desktop is per-account; the common desktop is what the machine-wide install
    # can create and what every account on this computer then sees.
    $desktopPath=Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'LanFileSharing.lnk'
    if ([IO.File]::Exists($desktopPath)) { Remove-Item -LiteralPath $desktopPath -Force -ErrorAction Stop }
    $desktopShortcut=$shell.CreateShortcut($desktopPath)
    $desktopShortcut.TargetPath=$launcher
    $desktopShortcut.WorkingDirectory=$target
    $desktopShortcut.IconLocation="$launcher,0"
    $desktopShortcut.Description='LAN File Sharing'
    $desktopShortcut.Save()
}
Write-Output "Installed: $target"
