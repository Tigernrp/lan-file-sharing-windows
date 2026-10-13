Describe 'test runner isolation and deadline' {
    It 'finishes a stuck test file and reports failure within its deadline' {
        $fixtureName = 'stuck-fixture-' + [guid]::NewGuid().ToString('N') + '.Tests.ps1'
        $fixture = Join-Path (Split-Path -Parent $PSScriptRoot) $fixtureName
        [IO.File]::WriteAllText($fixture,"Describe 'stuck' { It 'never finishes' { Start-Sleep -Seconds 30 } }")
        $runner = Join-Path $PSScriptRoot 'Run-Tests.ps1'
        $output = Join-Path $TestDrive 'runner-output.txt'
        $p = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$runner+'" -Path "'+$fixtureName+'" -TimeoutSeconds 2') -RedirectStandardOutput $output -PassThru -WindowStyle Hidden
        $null = $p.Handle
        try {
            $p.WaitForExit(12000) | Should Be $true
            $p.ExitCode | Should Be 1
            [IO.File]::ReadAllText($output) | Should Match 'timed out'
        } finally {
            if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
            $p.Dispose()
            [IO.File]::Delete($fixture)
        }
    }
}
