. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Online.ps1"
. "$PSScriptRoot/../src/ClientMap.ps1"
. "$PSScriptRoot/../src/Ui.ps1"
Describe 'Online credential destination identity' {
    BeforeEach {
        $script:s=[pscustomobject]@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';LocalAddress='100.80.0.1';LocalPeerIdentity='owner';ManagementUrl='https://api.netbird.io:443';ProfileName='default';Peers=@([pscustomobject]@{Identity='teacher1';Name='Teacher';Address='100.80.0.2'})}
        $script:a=@{GetStatus={ $script:s }}
        $script:e=[pscustomobject]@{Letter='X';Unc='\\100.80.0.2\Data';Transport='NetBird';OnlinePeerIdentity='teacher1';OnlineBinding=(Get-LanOnlineBinding $script:s)}
    }
    It 'does not send credentials when the same address belongs to another key' {
        (Resolve-LanOnlineMappingTarget -Entry $script:e -OnlineAdapter $script:a).Ready | Should Be $true
        $script:s.Peers[0].Identity='someone-else'
        (Resolve-LanOnlineMappingTarget -Entry $script:e -OnlineAdapter $script:a).Ready | Should Be $false
        $script:e.Unc | Should Be '\\100.80.0.2\Data'
    }
    It 'suspends retry when Online is manually disabled but does not affect LAN' {
        $script:s.OnlineEnabled=$false
        (Resolve-LanOnlineMappingTarget -Entry $script:e -OnlineAdapter $script:a).Ready | Should Be $false
        (Resolve-LanOnlineMappingTarget -Entry @{Unc='\\SERVER\Data'} -OnlineAdapter $script:a).Ready | Should Be $true
    }
    It 'guards automatic reconnect before reading credentials' {
        $p=Join-Path $TestDrive 'mappings.json'
        $script:e | Add-Member Persistent $false
        $script:e | Add-Member AuthMode 'Protected'
        Write-LanClientMappings $p @($script:e)
        $script:s.Peers[0].Identity='someone-else'
        $script:secretsRead=0; $script:connectCalls=0
        $a=@{StatePath=$p;GetOnlineStatus={ $script:s };GetMapping={ $null };
            GetRememberedCredential={ $script:secretsRead++; throw 'Secret should not be read' };
            Connect={ $script:connectCalls++; 0 }}
        Repair-LanMonitoredMappings -Adapter $a | Out-Null
        $script:secretsRead | Should Be 0
        $script:connectCalls | Should Be 0
        @(Read-LanClientMappings $p).Count | Should Be 1
    }
    It 'copies a qualified account and retains peer identity in the pasted login block' {
        $entry=@{Name='Data';AuthMode='Protected';CredentialInfo=@{UserName='LanShare_teacher'}}
        $text=Format-LanOnlineLoginBlock -Entry $entry -OnlineStatus $script:s -Password 'test-password' -ComputerName 'MYPC'
        $block=ConvertFrom-LanLoginBlock $text
        $block.UserName | Should Be 'MYPC\LanShare_teacher'
        $block.Unc | Should Be '\\100.80.0.1\Data'
        $block.OnlinePeerIdentity | Should Be 'owner'
        $text | Should Not Match 'SetupKey'
    }
}
