. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Online.ps1"
. "$PSScriptRoot/../src/Network.ps1"
. "$PSScriptRoot/../src/HostBridge.ps1"
Describe 'Online host integration' {
    It 'accepts an empty OnlineStatus payload after actual JSON pipe serialization' {
        $request=@{Action='OnlineStatus';Payload=@{}} | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        { Assert-LanHostRequest -Action $request.Action -Payload $request.Payload } | Should Not Throw
    }
    It 'uses a verified ready VPN without changing public Wi-Fi' {
        $script:changes=0
        $a=@{OnlineContext=@{Ready=$true;Status=@{InterfaceId='vpn';InterfaceAlias='wt0';LocalAddress='100.80.0.1';LocalPeerIdentity='owner'};Settings=@{Binding=@{LocalPeerIdentity='owner'}}};
            GetNetworkProfiles={ @(@{Name='Cafe';InterfaceAlias='Wi-Fi';NetworkCategory='Public'}) };
            SetNetworkProfile={ $script:changes++ }}
        $r=Ensure-LanShareNetwork -Adapter $a
        $r.Transport | Should Be 'NetBird'
        $r.InterfaceId | Should Be 'vpn'
        $script:changes | Should Be 0
    }
    It 'excludes the verified VPN from LAN candidates when Online is disabled' {
        $a=@{OnlineContext=@{Ready=$false;Status=@{InterfaceId='vpn';InterfaceAlias='wt0'};Settings=@{LastKnownInterface=$null}};
            GetNetworkProfiles={ @(@{Name='Home';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Private'},@{Name='VPN';InterfaceAlias='wt0';InterfaceIndex=8;NetworkCategory='Private'}) };
            SetNetworkProfile={ throw 'should not change' }}
        (Ensure-LanShareNetwork -Adapter $a).InterfaceAlias | Should Be 'Ethernet'
    }
    It 'validates typed Online actions before any privileged dispatch' {
        { Assert-LanHostRequest -Action OnlineStatus -Payload @{} } | Should Not Throw
        { Assert-LanHostRequest -Action OnlineEnroll -Payload @{SetupKey='valid-key'} } | Should Not Throw
        { Assert-LanHostRequest -Action OnlineEnroll -Payload @{SetupKey="bad`nkey"} } | Should Throw
        { Assert-LanHostRequest -Action OnlineConfigure -Payload @{Enabled='false';PeerIdentities=@()} } | Should Throw
        { Assert-LanHostRequest -Action OnlineConfigure -Payload @{Enabled=$false;PeerIdentities=@();Command='cmd.exe'} } | Should Throw
    }
}
