[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Verify')][switch]$VerifyOnly,
    [Parameter(ParameterSetName = 'Verify')][string]$InstallerPath,
    [Parameter(ParameterSetName = 'Build')][switch]$DevelopmentUnsigned,
    [Parameter(ParameterSetName = 'Build')][string]$SignedPayloadPath,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
    [ValidatePattern('^[0-9]+\.[0-9]+$')][string]$Version = '3.81'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $PSScriptRoot 'ReleaseBuild.psm1'
Import-Module $modulePath -Force

if ($VerifyOnly) {
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        $InstallerPath = Join-Path $root ('release\LanFileSharing-Setup-v' + $Version + '.exe')
    }
    $installer = [IO.Path]::GetFullPath($InstallerPath)
    if (-not [IO.File]::Exists($installer)) { throw 'Installer to verify is missing.' }
    $reportDirectory = Join-Path $root 'artifacts\verification'
    [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
    $report = Join-Path $reportDirectory ('verify-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $process = Start-Process -FilePath $installer -ArgumentList ('--verify "' + $report + '"') -PassThru -WindowStyle Hidden
        $null = $process.Handle
        try {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
                throw ('Embedded release verification timed out after {0}s.' -f $TimeoutSeconds)
            }
            $process.Refresh()
            if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($report) -or [IO.File]::ReadAllText($report) -notmatch '^OK files=\d+') {
                throw 'Embedded release verification failed.'
            }
        } finally {
            $process.Dispose()
        }
        [IO.File]::ReadAllText($report)
    } finally { if ([IO.File]::Exists($report)) { [IO.File]::Delete($report) } }
    exit 0
}

if ($DevelopmentUnsigned) {
    if (-not [string]::IsNullOrWhiteSpace($SignedPayloadPath)) { throw 'DevelopmentUnsigned cannot consume SignedPayloadPath.' }
    $output = Join-Path $root 'artifacts\development-unsigned'
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $payload = New-LanUnsignedPayload -SourceRoot $root -Version $Version -OutputDirectory $output
    $installer = New-LanInstallerFromPayload -PayloadPath $payload -Version $Version -OutputDirectory $output -RequireSignedPayload $false
    Write-Output $installer
    exit 0
}

if ([string]::IsNullOrWhiteSpace($SignedPayloadPath)) {
    throw 'A normal release requires -SignedPayloadPath. Use -DevelopmentUnsigned only for local testing.'
}
$release = Join-Path $root 'release'
[IO.Directory]::CreateDirectory($release) | Out-Null
New-LanInstallerFromPayload -PayloadPath $SignedPayloadPath -Version $Version -OutputDirectory $release -RequireSignedPayload $true
