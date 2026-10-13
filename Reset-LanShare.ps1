param(
    [ValidateSet('Preview','PreviewUser','PreviewUserSummary','CurrentUser','Machine')][string]$Phase='Preview',
    [string]$PreviewFile
)
$ErrorActionPreference='Stop'
foreach ($module in @('Selection','State','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','UserStartup','Reset')) {
    . (Join-Path $PSScriptRoot "src/$module.ps1")
}
if ($Phase -eq 'Machine') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights are required to remove machine-wide shares and the startup task.'
    }
}
$adapter = New-LanResetAdapter
if ($Phase -eq 'Preview') {
    Get-LanResetPreview -Adapter $adapter | ConvertTo-Json -Depth 20 -Compress
    exit 0
}
if ($Phase -eq 'PreviewUser') {
    Get-LanCurrentUserResetPreview -Adapter $adapter | ConvertTo-Json -Depth 20 -Compress
    exit 0
}
if ($Phase -eq 'PreviewUserSummary') {
    $preview=Get-LanCurrentUserResetPreview -Adapter $adapter
    Format-LanCurrentUserResetPreview -Preview $preview
    exit 0
}
if (-not $PreviewFile -or -not [IO.File]::Exists($PreviewFile)) { throw 'The reviewed reset preview is missing.' }
$reviewed = Get-Content -LiteralPath $PreviewFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if ($Phase -eq 'CurrentUser') {
    Invoke-LanCurrentUserReset -Preview $reviewed -Adapter $adapter | ConvertTo-Json -Depth 10 -Compress
} else {
    Invoke-LanMachineReset -Preview $reviewed -Adapter $adapter | ConvertTo-Json -Depth 10 -Compress
}
