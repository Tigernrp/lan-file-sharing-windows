. "$PSScriptRoot/../src/State.ps1"
$module=Join-Path $PSScriptRoot '../src/Online.ps1'
if (Test-Path $module) { . $module }
Describe 'NetBird provider boundaries' {
    It 'rejects untrusted executable locations' {
        $p=Join-Path $TestDrive 'netbird.exe'
        [IO.File]::WriteAllText($p,'fake')
        { Assert-LanNetBirdClient -Path $p } | Should Throw 'trusted'
    }
    It 'uses a child environment for the key and redacts provider errors' {
        $script:seenArgs=$null; $script:seenEnv=$null
        $a=@{ FindClient={ 'C:\Program Files\NetBird\netbird.exe' }; AssertTrustedClient={param($p)};
            RunProcess={param($path,$arguments,$environment,$timeout)
                $script:seenArgs=$arguments; $script:seenEnv=@{}; foreach($k in $environment.Keys){$script:seenEnv[$k]=$environment[$k]}
                @{ExitCode=1;Stdout='';Stderr=('rejected '+$environment.NB_SETUP_KEY);TimedOut=$false}
            }}
        $r=Invoke-LanNetBirdProcess -Operation Up -SetupKey 'private-test-key' -TimeoutMilliseconds 60000 -Adapter $a
        $script:seenArgs | Should Not Match 'private-test-key'
        $script:seenEnv.NB_SETUP_KEY | Should Be 'private-test-key'
        $r.Stderr | Should Not Match 'private-test-key'
        { Invoke-LanNetBirdProcess -Operation Up -SetupKey "bad`nkey" -Adapter $a } | Should Throw
    }
    It 'bounds subprocess output and cancels a stuck process' {
        $p=Join-Path $TestDrive 'noise.ps1'
        [IO.File]::WriteAllText($p,'[Console]::Error.Write((''e''*200000)); [Console]::Out.Write(''done'')')
        $shell=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r=Invoke-LanOnlineNativeProcess -Path $shell -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "'+$p+'"') -Environment @{} -TimeoutMilliseconds 5000
        $r.ExitCode | Should Be 0
        $r.Stdout | Should Be 'done'
        [IO.File]::WriteAllText($p,'Start-Sleep -Seconds 20')
        $w=[Diagnostics.Stopwatch]::StartNew()
        $r=Invoke-LanOnlineNativeProcess -Path $shell -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "'+$p+'"') -Environment @{} -TimeoutMilliseconds 500
        $r.TimedOut | Should Be $true
        $w.Elapsed.TotalSeconds | Should BeLessThan 5
    }
    It 'does not accept an interface name without a matching address and caches failures' {
        $stats=@{Calls=0}
        $key='CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk='
        $json=@{daemonStatus='Connected';management=@{connected=$true;url='https://api.netbird.io:443'};signal=@{connected=$true};netbirdIp='100.80.0.1/16';publicKey=$key;peers=@{details=@()}} | ConvertTo-Json -Depth 5
        $a=@{FindClient={'C:\Program Files\NetBird\netbird.exe'};AssertTrustedClient={param($p)};GetClock={ [DateTime]::UtcNow };
            GetInterfaceAddresses={ @(@{InterfaceAlias='wt0';InterfaceId='vpn-guid';Address='100.80.0.2'}) };
            RunProcess={param($p,$args,$env,$timeout) $stats.Calls++; @{ExitCode=0;Stdout=$json;Stderr='';TimedOut=$false} }.GetNewClosure()}
        (Get-LanOnlineStatus -Adapter $a).ConnectionState | Should Be 'Error'
        (Get-LanOnlineStatus -Adapter $a).ConnectionState | Should Be 'Error'
        $stats.Calls | Should Be 1
    }
}
