param([Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator approval is required for Online setup.'}
$base=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'LanFileSharing\OnlineSetup')).TrimEnd('\')
$full=[IO.Path]::GetFullPath($ResultPath)
if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full) -ine '.json'){
    throw 'Invalid Online setup result path.'
}
[IO.Directory]::CreateDirectory($base)|Out-Null
. (Join-Path $PSScriptRoot 'src\Online.ps1')
try {
    $result=Invoke-LanOnlineInstallRepair
    $result|Add-Member -NotePropertyName Message -NotePropertyValue 'ติดตั้งและซ่อม Online สำเร็จ' -Force
    $exitCode=0
} catch {
    $result=[pscustomobject]@{Passed=$false;Message=$_.Exception.Message;Error=$_.Exception.Message}
    $exitCode=1
}
$temporary=$full+'.tmp'
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $temporary -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $full -Force
exit $exitCode
