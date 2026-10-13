Describe 'installer subprocess output' {
    BeforeAll {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../installer/InstallEngine.cs')).Replace('@VERSION@','test')
        $sourcePath = Join-Path $TestDrive 'InstallEngine.cs'
        [IO.File]::WriteAllText($sourcePath,$source)
        $script:engineDll = Join-Path $TestDrive 'engine.dll'
        $compiler = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        & $compiler /nologo /target:library "/out:$script:engineDll" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll $sourcePath (Join-Path $PSScriptRoot '../installer/SetupForm.cs')
        if ($LASTEXITCODE -ne 0) { throw 'Engine compilation failed' }
    }
    It 'drains large stderr output while waiting for stdout' {
        $noisy = Join-Path $TestDrive 'noisy.ps1'
        [IO.File]::WriteAllText($noisy, '[Console]::Error.Write((''e'' * 200000)); [Console]::Out.Write(''finished'')')
        $probe = Join-Path $TestDrive 'probe.ps1'
        $report = Join-Path $TestDrive 'result.txt'
        $body = @'
param($Dll,$Script,$Report)
$assembly = [Reflection.Assembly]::LoadFrom($Dll)
$engine = $assembly.GetType('InstallEngine',$true)
$method = $engine.GetMethod('RunPowerShell',[Reflection.BindingFlags]'NonPublic,Static',$null,[type[]]@([string],[string]),$null)
$result = $method.Invoke($null,[object[]]@($Script,''))
[IO.File]::WriteAllText($Report,[string]$result)
'@
        [IO.File]::WriteAllText($probe,$body)
        $p = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$probe+'" "'+$script:engineDll+'" "'+$noisy+'" "'+$report+'"') -PassThru -WindowStyle Hidden
        try {
            $p.WaitForExit(10000) | Should Be $true
            [IO.File]::ReadAllText($report) | Should Be 'finished'
        } finally {
            if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
            $p.Dispose()
        }
    }
    It 'enforces the timeout before waiting for subprocess output to close' {
        $stuck = Join-Path $TestDrive 'stuck.ps1'
        [IO.File]::WriteAllText($stuck,'Start-Sleep -Seconds 30')
        $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:engineDll))
        $method = $assembly.GetType('InstallEngine',$true).GetMethod('RunPowerShell',[Reflection.BindingFlags]'NonPublic,Static',$null,[type[]]@([string],[string],[int]),$null)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        { $method.Invoke($null,[object[]]@([string]$stuck,'',500)) } | Should Throw 'timed out'
        $watch.Elapsed.TotalSeconds | Should BeLessThan 5
    }
}
