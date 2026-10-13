foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
Describe 'Modern sharing workspace' {
    It 'navigates all three workspaces without losing entered values' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show()
            @($f.Tag.Navigation).Count | Should Be 3
            $f.Tag.ClientForm.Tag.Unc.Text='\\TEACHER\Lessons'
            foreach($index in @(1,2,0)){
                $f.Tag.Navigation[$index].PerformClick()
                $f.Tag.Tabs.SelectedIndex | Should Be $index
            }
            $f.Tag.ClientForm.Tag.Unc.Text | Should Be '\\TEACHER\Lessons'
            $f.Tag.PageTitle.Text | Should Match 'ใช้ไฟล์'
        }finally{$f.Dispose()}
    }
    It 'reveals advanced tools and can collapse logs without clearing them' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show()
            $ui=$f.Tag.ClientForm.Tag
            $ui.AdvancedToggle | Should Not BeNullOrEmpty
            $ui.AdvancedBody.Visible | Should Be $false
            $ui.AdvancedToggle.PerformClick()
            $ui.AdvancedBody.Visible | Should Be $true
            [void]$ui.Log.Items.Add('retained entry')
            $ui.LogToggle.PerformClick()
            $ui.Log.Visible | Should Be $false
            $ui.LogToggle.PerformClick()
            $ui.Log.Visible | Should Be $true
            $ui.Log.Items[0].Text | Should Be 'retained entry'
        }finally{$f.Dispose()}
    }
    It 'keeps long forms scrollable and fields inside their cards at small and large sizes' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show()
            foreach($size in @(@(900,700),@(1400,1000))){
                $f.Size=[Drawing.Size]::new($size[0],$size[1])
                foreach($index in 0..2){
                    $f.Tag.Navigation[$index].PerformClick()
                    $page=$f.Tag.Tabs.TabPages[$index].Controls[0]
                    $page.Tag.ScrollHost.AutoScroll | Should Be $true
                    foreach($card in $page.Tag.Cards){
                        ($card.Right -le $page.Tag.ScrollHost.ClientSize.Width) | Should Be $true
                    }
                    foreach($control in @($page.Tag.Unc,$page.Tag.Path,$page.Tag.SetupKey) | Where-Object {$_}){
                        ($control.Right -le $control.Parent.ClientSize.Width) | Should Be $true
                        ($control.Width -ge 200) | Should Be $true
                    }
                }
            }
        }finally{$f.Dispose()}
    }
    It 'shows the dedicated login-block paste box first and keeps it usable at minimum size' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show();$f.Size=[Drawing.Size]::new(900,700);$f.Tag.Navigation[0].PerformClick()
            $u=$f.Tag.ClientForm.Tag
            $u.LoginBlockInput | Should Not BeNullOrEmpty
            $u.LoginBlockInput.Multiline | Should Be $true
            ($u.LoginBlockInput.Height -ge 80) | Should Be $true
            ($u.LoginBlockInput.Width -ge 200) | Should Be $true
            ($u.LoginBlockInput.Right -le $u.LoginBlockInput.Parent.ClientSize.Width) | Should Be $true
            $pasteCard=$u.LoginBlockInput
            while($pasteCard.Parent -and $pasteCard.Parent -ne $u.LayoutRoot){$pasteCard=$pasteCard.Parent}
            $uncCard=$u.Unc
            while($uncCard.Parent -and $uncCard.Parent -ne $u.LayoutRoot){$uncCard=$uncCard.Parent}
            ([array]::IndexOf(@($u.Cards),$pasteCard) -lt [array]::IndexOf(@($u.Cards),$uncCard)) | Should Be $true
            $u.LoginBlockHint.Text | Should Match 'อัตโนมัติ'
        }finally{$f.Dispose()}
    }
    It 'exposes shared startup settings without covering page content' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show()
            $f.Tag.StartupToggle | Should Not BeNullOrEmpty
            $f.Tag.StartupToggle.PerformClick()
            $f.Tag.StartWithHost.Visible | Should Be $true
            ($f.Tag.Tabs.Bottom -le $f.Tag.StartupPanel.Top) | Should Be $true
            $f.Tag.StartupToggle.PerformClick()
            $f.Tag.StartWithHost.Visible | Should Be $false
        }finally{$f.Dispose()}
    }
    It 'reflows credential fields without overlap when changing access mode on a narrow screen' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show();$f.Size=[Drawing.Size]::new(900,700);$f.Tag.Navigation[1].PerformClick()
            $u=$f.Tag.HostForm.Tag
            foreach($mode in @('Protected Password','WindowsCurrent','Guest','Protected Password')){
                $u.Auth.SelectedItem=$mode
                foreach($row in @($u.LayoutRoot.Controls|ForEach-Object {$_.Controls}|ForEach-Object {$_.Controls}|Where-Object {$_ -is [LanModernRow]})){
                    $fields=@($row.Controls|Where-Object {$_.Visible})
                    for($a=0;$a -lt $fields.Count;$a++){
                        for($b=$a+1;$b -lt $fields.Count;$b++){
                            $fields[$a].Bounds.IntersectsWith($fields[$b].Bounds) | Should Be $false
                        }
                    }
                    ($row.Height -ge (($fields|Measure-Object Bottom -Maximum).Maximum)) | Should Be $true
                }
            }
        }finally{$f.Dispose()}
    }
    It 'keeps registration input usable and masked when expanded at minimum size' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show();$f.Size=[Drawing.Size]::new(900,700);$f.Tag.Navigation[2].PerformClick()
            $u=$f.Tag.Tabs.TabPages[2].Controls[0].Tag
            $u.ScrollHost.ScrollControlIntoView($u.EnrollmentToggle);$u.EnrollmentToggle.PerformClick()
            $u.SetupKey.Visible | Should Be $true
            $u.SetupKey.UseSystemPasswordChar | Should Be $true
            ($u.SetupKey.Width -ge 200) | Should Be $true
            ($u.Enroll.Right -le $u.Enroll.Parent.ClientSize.Width) | Should Be $true
            $u.SetupKey.Bounds.IntersectsWith($u.Enroll.Bounds) | Should Be $false
        }finally{$f.Dispose()}
    }
    It 'explains the empty peer list and removes the hint when a teacher appears' {
        $f=New-LanOnlineForm -WireEvents:$false
        try {
            $f.Show();$s=New-LanOnlineStatusModel Connected;$s.Peers=@()
            Update-LanOnlineForm $f.Tag $s
            $f.Tag.EmptyPeerHint | Should Not BeNullOrEmpty
            $f.Tag.EmptyPeerHint.Visible | Should Be $true
            $s.Peers=@([pscustomobject]@{Identity='teacher-key';Name='Teacher';Address='100.80.0.2';ConnectionState='Connected';ConnectionType='P2P';LatencyMilliseconds=16})
            Update-LanOnlineForm $f.Tag $s
            $f.Tag.EmptyPeerHint.Visible | Should Be $false
            $f.Tag.Peers.Items.Count | Should Be 1
        }finally{$f.Dispose()}
    }
    It 'fits the Online peer columns without horizontal scrolling at minimum size' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show();$f.Size=[Drawing.Size]::new(900,700);$f.Tag.Navigation[2].PerformClick()
            $list=$f.Tag.Tabs.TabPages[2].Controls[0].Tag.Peers
            (($list.Columns|Measure-Object Width -Sum).Sum -le $list.ClientSize.Width) | Should Be $true
        }finally{$f.Dispose()}
    }
    It 'expands status messages so multiline connection details remain readable' {
        $f=New-LanMainForm -WireEvents:$false
        try {
            $f.Show();$f.Size=[Drawing.Size]::new(900,700)
            $f.Tag.ClientForm.Tag.Status.Text=((1..10|ForEach-Object {'รายละเอียดการเชื่อมต่อ '+$_}) -join "`r`n")
            ($f.Tag.ClientForm.Tag.Status.Height -ge 160) | Should Be $true
            ($f.Tag.ClientForm.Tag.Status.Bottom -le $f.Tag.ClientForm.Tag.LayoutRoot.Height) | Should Be $true
        }finally{$f.Dispose()}
    }
}
