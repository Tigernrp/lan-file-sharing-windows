function Update-LanOnlineForm {
    param([hashtable]$Ui,$Status)
    if (-not $Status) { return }
    $Ui.LastStatus=$Status
    $Ui.LastStatusAt=[DateTime]::UtcNow
    $stateText=switch($Status.ConnectionState){
        MissingClient{'ยังไม่ได้ติดตั้ง NetBird'} NotEnrolled{'ยังไม่ได้ลงทะเบียนเครื่อง'} Connecting{'กำลังเชื่อมต่อ'}
        Connected{'VPN เชื่อมต่อแล้ว'} Disconnected{'VPN ยังไม่เชื่อมต่อ'} Unsupported{'กรุณาอัปเดต NetBird'} default{'ตรวจสอบการเชื่อมต่อ NetBird'}
    }
    $Ui.Status.Text=$stateText+' | แชร์ Online: '+$(if($Status.OnlineEnabled){'เปิด'}else{'ปิด'})
    if($Status.LocalAddress){$Ui.Status.Text+=' | IP: '+$Status.LocalAddress}
    if($Status.Error){$Ui.Status.Text+=' — '+$Status.Error}
    if($Ui.SignIn){$Ui.SignIn.Visible=($Status.ConnectionState -eq 'NotEnrolled')}
    $checked=@($Ui.Peers.CheckedItems | ForEach-Object { [string]$_.Tag })
    if(-not $Ui.HasLoadedPeers){$checked=@($Status.AllowedPeerIdentities)}
    $Ui.Peers.BeginUpdate()
    try {
        $Ui.Peers.Items.Clear()
        foreach($peer in @($Status.Peers)){
            $row=New-Object Windows.Forms.ListViewItem([string]$peer.Name)
            $row.Tag=[string]$peer.Identity
            foreach($value in @($peer.Address,$peer.ConnectionState,$peer.ConnectionType,$peer.LatencyMilliseconds)){
                [void]$row.SubItems.Add([string]$value)
            }
            $row.Checked=([string]$peer.Identity -cin $checked)
            [void]$Ui.Peers.Items.Add($row)
        }
        $Ui.HasLoadedPeers=$true
    }finally{$Ui.Peers.EndUpdate()}
    if($Ui.EmptyPeerHint){$Ui.EmptyPeerHint.Visible=($Ui.Peers.Items.Count -eq 0)}
}

function Start-LanOnlineUiOperation {
    param([hashtable]$Ui,[ValidateSet('OnlineStatus','OnlineEnroll','OnlineConfigure')][string]$Action,$Payload=@{})
    if($Ui.Disposed -or $Ui.Job -or $Ui.SetupProcess){return}
    try {
        $Ui.Job=& $Ui.JobStarter $Action $Payload $Ui.Root
        $Ui.Operation=$Action
        $Ui.Enroll.Enabled=$false; $Ui.Enable.Enabled=$false; $Ui.Disable.Enabled=$false; $Ui.Install.Enabled=$false; $Ui.SignIn.Enabled=$false
        if($Action -ne 'OnlineStatus'){$Ui.Status.Text='กำลังดำเนินการ Online...'}
    }catch{$Ui.Status.Text='เริ่มงานไม่สำเร็จ: '+$_.Exception.Message}
    finally{if($Action -eq 'OnlineEnroll'){$Ui.SetupKey.Clear()}}
}

function Complete-LanOnlineUiOperation {
    param([hashtable]$Ui)
    if($Ui.Disposed -or -not $Ui.Job -or $Ui.Job.State -in @('Running','NotStarted')){return}
    try {
        $result=Receive-Job -Job $Ui.Job -ErrorAction Stop
        if($Ui.Job.State -ne 'Completed'){throw 'Online operation did not complete.'}
        if($result){& $Ui.UpdateForm -Ui $Ui -Status $result}
    }catch{$Ui.Status.Text='Online ยังไม่พร้อม: '+$_.Exception.Message}
    finally{
        Remove-Job $Ui.Job -Force -ErrorAction SilentlyContinue
        $Ui.Job=$null; $Ui.Enroll.Enabled=$true; $Ui.Enable.Enabled=$true; $Ui.Disable.Enabled=$true; $Ui.Install.Enabled=$true; $Ui.SignIn.Enabled=$true
    }
}

function Start-LanOnlineElevatedSetup {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ResultPath)
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script=Join-Path $Root 'OnlineSetup.ps1'
    if(-not [IO.File]::Exists($script)){throw 'ไม่พบตัวช่วยติดตั้ง Online กรุณาติดตั้ง LAN File Sharing รุ่นล่าสุดอีกครั้ง'}
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -ResultPath "'+$ResultPath+'"'
    return Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
}

