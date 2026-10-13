. "$PSScriptRoot/../src/State.ps1"
$onlineModule = Join-Path $PSScriptRoot '../src/Online.ps1'
if (Test-Path $onlineModule) { . $onlineModule }

function New-TestOnlineJson {
    param([int]$Count=6)
    $peers = @(1..$Count | ForEach-Object {
        $bytes = New-Object byte[] 32
        for ($j=0;$j -lt 32;$j++) { $bytes[$j]=[byte]$_ }
        @{fqdn="teacher$_.netbird.cloud";netbirdIp="100.80.0.$($_+1)";publicKey=[Convert]::ToBase64String($bytes);status='Connected';connectionType=$(if ($_ -eq 2){'Relayed'}elseif($_ -eq 3){'-'}else{'P2P'});latency=16000000}
    })
    return (@{daemonStatus='Connected';management=@{connected=$true;url='https://api.netbird.io:443'};signal=@{connected=$true};netbirdIp='100.80.0.1/16';publicKey='CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=';profileName='default';peers=@{details=$peers}} | ConvertTo-Json -Depth 8)
}
Describe 'NetBird online status and state' {
    It 'normalizes six peers and reports connection types and nanosecond latency' {
        $s=ConvertFrom-LanNetBirdStatus -Json (New-TestOnlineJson)
        $s.ConnectionState | Should Be 'Connected'
        $s.LocalAddress | Should Be '100.80.0.1'
        @($s.Peers).Count | Should Be 6
        $s.Peers[0].ConnectionType | Should Be 'P2P'
        $s.Peers[1].ConnectionType | Should Be 'Relay'
        $s.Peers[2].ConnectionType | Should Be 'Unknown'
        $s.Peers[0].LatencyMilliseconds | Should Be 16
    }
    It 'does not infer connectivity from a string boolean or missing identity' {
        $raw=New-TestOnlineJson | ConvertFrom-Json
        $raw.management.connected='false'
        (ConvertFrom-LanNetBirdStatus ($raw | ConvertTo-Json -Depth 8)).ConnectionState | Should Be 'Unsupported'
        $raw.management.connected=$true; $raw.publicKey=''
        (ConvertFrom-LanNetBirdStatus ($raw | ConvertTo-Json -Depth 8)).ConnectionState | Should Be 'Unsupported'
        (ConvertFrom-LanNetBirdStatus '{broken').ConnectionState | Should Be 'Error'
    }
    It 'represents an unenrolled client without inventing an address' {
        $s=ConvertFrom-LanNetBirdStatus '{"daemonStatus":"NeedsLogin"}'
        $s.ConnectionState | Should Be 'NotEnrolled'
        $s.LocalAddress | Should BeNullOrEmpty
    }
    It 'defaults old state to Online disabled without changing its share data' {
        $p=Join-Path $TestDrive 'old.json'
        [IO.File]::WriteAllText($p,'{"Version":1,"Shares":[{"Name":"Original"}],"Journal":[],"GuestSnapshots":[]}')
        $s=Read-LanState $p
        $s.Shares[0].Name | Should Be 'Original'
        $s.OnlineSettings.Enabled | Should Be $false
        (New-LanEmptyState).OnlineSettings.Version | Should Be 1
    }
}
