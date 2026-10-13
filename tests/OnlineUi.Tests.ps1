foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
$m=Join-Path $PSScriptRoot '../src/OnlineUi.ps1'; if(Test-Path $m){. $m}
Describe 'Online screen' {
    It 'embeds an Online tab and masks registration keys' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            @($f.Controls | Where-Object {$_ -is [Windows.Forms.TabControl]})[0].TabPages.Count | Should Be 3
            $online=@($f.Controls | Where-Object {$_ -is [Windows.Forms.TabControl]})[0].TabPages[2].Controls[0]
            $online.Tag.SetupKey.UseSystemPasswordChar | Should Be $true
            $online.Tag.Install.Text | Should Be 'ติดตั้ง/ซ่อม Online อัตโนมัติ'
            $online.Tag.SignIn.Text | Should Be 'ลงชื่อเข้าใช้ NetBird'
        }finally{$f.Dispose()}
    }
    It 'shows sign in only when the installed client needs enrollment' {
        $f=New-LanOnlineForm -WireEvents:$false
        try {
            $f.Show();[Windows.Forms.Application]::DoEvents()
            $s=New-LanOnlineStatusModel NotEnrolled; $s.Installed=$true
            Update-LanOnlineForm $f.Tag $s
            $f.Tag.SignIn.Visible | Should Be $true
            $f.Tag.Install.Visible | Should Be $true
            $s.ConnectionState='Connected'
            Update-LanOnlineForm $f.Tag $s
            $f.Tag.SignIn.Visible | Should Be $false
        }finally{$f.Dispose()}
    }
    It 'retains six peer selections by identity and distinguishes tunnel from sharing' {
        $f=New-LanOnlineForm -WireEvents:$false
        try {
            $s=New-LanOnlineStatusModel Connected; $s.Installed=$true; $s.LocalAddress='100.80.0.1'
            $s.Peers=@(1..6 | ForEach-Object {[pscustomobject]@{Identity="key$_";Name="Teacher$_";Address="100.80.0.$($_+1)";ConnectionState='Connected';ConnectionType='P2P';LatencyMilliseconds=16}})
            Update-LanOnlineForm $f.Tag $s
            $f.Tag.Peers.Items[4].Checked=$true
            $s.Peers=@($s.Peers[5],$s.Peers[4],$s.Peers[3],$s.Peers[2],$s.Peers[1],$s.Peers[0])
            Update-LanOnlineForm $f.Tag $s
            $f.Tag.Peers.CheckedItems[0].Tag | Should Be 'key5'
            $f.Tag.Status.Text | Should Match 'ปิด'
            $f.Tag.Peers.Items.Count | Should Be 6
        }finally{$f.Dispose()}
    }
    It 'starts only one background operation and clears enrollment input' {
        $f=New-LanOnlineForm -WireEvents:$false
        try {
            $ui=$f.Tag; $ui.SetupKey.Text='secret-test'
            $ui.JobStarter={param($action,$payload) Start-Job {Start-Sleep -Milliseconds 500; @{Installed=$false;ConnectionState='MissingClient';Peers=@()}}}
            Start-LanOnlineUiOperation $ui OnlineEnroll @{SetupKey=$ui.SetupKey.Text}
            $first=$ui.Job
            Start-LanOnlineUiOperation $ui OnlineStatus @{}
            $ui.Job.Id | Should Be $first.Id
            $ui.SetupKey.Text | Should Be ''
        }finally{if($f.Tag.Job){Remove-Job $f.Tag.Job -Force -ErrorAction SilentlyContinue};$f.Dispose()}
    }
}
