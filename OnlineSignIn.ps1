param([Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator approval is required for NetBird sign in.'}
$base=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'LanFileSharing\OnlineSetup')).TrimEnd('\')
$full=[IO.Path]::GetFullPath($ResultPath)
if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full) -ine '.json'){
    throw 'Invalid Online sign-in result path.'
}
[IO.Directory]::CreateDirectory($base)|Out-Null
. (Join-Path $PSScriptRoot 'src\Online.ps1')
try {
    $status=Connect-LanOnlineMachineInteractive -Adapter (New-LanOnlineAdapter)
    $result=[pscustomobject]@{Passed=($status.ConnectionState -eq 'Connected');Message=$(if($status.ConnectionState -eq 'Connected'){'ลงชื่อเข้าใช้ NetBird สำเร็จ'}else{'NetBird ยังไม่เชื่อมต่อหลังลงชื่อเข้าใช้'});ConnectionState=$status.ConnectionState}
    $exitCode=if($result.Passed){0}else{1}
} catch {
    $result=[pscustomobject]@{Passed=$false;Message=$_.Exception.Message;Error=$_.Exception.Message}
    $exitCode=1
}
$temporary=$full+'.tmp'
$result|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $temporary -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $full -Force
exit $exitCode
