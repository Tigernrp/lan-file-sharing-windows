. "$PSScriptRoot/../src/State.ps1"
$module=Join-Path $PSScriptRoot '../src/Online.ps1'
if (Test-Path $module) { . $module }
Describe 'Online firewall ownership and scope' {
    BeforeEach {
        $script:rule=$null; $script:disabled=$false; $script:lanExcluded=$null
        $script:path=Join-Path $TestDrive 'state.json'
        $script:status=[pscustomobject]@{Installed=$true;OnlineEnabled=$false;ConnectionState='Connected';LocalAddress='100.80.0.1';LocalPeerIdentity='owner';ManagementUrl='https://api.netbird.io:443';ProfileName='default';InterfaceId='guid';InterfaceAlias='wt0';Peers=@([pscustomobject]@{Identity='teacher1';Name='Teacher';Address='100.80.0.2'})}
        $script:a=@{
            GetStatus={ $script:status }; GetOnlineRule={ $script:rule }
            ApplyOnlineRule={param($options) $script:rule=$options}; DisableOnlineRule={ $script:disabled=$true }
            RemoveOnlineRule={ $script:rule=$null }; RestrictLanRule={param($interface) $script:lanExcluded=$interface}
        }
    }
    It 'only permits selected peer addresses on the verified VPN interface' {
        Set-LanOnlineConfiguration -StatePath $script:path -Enabled $true -PeerIdentities @('teacher1') -Adapter $script:a | Out-Null
        $script:rule.Protocol | Should Be 'TCP'
        $script:rule.LocalPort | Should Be 445
        $script:rule.RemoteAddress | Should Be @('100.80.0.2/32')
        $script:rule.InterfaceAlias | Should Be 'wt0'
        $script:rule.LocalAddress | Should Be '100.80.0.1'
        $script:lanExcluded.InterfaceId | Should Be 'guid'
        (Read-LanState $script:path).OnlineSettings.AllowedPeers[0].Identity | Should Be 'teacher1'
    }
    It 'disables online when binding changes and keeps LAN excluded when disabled' {
        Set-LanOnlineConfiguration -StatePath $script:path -Enabled $true -PeerIdentities @('teacher1') -Adapter $script:a | Out-Null
        $script:status.LocalPeerIdentity='new-owner'
        (Sync-LanOnlineFirewall -StatePath $script:path -Adapter $script:a).Ready | Should Be $false
        $script:disabled | Should Be $true
        Set-LanOnlineConfiguration -StatePath $script:path -Enabled $false -PeerIdentities @() -Adapter $script:a | Out-Null
        $script:lanExcluded.InterfaceId | Should Be 'guid'
    }
    It 'does not modify a foreign rule or enroll an unknown peer' {
        $script:rule=@{Name='LFS-NetBird-SMB';Description='someone else'}
        { Set-LanOnlineConfiguration -StatePath $script:path -Enabled $true -PeerIdentities @('teacher1') -Adapter $script:a } | Should Throw 'another'
        $script:rule.Description | Should Be 'someone else'
        $script:rule=$null
        { Set-LanOnlineConfiguration -StatePath $script:path -Enabled $true -PeerIdentities @('unknown') -Adapter $script:a } | Should Throw 'peer'
    }
    It 'rejects Online enable while an app Guest share exists' {
        $s=New-LanEmptyState; $s.Shares=@([pscustomobject]@{AuthMode='Guest';Name='GuestShare'})
        Write-LanState -Path $script:path -State $s
        { Set-LanOnlineConfiguration -StatePath $script:path -Enabled $true -PeerIdentities @('teacher1') -Adapter $script:a } | Should Throw 'Guest'
        $script:rule | Should BeNullOrEmpty
    }
}
