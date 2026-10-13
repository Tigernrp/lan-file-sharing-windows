param([switch]$HostMode,[switch]$AutoLaunch,[switch]$ConfigureGuestClient,[switch]$RestoreGuestClient)
$ErrorActionPreference = 'Stop'
foreach ($module in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')) {
    . (Join-Path $PSScriptRoot "src/$module.ps1")
}
if ($ConfigureGuestClient -or $RestoreGuestClient) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator rights are required to configure Guest SMB.' }
    $guestPath = Get-LanClientGuestStatePath
    if ($ConfigureGuestClient) {
        Set-LanInstalledDirectoryAcl -Path ([IO.Path]::GetDirectoryName($guestPath)) -Role Code
        Enable-LanGuestConfiguration -Role Client -Adapter (New-LanClientAdapter) -StatePath $guestPath | Out-Null
    } else {
        $restore = Restore-LanGuestConfiguration -Role Client -Adapter (New-LanClientAdapter) -StatePath $guestPath
        if (@($restore.Skipped).Count -gt 0) { throw 'Guest policy was changed outside this app; automatic restore was skipped.' }
    }
    exit 0
}
Start-LanShareGui -HostMode:$HostMode -AutoLaunch:$AutoLaunch
