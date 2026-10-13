$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $child.ExitCode
}
$existing = Get-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -ErrorAction SilentlyContinue
if ($existing) {
    . (Join-Path $PSScriptRoot 'src/InstallLocation.ps1')
    $record = Get-LanInstallRecord
    $installedRoot = if ($record) { $record.InstallRoot } else { Join-Path $env:ProgramFiles 'LanFileSharing' }
    $installedRoot = [IO.Path]::GetFullPath($installedRoot).TrimEnd('\')
    $sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if ([string]::Equals($sourceRoot, $installedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($module in @('Selection','State','Online','Auth','SingleFile','Host','Startup')) {
            . (Join-Path $sourceRoot "src/$module.ps1")
        }
        $stateRoot = Join-Path $env:ProgramData 'LanFileSharing'
        $adapter = New-LanStartupAdapter -SourceRoot $sourceRoot -InstallRoot $installedRoot -StateRoot $stateRoot
        Refresh-LanHostWorkerInPlace -Adapter $adapter | Out-Null
        Write-Host 'Host files in Program Files were verified and the worker restarted. Existing shares were preserved.'
    } else {
        & (Join-Path $PSScriptRoot 'Update-LanShare.ps1') -InstallRoot $installedRoot
        Write-Host 'Host updated. Existing share settings were preserved.'
    }
} else {
    & (Join-Path $PSScriptRoot 'Install-LanShare.ps1')
    Write-Host 'Host installed. Open the sharer mode to choose a share.'
}
