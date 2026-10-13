param(
    [string]$Path = 'tests', [string]$Given,
    [ValidateRange(1,3600)][int]$TimeoutSeconds = 120,
    [switch]$InProcess, [string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$pesterV4 = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -eq 4 } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $pesterV4) {
    throw 'Pester 4.x is required. Install Pester 4.10.1 before running tests.'
}
Import-Module -Name $pesterV4.Path -Force
if (-not [string]::IsNullOrWhiteSpace($Given)) {
    $paths = @($Given.Split(',') | Where-Object { $_.Trim() } | ForEach-Object { Join-Path $PSScriptRoot $_.Trim() })
} else {
    $paths = @(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path })
}
if ($InProcess) {
    $r = Invoke-Pester -Path $paths -PassThru -Quiet
    if ($ResultPath) { $r | Export-Clixml -LiteralPath $ResultPath }
    Write-Host ("Total={0} Passed={1} Failed={2} Skipped={3}" -f $r.TotalCount,$r.PassedCount,$r.FailedCount,$r.SkippedCount)
    foreach ($t in @($r.TestResult | Where-Object { -not $_.Passed })) {
        Write-Host ("--- {0} > {1} > {2}" -f $t.Describe,$t.Context,$t.Name)
        Write-Host ("    {0}" -f $t.FailureMessage)
    }
    if ($r.FailedCount -gt 0) { exit 1 }
    exit 0
}
$files = @($paths | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -Filter '*.Tests.ps1' -File -Recurse }
    else { $item }
} | Sort-Object FullName -Unique)
if ($files.Count -eq 0) { throw 'No test files were found.' }
$total=0; $passed=0; $failed=0; $skipped=0
$scratch = Join-Path $env:TEMP ('LanFileSharing-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    foreach ($file in $files) {
        Write-Host ("Running {0}" -f $file.Name)
        $resultFile = Join-Path $scratch 'result.xml'
        $stdout = Join-Path $scratch 'stdout.txt'
        $stderr = Join-Path $scratch 'stderr.txt'
        if ([IO.File]::Exists($resultFile)) { [IO.File]::Delete($resultFile) }
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -InProcess -Path "' + $file.FullName + '" -ResultPath "' + $resultFile + '"'
        $process = Start-Process powershell.exe -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
        $null = $process.Handle
        try {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                & taskkill.exe /PID $process.Id /T /F | Out-Null
                $total++; $failed++
                Write-Host ("FAIL: {0} timed out after {1}s" -f $file.Name,$TimeoutSeconds)
                continue
            }
            $process.Refresh()
            foreach ($log in @($stdout,$stderr)) {
                if ([IO.File]::Exists($log)) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
            }
            if ([IO.File]::Exists($resultFile)) {
                $r = Import-Clixml -LiteralPath $resultFile
                $total += $r.TotalCount; $passed += $r.PassedCount
                $failed += $r.FailedCount; $skipped += $r.SkippedCount
                if ($process.ExitCode -ne 0 -and $r.FailedCount -eq 0) { $total++; $failed++; Write-Host 'FAIL: test process exited unexpectedly.' }
            } else { $total++; $failed++; Write-Host 'FAIL: test process produced no result.' }
        } finally { $process.Dispose() }
    }
} finally {
    foreach ($name in @('result.xml','stdout.txt','stderr.txt')) {
        $temporaryFile = Join-Path $scratch $name
        if ([IO.File]::Exists($temporaryFile)) { [IO.File]::Delete($temporaryFile) }
    }
    [IO.Directory]::Delete($scratch)
}
Write-Host ("Total={0} Passed={1} Failed={2} Skipped={3}" -f $total,$passed,$failed,$skipped)
if ($failed -gt 0) { exit 1 }