function Start-LanOnlineElevatedSignIn {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ResultPath)
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script=Join-Path $Root 'OnlineSignIn.ps1'
    if(-not [IO.File]::Exists($script)){throw 'ไม่พบตัวช่วยลงชื่อเข้าใช้ Online กรุณาติดตั้ง LAN File Sharing รุ่นล่าสุดอีกครั้ง'}
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -ResultPath "'+$ResultPath+'"'
    return Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
}

function Start-LanOnlineSetupUiOperation {
    param([hashtable]$Ui)
    if($Ui.Disposed -or $Ui.Job -or $Ui.SetupProcess){return}
    try {
        $directory=Join-Path $env:LOCALAPPDATA 'LanFileSharing\OnlineSetup'
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        $result=Join-Path $directory ('result-'+[guid]::NewGuid().ToString('N')+'.json')
        $Ui.SetupResultPath=$result
        $Ui.ExternalOperation='Setup'
        $Ui.SetupProcess=& $Ui.SetupStarter $Ui.Root $result
        $Ui.Install.Enabled=$false; $Ui.SignIn.Enabled=$false; $Ui.Enroll.Enabled=$false; $Ui.Enable.Enabled=$false; $Ui.Disable.Enabled=$false
        $Ui.Status.Text='กำลังดาวน์โหลด ตรวจลายเซ็น ติดตั้ง และซ่อม NetBird... กรุณารอ'
    } catch {
        $Ui.SetupProcess=$null
        $Ui.Status.Text=if($_.Exception.NativeErrorCode -eq 1223){'ยกเลิกการติดตั้ง Online — ต้องกด Yes ที่หน้าต่างอนุญาตของ Windows'}else{'เริ่มติดตั้ง Online ไม่สำเร็จ: '+$_.Exception.Message}
    }
}

function Start-LanOnlineSignInUiOperation {
    param([hashtable]$Ui)
    if($Ui.Disposed -or $Ui.Job -or $Ui.SetupProcess){return}
    try {
        $directory=Join-Path $env:LOCALAPPDATA 'LanFileSharing\OnlineSetup'
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        $result=Join-Path $directory ('signin-'+[guid]::NewGuid().ToString('N')+'.json')
        $Ui.SetupResultPath=$result;$Ui.ExternalOperation='SignIn'
        $Ui.SetupProcess=& $Ui.SignInStarter $Ui.Root $result
        $Ui.Install.Enabled=$false;$Ui.SignIn.Enabled=$false;$Ui.Enroll.Enabled=$false;$Ui.Enable.Enabled=$false;$Ui.Disable.Enabled=$false
        $Ui.Status.Text='กำลังเปิดเว็บ NetBird — ลงชื่อเข้าใช้ด้วยบัญชีเดิม แล้วกลับมาที่โปรแกรม'
    } catch {
        $Ui.SetupProcess=$null
        $Ui.Status.Text=if($_.Exception.NativeErrorCode -eq 1223){'ยกเลิกการลงชื่อเข้าใช้ Online — ต้องกด Yes ที่หน้าต่างอนุญาตของ Windows'}else{'เริ่มลงชื่อเข้าใช้ Online ไม่สำเร็จ: '+$_.Exception.Message}
    }
}

function Complete-LanOnlineSetupUiOperation {
    param([hashtable]$Ui)
    if($Ui.Disposed -or -not $Ui.SetupProcess -or -not $Ui.SetupProcess.HasExited){return}
    try {
        if(-not [IO.File]::Exists($Ui.SetupResultPath)){throw 'ตัวติดตั้ง Online หยุดก่อนส่งผลลัพธ์กลับมา'}
        $result=Get-Content -LiteralPath $Ui.SetupResultPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if(-not $result.Passed){throw [string]$result.Message}
        $Ui.Status.Text=if($Ui.ExternalOperation -eq 'SignIn'){'ลงชื่อเข้าใช้ NetBird สำเร็จ กำลังตรวจสถานะ...'}else{'Online ติดตั้งและซ่อมเรียบร้อย กำลังตรวจสถานะการเชื่อมต่อ...'}
        $Ui.LastPoll=[DateTime]::MinValue
    } catch {$Ui.Status.Text='ติดตั้ง/ซ่อม Online ไม่สำเร็จ: '+$_.Exception.Message}
    finally {
        try{$Ui.SetupProcess.Dispose()}catch{}
        $Ui.SetupProcess=$null
        if($Ui.SetupResultPath -and [IO.File]::Exists($Ui.SetupResultPath)){Remove-Item -LiteralPath $Ui.SetupResultPath -Force -ErrorAction SilentlyContinue}
        $Ui.SetupResultPath=$null
        $Ui.ExternalOperation=$null
        $Ui.Install.Enabled=$true; $Ui.SignIn.Enabled=$true; $Ui.Enroll.Enabled=$true; $Ui.Enable.Enabled=$true; $Ui.Disable.Enabled=$true
    }
}

