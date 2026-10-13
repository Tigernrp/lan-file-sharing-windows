foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
Describe 'Online review regression gates' {
    It 'does not reapply settings captured before a concurrent disable' {
        $p=Join-Path $TestDrive 'race.json';$s=New-LanEmptyState
        $status=[pscustomobject]@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';InterfaceAlias='wt0';LocalAddress='100.80.0.1';LocalPeerIdentity='owner';ManagementUrl='https://api.netbird.io:443';ProfileName='default';Peers=@(@{Identity='peer';Address='100.80.0.2'})}
        $s.OnlineSettings.Enabled=$true;$s.OnlineSettings.Binding=Get-LanOnlineBinding $status;$s.OnlineSettings.AllowedPeers=@(@{Identity='peer';Address='100.80.0.2'})
        Write-LanState $p $s
        $box=@{Applied=$false;Disabled=$false}
        $s.OnlineSettings.Enabled=$false;$disabledJson=$s|ConvertTo-Json -Depth 10
        $a=@{GetStatus={ [IO.File]::WriteAllText($p,$disabledJson); $status
        }.GetNewClosure();GetOnlineRule={$null};RestrictLanRule={};ApplyOnlineRule={param($o)$box.Applied=$true}.GetNewClosure();DisableOnlineRule={$box.Disabled=$true}.GetNewClosure()}
        $script:raceAdapter=$a
        Mock Get-LanOnlinePolicyAdapter {$script:raceAdapter}
        $ctx=Get-LanShareOnlineContext -StatePath $p -Adapter $a
        $ctx.Ready | Should Be $false
        $box.Applied | Should Be $false
    }
    It 'disables the Online rule if LAN restriction cannot be enforced' {
        $a=@{GetOnlineRule={@{Description='Created by LAN File Sharing (NetBird)'}};RestrictLanRule={throw 'scope failed'};DisableOnlineRule={$script:closed=$true};ApplyOnlineRule={}}
        $script:closed=$false
        $status=@{ConnectionState='Connected';InterfaceId='vpn';InterfaceAlias='wt0';LocalAddress='100.80.0.1'}
        {Sync-LanOnlineFirewall -Adapter $a -Settings (New-LanOnlineSettings) -Status $status} | Should Throw 'scope failed'
        $script:closed | Should Be $true
    }
    It 'checks the same server identity across a different share name' {
        $p=Join-Path $TestDrive 'maps.json'
        $old=@{Unc='\\100.80.0.2\Data';Transport='NetBird';OnlinePeerIdentity='A';OnlineBinding=@{ManagementUrl='https://api.netbird.io:443';LocalPeerIdentity='owner';ProfileName='default'}}
        Write-LanClientMappings $p @($old)
        $a=@{StatePath=$p;GetOnlineStatus={@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';ManagementUrl='https://api.netbird.io:443';LocalPeerIdentity='owner';ProfileName='default';Peers=@(@{Identity='B';Address='100.80.0.2'})}}}
        {Assert-LanSavedOnlineTarget -Unc '\\100.80.0.2\Other' -Adapter $a} | Should Throw 'identity'
    }
    It 'rejects creation of Guest after Online was enabled' {
        $folder=Join-Path $TestDrive 'guest';[IO.Directory]::CreateDirectory($folder)|Out-Null
        $p=Join-Path $TestDrive 'guest.json';$s=New-LanEmptyState;$s.OnlineSettings.Enabled=$true;Write-LanState $p $s
        $a=@{GetShare={$null};GetNetworkProfiles={@(@{Name='Home';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Private'})};EnableFirewall={};GrantAcl={@()};NewShare={};GetGuestPolicy={@{Managed=$false;RequireSigning=$false;RequireEncryption=$false;GuestEnabled=$true;PasswordProtectedSharing=$false;UnrelatedSharesAtRisk=@()}}}
        {Start-LanHostShare -Selection (Resolve-LanSelection -Kind Folder -Path $folder) -Name Guest -Mode Read -Access @{AuthMode='Guest';AllowedSids=@('S-1-5-21-1-2-3-501');CredentialInfo=$null} -AutoStart $false -StatePath $p -Adapter $a} | Should Throw 'Guest'
    }
}
Describe 'Online native persistence regression' {
    It 'remembers Online in app state without storing a native profile or Windows vault password' {
        Mock Set-LanWindowsCredential {throw 'Must not write Windows vault'}
        $script:nativePersistent=$null
        $key='AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI='
        $status=@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';LocalPeerIdentity='owner';ManagementUrl='https://api.netbird.io:443';ProfileName='default';Peers=@(@{Identity=$key;Address='100.80.0.2'})}
        $a=@{StatePath=(Join-Path $TestDrive 'native.json');CredentialPath=(Join-Path $TestDrive 'creds.json');ExpectedOnlinePeerIdentity=$key;
            GetOnlineStatus={$status}.GetNewClosure();GetOccupiedLetters={@()};GetMapping={param($local)'\\100.80.0.2\Data'};GetSession={'MYPC\LanShare_test'};Disconnect={0};ProbeAccess={};GetRememberedCredential={$null};
            Connect={param($unc,$local,$persistent,$prompt,$user,$password)$script:nativePersistent=$persistent;0}}
        $e=Add-LanClientMap -Unc '\\100.80.0.2\Data' -Letter X -Persistent $true -AuthMode Protected -WindowsAccount 'MYPC\LanShare_test' -Password 'Test#123456' -Adapter $a
        $script:nativePersistent | Should Be $false
        $e.Persistent | Should Be $false
        $e.Transport | Should Be 'NetBird'
        Assert-MockCalled Set-LanWindowsCredential -Times 0 -Exactly -Scope It
    }
}

Describe 'Online copy latency regression' {
    It 'returns a pending model before any status is cached in product script scope' {
        & {
            foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
            $f=New-LanMainForm -WireEvents:$false
            try{(& $f.Tag.ClientForm.Tag.Adapter.GetOnlineStatus).ConnectionState | Should Be 'Connecting'}finally{$f.Dispose()}
        }
    }
    It 'uses the shared cache for client Map and Open status checks' {
        Mock Invoke-LanHostRequest {throw 'UI must not call broker synchronously'}
        $f=New-LanMainForm -WireEvents:$false
        try {
            $online=$f.Tag.Tabs.TabPages[2].Controls[0]
            $online.Tag.LastStatus=@{ConnectionState='Connected';LocalAddress='100.80.0.1'}
            $online.Tag.LastStatusAt=[DateTime]::UtcNow
            (& $f.Tag.ClientForm.Tag.Adapter.GetOnlineStatus).LocalAddress | Should Be '100.80.0.1'
            Assert-MockCalled Invoke-LanHostRequest -Times 0 -Exactly -Scope It
        }finally{$f.Dispose()}
    }
    It 'uses a recent cached status without calling the broker on the click thread' {
        Mock Invoke-LanHostRequest {throw 'Synchronous broker call must not run'}
        $f=New-LanHostForm -WireEvents:$false
        try{
            $entry=[pscustomobject]@{Id='copy';Name='Data';Kind='Folder';SourcePath='C:\Data';Mode='Read';AuthMode='Protected';AutoStart=$true;Status='Running';CredentialInfo=@{UserName='LanShare_test';PasswordCipher='fake'}}
            Update-LanHostList -Ui $f.Tag -StatePath 'unused' -Entries @($entry)
            $f.Tag.GetOnlineStatus={@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';LocalAddress='100.80.0.1';LocalPeerIdentity='owner'}}
            $script:copied=$null
            Invoke-LanCopyLogin -Ui $f.Tag -StatePath 'unused' -Online -ReadState {param($p)@{Shares=@($entry)}} -Unprotect {param($p)'password'} -SetClipboardText {param($text)$script:copied=$text}
            $script:copied | Should Match '100.80.0.1'
            Assert-MockCalled Invoke-LanHostRequest -Times 0 -Exactly -Scope It
        }finally{$f.Dispose()}
    }
}

Describe 'Online remembered credential identity' {
    It 'allows explicit new credentials for a verified new peer without reading the old secret' {
        $key='AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI='
        $status=@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';LocalPeerIdentity='owner';ManagementUrl='https://api.netbird.io:443';ProfileName='default';Peers=@(@{Identity=$key;Address='100.80.0.2'})}
        $a=@{StatePath=(Join-Path $TestDrive 'replace.json');CredentialPath=(Join-Path $TestDrive 'replace-creds.json');ExpectedOnlinePeerIdentity=$key;
            GetOnlineStatus={$status}.GetNewClosure();GetOccupiedLetters={@()};GetMapping={param($l)'\\100.80.0.2\Data'};GetSession={'NEWPC\LanShare_new'};Disconnect={0};ProbeAccess={};LaunchExplorer={};
            GetRememberedCredential={throw 'Old remembered secret must not be read'};Connect={param($u,$l,$p,$prompt,$user,$secret)if($secret -ne 'new-secret'){throw 'wrong secret'};0}}
        $e=Add-LanClientMap -Unc '\\100.80.0.2\Data' -Letter X -AuthMode Protected -WindowsAccount 'NEWPC\LanShare_new' -Password 'new-secret' -Adapter $a
        $e.OnlinePeerIdentity | Should Be $key
        Write-LanClientMappings $a.StatePath @()
        Open-LanUnc -Path '\\100.80.0.2\Data' -AuthMode Protected -WindowsAccount 'NEWPC\LanShare_new' -Password 'new-secret' -Adapter $a
    }
    It 'retains the credential identity guard after its last mapping was forgotten' {
        $a=@{CredentialPath=(Join-Path $TestDrive 'pinned-creds.json');StatePath=(Join-Path $TestDrive 'forgotten.json')}
        $a.VerifiedOnlineTarget=@{Transport='NetBird';OnlinePeerIdentity='A';OnlineBinding=@{ManagementUrl='https://api.netbird.io:443';LocalPeerIdentity='owner';ProfileName='default'}}
        Write-LanClientCredential -Adapter $a -HostName '100.80.0.2' -UserName 'MYPC\LanShare_test' -Password 'old-secret' | Out-Null
        Write-LanClientMappings $a.StatePath @()
        $a.VerifiedOnlineTarget=$null
        $a.GetOnlineStatus={@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';ManagementUrl='https://api.netbird.io:443';LocalPeerIdentity='owner';ProfileName='default';Peers=@(@{Identity='B';Address='100.80.0.2'})}}
        {Get-LanRememberedCredential -HostName '100.80.0.2' -Adapter $a} | Should Throw 'identity'
    }
    It 'does not reuse an unpinned LAN credential for a new Online peer' {
        $a=@{CredentialPath=(Join-Path $TestDrive 'legacy-creds.json')}
        Write-LanClientCredential -Adapter $a -HostName '100.80.0.2' -UserName 'old-user' -Password 'old-secret' | Out-Null
        $a.VerifiedOnlineTarget=@{Transport='NetBird';OnlinePeerIdentity='B'}
        Get-LanRememberedCredential -HostName '100.80.0.2' -Adapter $a | Should Be $null
    }
}
