foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
Describe 'Remembered sharing UI' {
    It 'starts both roles in Protected Password with WindowsCurrent then Guest' {
        foreach($f in @((New-LanHostForm -WireEvents:$false),(New-LanClientForm -WireEvents:$false))){
            try{@($f.Tag.Auth.Items)|Should Be @('Protected Password','WindowsCurrent','Guest');$f.Tag.Auth.Text|Should Be 'Protected Password'}finally{$f.Dispose()}
        }
    }
    It 'restores the most recently selected connection automatically after reopening' {
        $path=Join-Path $TestDrive 'maps.json';$pref=Join-Path $TestDrive 'ui.json';$cred=Join-Path $TestDrive 'creds.json'
        Write-LanClientMappings $path @([pscustomobject]@{Letter='P';Unc='\\TEACHER\Old';AuthMode='WindowsCurrent';SavedAt='2026-10-01T00:00:00Z'},[pscustomobject]@{Letter='Q';Unc='\\TEACHER\Lessons';AuthMode='Protected';WindowsAccount='TEACHER\share';HostName='TEACHER';SavedAt='2026-10-11T00:00:00Z'})
        $a=@{StatePath=$path;CredentialPath=$cred;SkipLivenessCheck=$true}
        Write-LanClientCredential $a 'TEACHER' 'TEACHER\share' 'LongTestPassword1!' |Out-Null
        foreach($iteration in 1..2){
            $f=New-LanClientForm -WireEvents:$false
            try{
                $u=$f.Tag;$u.PreferencePath=$pref;$u.Adapter=$a
                Update-LanClientMapList $u $a
                $u.Unc.Text|Should Be '\\TEACHER\Lessons';$u.Auth.Text|Should Be 'Protected Password';$u.Letter.Text|Should Be 'Q'
                $u.WindowsAccount.Text|Should Be 'TEACHER\share';$u.PasswordInput.Text|Should Be 'LongTestPassword1!';$u.PasswordInput.UseSystemPasswordChar|Should Be $true
            }finally{$f.Dispose()}
        }
    }
    It 'does not overwrite an edited path during a background list refresh' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'prefs.json';$a=@{StatePath=(Join-Path $TestDrive 'maps2.json');SkipLivenessCheck=$true};$u.Adapter=$a
            Write-LanClientMappings $a.StatePath @([pscustomobject]@{Letter='P';Unc='\\TEACHER\Saved';AuthMode='WindowsCurrent';SavedAt='2026-10-11'})
            Update-LanClientMapList $u $a;$u.Unc.Text='\\OTHER\Draft';Update-LanClientMapList $u $a
            $u.Unc.Text|Should Be '\\OTHER\Draft'
        }finally{$f.Dispose()}
    }
    It 'restores a host share and masks its unchanged stored password' {
        $f=New-LanHostForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'hostprefs.json'
            $entry=[pscustomobject]@{Id='saved';Name='Lessons';Kind='Folder';SourcePath='F:\Lessons';Mode='Modify';AuthMode='Protected';AllowedSids=@();AutoStart=$true;CredentialInfo=@{UserName='SchoolShare';PasswordCipher=(Protect-LanSecret 'StoredTestPassword1!')}}
            (Get-Command Restore-LanHostFields -ErrorAction SilentlyContinue)|Should Not BeNullOrEmpty
            Restore-LanHostFields $u $entry
            $u.Path.Text|Should Be 'F:\Lessons';$u.Name.Text|Should Be 'Lessons';$u.Mode.Text|Should Be 'Modify';$u.Auth.Text|Should Be 'Protected Password'
            $u.AccountName.Text|Should Be 'SchoolShare';$u.PasswordInput.Text|Should Be 'StoredTestPassword1!';$u.PasswordInput.UseSystemPasswordChar|Should Be $true
        }finally{$f.Dispose()}
    }
    It 'registers automatic connection without needing a separate startup action' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $script:values=@{};$script:login='';$u=$f.Tag;$u.Root=$TestDrive
            Set-Content (Join-Path $u.Root 'LanFileSharing.exe') 'fake'
            $u.StartupAdapter=@{ReadPreference={param($n)$script:values[$n]};WritePreference={param($n,$v)$script:values[$n]=$v};ReadRun={$script:login};WriteRun={param($v)$script:login=$v};RemoveRun={$script:login=''}}
            (Get-Command Enable-LanClientAutomaticStartup -ErrorAction SilentlyContinue)|Should Not BeNullOrEmpty
            Enable-LanClientAutomaticStartup $u|Out-Null
            $s=Get-LanUserStartupSettings $u.StartupAdapter;$s.StartWithHost|Should Be $true;$s.AutoReconnect|Should Be $true
            $s.LoginCommand|Should Match '--auto'
        }finally{$f.Dispose()}
    }
    It 'preserves an explicitly disabled reconnect preference when editing startup options' {
        $script:startupValues=@{AutoReconnect=0};$script:startupRun=''
        Mock New-LanUserStartupAdapter {
            @{ReadPreference={param($n)$script:startupValues[$n]};WritePreference={param($n,$v)$script:startupValues[$n]=$v};ReadRun={$script:startupRun};WriteRun={param($v)$script:startupRun=$v};RemoveRun={$script:startupRun=''}}
        }
        $f=New-LanMainForm -WireEvents:$true
        try{
            $f.Tag.ClientForm.Tag.ReconnectTimer.Stop()
            $f.Tag.StartMinimized.Checked=$true
            (Get-LanUserStartupSettings).AutoReconnect|Should Be $false
        }finally{$f.Dispose()}
    }
    It 'does not release a legacy password for a changed saved Online peer' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'online-ui.json';$u.Adapter=@{CredentialPath=(Join-Path $TestDrive 'legacy.json')}
            Write-LanClientCredential $u.Adapter '100.80.0.2' 'share' 'LegacyTestPassword1!'|Out-Null
            Mock Test-LanClientOnlineTarget {[pscustomobject]@{Ready=$false;Reason='changed peer'}}
            Restore-LanClientFields $u ([pscustomobject]@{Letter='P';Unc='\\100.80.0.2\Lessons';HostName='100.80.0.2';AuthMode='Protected';Transport='NetBird';OnlinePeerIdentity='old-key'})
            $u.PasswordInput.Text|Should Be ''
            $u.Status.Text|Should Match 'changed peer'
        }finally{$f.Dispose()}
    }
    It 'restores LAN credentials independently of a previous Online operation' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'lan-ui.json';$u.Adapter=@{CredentialPath=(Join-Path $TestDrive 'lan.json')}
            Write-LanClientCredential $u.Adapter 'LANHOST' 'share' 'LanTestPassword1!'|Out-Null
            $u.Adapter.VerifiedOnlineTarget=@{OnlinePeerIdentity='previous'}
            Restore-LanClientFields $u ([pscustomobject]@{Letter='P';Unc='\\LANHOST\Lessons';HostName='LANHOST';AuthMode='Protected'})
            $u.PasswordInput.Text|Should Be 'LanTestPassword1!'
        }finally{$f.Dispose()}
    }
    It 'preserves explicit reconnect disable when connecting again' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $script:values=@{AutoReconnect=0};$script:login='';$u=$f.Tag;$u.Root=$TestDrive
            Set-Content (Join-Path $u.Root 'LanFileSharing.exe') 'fake'
            $u.StartupAdapter=@{ReadPreference={param($n)$script:values[$n]};WritePreference={param($n,$v)$script:values[$n]=$v};ReadRun={$script:login};WriteRun={param($v)$script:login=$v};RemoveRun={$script:login=''}}
            Enable-LanClientAutomaticStartup $u|Out-Null
            (Get-LanUserStartupSettings $u.StartupAdapter).AutoReconnect|Should Be $false
        }finally{$f.Dispose()}
    }
    It 'refreshes watching state without overwriting edited fields' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'watch-ui.json';$a=@{StatePath=(Join-Path $TestDrive 'watch.json');SkipLivenessCheck=$true};$u.Adapter=$a
            $entry=[pscustomobject]@{Letter='P';Unc='\\TEACHER\Saved';AuthMode='WindowsCurrent';Watching=$true}
            Write-LanClientMappings $a.StatePath @($entry);Update-LanClientMapList $u $a
            $u.Unc.Text='\\OTHER\Draft';$entry.Watching=$false;Write-LanClientMappings $a.StatePath @($entry);Update-LanClientMapList $u $a
            $u.CurrentMap.Watching|Should Be $false;$u.Unc.Text|Should Be '\\OTHER\Draft'
            $entry.Watching=$true;Write-LanClientMappings $a.StatePath @($entry);Update-LanClientMapList $u $a
            $u.CurrentMap.Watching|Should Be $true
        }finally{$f.Dispose()}
    }
    It 'retains a current selection when a different remembered profile remains after forgetting one' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'remaining-ui.json';$a=@{StatePath=(Join-Path $TestDrive 'remaining.json');SkipLivenessCheck=$true};$u.Adapter=$a
            $u.ClientFieldsRestored=$true
            Write-LanClientMappings $a.StatePath @([pscustomobject]@{Letter='Q';Unc='\\TEACHER\Remaining';AuthMode='WindowsCurrent'})
            Update-LanClientMapList $u $a
            $u.CurrentMap.Letter|Should Be 'Q'
        }finally{$f.Dispose()}
    }
    It 'does not run broad host repair for a stopped UNC on a timer tick' {
        Mock Get-LanUserStartupSettings {[pscustomobject]@{AutoReconnect=$true;StartWithHost=$false;StartMinimized=$false;ShowAfterSeconds=15}}
        $script:broadRepairCalls=0;$script:watchRepairCalls=0
        Mock Repair-LanMonitoredMappings {$script:watchRepairCalls++;[pscustomobject]@{Connected=@();Waiting=@()}}
        Mock Repair-LanClientConnection {$script:broadRepairCalls++;[pscustomobject]@{Connected=@();Message='broad'}}
        $f=New-LanClientForm -WireEvents:$true
        try{
            $u=$f.Tag;$u.ReconnectTimer.Stop();$u.Adapter=@{StatePath=(Join-Path $TestDrive 'stopped.json');SkipLivenessCheck=$true};$u.PreferencePath=Join-Path $TestDrive 'stopped-ui.json'
            Write-LanClientMappings $u.Adapter.StatePath @([pscustomobject]@{Letter='';ConnectionKind='Unc';Path='\\HOST\Saved';Unc='\\HOST\Saved';AuthMode='WindowsCurrent';Watching=$false})
            $f.Show()
            $method=[Windows.Forms.Timer].GetMethod('OnTick',[Reflection.BindingFlags]'Instance,NonPublic')
            $method.Invoke($u.ReconnectTimer,@([EventArgs]::Empty))
            $script:watchRepairCalls|Should Be 1;$script:broadRepairCalls|Should Be 0
            $u.Status.Text|Should Not Match 'not recognized'
        }finally{$f.Dispose()}
    }
    It 'clears a restored password before the user enters a different server' {
        $f=New-LanClientForm -WireEvents:$true
        try{
            $u=$f.Tag;$u.ReconnectTimer.Stop();$u.PreferencePath=Join-Path $TestDrive 'origin-ui.json';$u.Adapter=@{CredentialPath=(Join-Path $TestDrive 'origin.json')}
            Write-LanClientCredential $u.Adapter 'FIRST' 'share' 'FirstTestPassword1!'|Out-Null
            Restore-LanClientFields $u ([pscustomobject]@{Letter='P';Unc='\\FIRST\Saved';HostName='FIRST';AuthMode='Protected'})
            $u.PasswordInput.Text|Should Be 'FirstTestPassword1!'
            $u.Unc.Text='\\SECOND\Lessons'
            $u.PasswordInput.Text|Should Be ''
            $u.WindowsAccount.Text|Should Be ''
        }finally{$f.Dispose()}
    }
    It 'marks restored passwords as remembered rather than fresh explicit input' {
        $f=New-LanClientForm -WireEvents:$false
        try{
            $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'memory-origin-ui.json';$u.Adapter=@{CredentialPath=(Join-Path $TestDrive 'memory-origin.json')}
            Write-LanClientCredential $u.Adapter 'FIRST' 'share' 'FirstTestPassword1!'|Out-Null
            Restore-LanClientFields $u ([pscustomobject]@{Letter='P';Unc='\\FIRST\Saved';HostName='FIRST';AuthMode='Protected'})
            $u.CredentialWasRemembered|Should Be $true
        }finally{$f.Dispose()}
    }
}