function New-LanOnlineForm {
    param([bool]$WireEvents=$true,[hashtable]$BridgeAdapter)
    $f=New-Object Windows.Forms.Form
    $f.Text='Online'; $f.Size=[Drawing.Size]::new(940,760); $f.AutoScroll=$true
    $f.Font=New-Object Drawing.Font('Segoe UI',10)
    $intro=New-Object Windows.Forms.Label
    $intro.Text='แชร์ระหว่างเครื่องที่อยู่คนละสถานที่ ไม่ต้องมีเครื่องกลางเพิ่ม'
    $intro.SetBounds(20,20,875,32); $f.Controls.Add($intro)
    $install=New-Object Windows.Forms.Button; $install.Text='ติดตั้ง/ซ่อม Online อัตโนมัติ'; $install.SetBounds(20,65,240,36); $f.Controls.Add($install)
    $signIn=New-Object Windows.Forms.Button; $signIn.Text='ลงชื่อเข้าใช้ NetBird'; $signIn.SetBounds(270,65,190,36); $signIn.Visible=$false; $f.Controls.Add($signIn)
    $console=New-Object Windows.Forms.Button; $console.Text='จัดการเครือข่าย / สร้างรหัส'; $console.SetBounds(195,65,270,36); $f.Controls.Add($console)
    $refresh=New-Object Windows.Forms.Button; $refresh.Text='ตรวจสถานะ'; $refresh.SetBounds(480,65,150,36); $f.Controls.Add($refresh)
    $label=New-Object Windows.Forms.Label; $label.Text='รหัสลงทะเบียนเครื่องนี้ (ใช้ครั้งแรก)'; $label.SetBounds(20,120,340,30); $f.Controls.Add($label)
    $key=New-Object Windows.Forms.TextBox; $key.UseSystemPasswordChar=$true; $key.SetBounds(20,153,650,30); $f.Controls.Add($key)
    $enroll=New-Object Windows.Forms.Button; $enroll.Text='ลงทะเบียน / เชื่อมต่อ'; $enroll.SetBounds(685,150,205,36); $f.Controls.Add($enroll)
    $status=New-Object Windows.Forms.Label; $status.Text='กดตรวจสถานะ หรือทำการตั้งค่าครั้งแรก'; $status.SetBounds(20,205,875,70); $f.Controls.Add($status)
    $note=New-Object Windows.Forms.Label
    $note.Text='เลือกเครื่องที่อนุญาตให้เข้าถึงแชร์ตามสิทธิ์บัญชี Windows ของเครื่องนี้ แล้วเปิด Online'
    $note.SetBounds(20,285,875,50); $f.Controls.Add($note)
    $list=New-Object Windows.Forms.ListView; $list.View='Details'; $list.CheckBoxes=$true; $list.FullRowSelect=$true
    $list.SetBounds(20,345,875,220); $list.Anchor='Top,Left,Right'
    foreach($col in @(@('เครื่องที่อนุญาต',285),@('IP',145),@('สถานะ',130),@('เส้นทาง',105),@('หน่วง (ms)',130))){[void]$list.Columns.Add($col[0],$col[1])}
    $f.Controls.Add($list)
    $enable=New-Object Windows.Forms.Button; $enable.Text='เปิด Online ตามที่เลือก'; $enable.SetBounds(20,580,245,38); $f.Controls.Add($enable)
    $disable=New-Object Windows.Forms.Button; $disable.Text='ปิดแชร์ Online'; $disable.SetBounds(280,580,180,38); $f.Controls.Add($disable)
    $help=New-Object Windows.Forms.Label
    $help.Text='หลังตั้งค่า ใช้ปุ่มคัดลอกข้อมูลเข้าใช้ Online ที่แท็บผู้แชร์ แล้ววางที่เครื่องครู'+"`r`n"+'ฟรีตามขอบเขต NetBird; เครื่องผู้แชร์ต้องเปิดอยู่ ความเร็วแบ่งตาม Upload และ P2P/Relay'
    $help.SetBounds(20,635,875,85); $f.Controls.Add($help)
    $ui=@{Root=(Split-Path -Parent $PSScriptRoot);SetupKey=$key;Peers=$list;Status=$status;Enroll=$enroll;Enable=$enable;Disable=$disable;
        Job=$null;Disposed=$false;HasLoadedPeers=$false;LastStatus=$null;Operation=$null;Timer=$null;Install=$install;SignIn=$signIn;Console=$console;Refresh=$refresh;
        SetupProcess=$null;SetupResultPath=$null;ExternalOperation=$null}
    $ui.JobStarter={param($action,$payload,$root)
        Start-Job -ArgumentList $root,$action,$payload -ScriptBlock {
            param($root,$action,$payload)
            $ErrorActionPreference='Stop'
            foreach($module in @('Selection','State','Progress','Online','Auth','SingleFile','Host','InstallLocation','Startup','HostBridge')){. (Join-Path $root "src/$module.ps1")}
            Invoke-LanHostRequest -Action $action -Payload $payload
        }
    }
    $ui.SetupStarter={param($root,$result) Start-LanOnlineElevatedSetup -Root $root -ResultPath $result}
    $ui.SignInStarter={param($root,$result) Start-LanOnlineElevatedSignIn -Root $root -ResultPath $result}
    $f.Tag=$ui
    Set-LanModernOnlinePage $f $intro $note $help
    $ui.UpdateForm=${function:Update-LanOnlineForm}
    $f.Add_Disposed({
        $ui.Disposed=$true
        if($ui.Timer){$ui.Timer.Stop();$ui.Timer.Dispose()}
        if($ui.Job){Remove-Job $ui.Job -Force -ErrorAction SilentlyContinue;$ui.Job=$null}
        if($ui.SetupProcess){try{$ui.SetupProcess.Dispose()}catch{};$ui.SetupProcess=$null}
        $ui.SetupKey.Clear()
    }.GetNewClosure())
    if(-not $WireEvents){return $f}
    $start=${function:Start-LanOnlineUiOperation}; $complete=${function:Complete-LanOnlineUiOperation}
    $startSetup=${function:Start-LanOnlineSetupUiOperation};$startSignIn=${function:Start-LanOnlineSignInUiOperation};$completeSetup=${function:Complete-LanOnlineSetupUiOperation}
    $install.Add_Click({& $startSetup $ui}.GetNewClosure())
    $signIn.Add_Click({& $startSignIn $ui}.GetNewClosure())
    $console.Add_Click({Start-Process 'https://app.netbird.io/'}.GetNewClosure())
    $refresh.Add_Click({& $start $ui OnlineStatus @{}}.GetNewClosure())
    $enroll.Add_Click({if([string]::IsNullOrWhiteSpace($ui.SetupKey.Text)){$ui.Status.Text='กรุณาใส่รหัสลงทะเบียนของเครื่องนี้';return}; & $start $ui OnlineEnroll @{SetupKey=$ui.SetupKey.Text}}.GetNewClosure())
    $enable.Add_Click({$ids=@($ui.Peers.CheckedItems|ForEach-Object{[string]$_.Tag}); if($ids.Count -eq 0){$ui.Status.Text='เลือกเครื่องที่อนุญาตก่อน';return}; & $start $ui OnlineConfigure @{Enabled=$true;PeerIdentities=$ids}}.GetNewClosure())
    $disable.Add_Click({& $start $ui OnlineConfigure @{Enabled=$false;PeerIdentities=@()}}.GetNewClosure())
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=250; $ui.LastPoll=[DateTime]::MinValue
    $timer.Add_Tick({
        try{
            & $complete $ui
            & $completeSetup $ui
            $missing=($ui.LastStatus -and $ui.LastStatus.ConnectionState -eq 'MissingClient' -and
                -not [IO.File]::Exists((Join-Path $env:ProgramFiles 'NetBird\netbird.exe')))
            if(-not $missing -and -not $ui.Job -and -not $ui.SetupProcess -and ([DateTime]::UtcNow-$ui.LastPoll).TotalMilliseconds -ge 5000){$ui.LastPoll=[DateTime]::UtcNow;& $start $ui OnlineStatus @{}}
        }catch{$ui.Status.Text='ตรวจ Online ไม่สำเร็จ: '+$_.Exception.Message}
    }.GetNewClosure())
    $ui.Timer=$timer
    $f.Add_Shown({$ui.Timer.Start()}.GetNewClosure())
    return $f
}
