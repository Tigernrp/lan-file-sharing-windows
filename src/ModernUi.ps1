# Presentation only: existing controls and handlers are retained when moved into cards.
if (-not ('LanModernStack' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
public class LanModernTabs : TabControl {
    public LanModernTabs() { Appearance=TabAppearance.FlatButtons; ItemSize=new Size(0,1); SizeMode=TabSizeMode.Fixed; }
    public override Rectangle DisplayRectangle { get { return new Rectangle(0,0,ClientSize.Width,ClientSize.Height); } }
    protected override void WndProc(ref Message m) { if(m.Msg==0x1328) { m.Result=IntPtr.Zero; return; } base.WndProc(ref m); }
}
public class LanModernStack : Panel {
    private bool arranging;
    private static readonly System.Reflection.MethodInfo getState=typeof(Control).GetMethod("GetState",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic);
    public static bool IsShown(Control c) { return (bool)getState.Invoke(c,new object[]{2}); }
    public LanModernStack() { DoubleBuffered=true; Margin=Padding.Empty; }
    protected override void OnLayout(LayoutEventArgs e) {
        if(arranging) return;
        arranging=true;
        try {
            int y=Padding.Top;
            foreach(Control c in Controls) {
                // Visible includes ancestors: do not remove a whole page while its tab is hidden.
                bool shown=IsShown(c);
                if(!shown) continue;
                c.Width=Math.Max(1,ClientSize.Width-Padding.Horizontal-c.Margin.Horizontal);
                c.Location=new Point(Padding.Left+c.Margin.Left,y+c.Margin.Top);
                c.PerformLayout(); y+=c.Height+c.Margin.Vertical;
            }
            Height=y+Padding.Bottom;
        } finally { arranging=false; }
        base.OnLayout(e);
    }
    protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); PerformLayout(); if(Parent!=null) Parent.PerformLayout(); }
}
public class LanModernField : LanModernStack {
    public bool FillRow;
    public int FieldWidth=280;
}
public class LanModernRow : FlowLayoutPanel {
    private bool arranging;
    public Control FlexibleControl;
    public LanModernRow() { WrapContents=true; DoubleBuffered=true; Margin=new Padding(0,0,0,8); }
    protected override void OnLayout(LayoutEventArgs e) {
        if(arranging) return;
        arranging=true; try {
            int available=Math.Max(1,ClientSize.Width-Padding.Horizontal);
            foreach(Control c in Controls) { var f=c as LanModernField; if(f!=null) f.Width=Math.Max(1,Math.Min(available-c.Margin.Horizontal,f.FillRow?available-c.Margin.Horizontal:f.FieldWidth)); c.PerformLayout(); }
            if(FlexibleControl!=null) { int rest=available; foreach(Control c in Controls) if(c!=FlexibleControl && LanModernStack.IsShown(c)) rest-=c.Width+c.Margin.Horizontal; FlexibleControl.Width=Math.Max(1,rest-FlexibleControl.Margin.Horizontal); }
            base.OnLayout(e);
            int bottom=Padding.Top;
            foreach(Control c in Controls) if(LanModernStack.IsShown(c)) bottom=Math.Max(bottom,c.Bottom+c.Margin.Bottom);
            Height=bottom+Padding.Bottom;
        } finally { arranging=false; }
    }
}
'@
}

function Set-LanModernControl {
    param($Control,[switch]$Primary)
    $Control.Anchor='Top,Left'; $Control.Dock='None'; $Control.Margin=[Windows.Forms.Padding]::new(0,0,10,0)
    $Control.ForeColor=[Drawing.ColorTranslator]::FromHtml('#283244')
    if($Control -is [Windows.Forms.Button]){
        $Control.FlatStyle='Flat'; $Control.FlatAppearance.BorderSize=1
        $Control.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#DCE1E8')
        $Control.BackColor=[Drawing.Color]::White; $Control.Height=36
        $Control.Cursor=[Windows.Forms.Cursors]::Hand
        if($Primary){$Control.BackColor=[Drawing.ColorTranslator]::FromHtml('#EA580C');$Control.ForeColor=[Drawing.Color]::White;$Control.FlatAppearance.BorderSize=0}
    }elseif($Control -is [Windows.Forms.ListView]){
        $Control.BorderStyle='None'; $Control.BackColor=[Drawing.Color]::White
        $Control.GridLines=$false; $Control.HideSelection=$false
    }elseif($Control -is [Windows.Forms.Label]){
        $Control.AutoSize=$false; $Control.Height=[Math]::Max(24,$Control.Height)
    }elseif($Control -is [Windows.Forms.CheckBox]){
        $Control.AutoSize=$true; $Control.Padding=[Windows.Forms.Padding]::new(0,5,0,5)
    }
}

function New-LanModernRow {
    param($Parent,$Controls,[switch]$PrimaryFirst)
    $row=New-Object LanModernRow
    $row.TabIndex=$Parent.Controls.Count
    $first=$true
    foreach($control in $Controls){
        if(-not $control){continue}
        Set-LanModernControl $control -Primary:($PrimaryFirst -and $first)
        $control.TabIndex=$row.Controls.Count
        $row.Controls.Add($control); $first=$false
    }
    $Parent.Controls.Add($row)
    return $row
}

function Add-LanModernField {
    param($Row,[string]$Caption,$Control,$Extra=@(),$Label,[switch]$Full,[int]$Width=280)
    $field=New-Object LanModernField; $field.FillRow=[bool]$Full; $field.FieldWidth=$Width
    $field.TabIndex=$Row.Controls.Count
    $field.Margin=[Windows.Forms.Padding]::new(0,0,16,8); $field.Width=$Width
    if(-not $Label){$Label=New-Object Windows.Forms.Label;$Label.Text=$Caption}
    $Label.AutoSize=$false; $Label.Height=25; $Label.Margin=[Windows.Forms.Padding]::new(0,0,0,4)
    $Label.ForeColor=[Drawing.ColorTranslator]::FromHtml('#64748B')
    $Control.AccessibleName=$Label.Text
    $Label.Add_TextChanged({$Control.AccessibleName=$Label.Text}.GetNewClosure())
    $field.Controls.Add($Label)
    $input=New-LanModernRow $field (@($Control)+@($Extra))
    $input.WrapContents=$false; $input.FlexibleControl=$Control; $input.Margin=[Windows.Forms.Padding]::Empty
    $Row.Controls.Add($field)
    $field.Visible=[LanModernStack]::IsShown($Control)
    $Control.Add_VisibleChanged({$field.Visible=[LanModernStack]::IsShown($Control)}.GetNewClosure())
}

function New-LanModernCard {
    param($Ui,[string]$Title,[switch]$Collapsible,[switch]$Collapsed,[string]$Key)
    $card=New-Object LanModernStack; $card.BackColor=[Drawing.Color]::White
    $card.TabIndex=$Ui.LayoutRoot.Controls.Count
    $card.Padding=[Windows.Forms.Padding]::new(18,14,18,14); $card.Margin=[Windows.Forms.Padding]::new(0,0,0,14)
    if($Collapsible){
        $heading=New-Object Windows.Forms.Button
        Set-LanModernControl $heading
        $heading.FlatAppearance.BorderSize=0; $heading.TextAlign='MiddleLeft'; $heading.Height=30
        $heading.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)
    }else{
        $heading=New-Object Windows.Forms.Label; $heading.Height=30
        $heading.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold)
    }
    $heading.ForeColor=[Drawing.ColorTranslator]::FromHtml('#172033'); $heading.Margin=[Windows.Forms.Padding]::new(0,0,0,8)
    $heading.Text=$Title; $card.Controls.Add($heading)
    $body=New-Object LanModernStack; $card.Controls.Add($body)
    $Ui.LayoutRoot.Controls.Add($card); $Ui.Cards+=@($card)
    if($Collapsible){
        $body.Visible=-not $Collapsed; $heading.Text=$(if($Collapsed){'+  '}else{'−  '})+$Title
        $heading.Add_Click({$body.Visible=-not $body.Visible;$heading.Text=$(if($body.Visible){'−  '}else{'+  '})+$Title;if($body.Visible){$Ui.ScrollHost.ScrollControlIntoView($body)}}.GetNewClosure())
        $Ui[$Key+'Toggle']=$heading; $Ui[$Key+'Body']=$body
    }
    return $body
}

function Initialize-LanModernPage {
    param($Form)
    $ui=$Form.Tag
    # Detach rather than dispose: controls referenced by existing closures are reused below.
    $ui.DetachedControls=@($Form.Controls)
    $Form.Controls.Clear(); $Form.MinimumSize=[Drawing.Size]::Empty; $Form.AutoScroll=$false
    $Form.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F5F9')
    $Form.Font=New-Object Drawing.Font('Segoe UI',10)
    $scroll=New-Object Windows.Forms.Panel; $scroll.Dock='Fill'; $scroll.AutoScroll=$true
    $scroll.Padding=[Windows.Forms.Padding]::new(20,8,20,16); $Form.Controls.Add($scroll)
    $stack=New-Object LanModernStack; $stack.Dock='Top'; $scroll.Controls.Add($stack)
    $ui.ScrollHost=$scroll; $ui.LayoutRoot=$stack; $ui.Cards=@()
}

function Complete-LanModernPage {
    param($Ui)
    foreach($control in $Ui.DetachedControls){if(-not $control.Parent){$control.Dispose()}}
    $Ui.Remove('DetachedControls')
}

function Set-LanModernListColumns {
    param($List,[double[]]$Weights)
    $resize={
        $available=[Math]::Max(0,$List.ClientSize.Width-2); $used=0
        for($index=0;$index -lt $Weights.Count;$index++){
            $width=if($index -eq $Weights.Count-1){$available-$used}else{[int][Math]::Floor($available*$Weights[$index])}
            $List.Columns[$index].Width=[Math]::Max(0,$width);$used+=$width
        }
    }.GetNewClosure()
    $List.Add_SizeChanged($resize); & $resize
}

function Add-LanModernStatus {
    param($Ui)
    $Ui.Status.Padding=[Windows.Forms.Padding]::new(12,10,12,10)
    $Ui.Status.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF3E8')
    $Ui.Status.ForeColor=[Drawing.ColorTranslator]::FromHtml('#9A3412')
    $label=$Ui.Status; $label.UseMnemonic=$false
    $resize={
        $width=[Math]::Max(80,$label.ClientSize.Width-$label.Padding.Horizontal)
        $measured=[Windows.Forms.TextRenderer]::MeasureText($label.Text,$label.Font,[Drawing.Size]::new($width,0),[Windows.Forms.TextFormatFlags]::WordBreak)
        $label.Height=[Math]::Max(52,$measured.Height+$label.Padding.Vertical+4)
    }.GetNewClosure()
    $label.Add_TextChanged($resize);$label.Add_SizeChanged($resize)
    $Ui.Status.Margin=[Windows.Forms.Padding]::new(0,0,0,14)
    $Ui.LayoutRoot.Controls.Add($Ui.Status)
    & $resize
}

function Set-LanModernClientPage {
    param($Form)
    Initialize-LanModernPage $Form; $u=$Form.Tag
    $c=New-LanModernCard $u 'วางข้อมูลเข้าใช้ครั้งเดียว'
    $u.LoginBlockInput.Height=88
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'วางข้อความทั้งหมดที่คัดลอกจากเครื่องผู้แชร์' $u.LoginBlockInput -Full
    $u.LoginBlockHint.Margin=[Windows.Forms.Padding]::new(0,0,0,4); $c.Controls.Add($u.LoginBlockHint)
    $c=New-LanModernCard $u 'เชื่อมต่อกับเครื่องผู้แชร์'
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'ที่อยู่ไฟล์  •  \\ชื่อเครื่อง\ชื่อแชร์' $u.Unc @($u.UncExample) -Full
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'วิธีเข้าใช้' $u.Auth; Add-LanModernField $r 'ตัวอักษรไดรฟ์' $u.Letter -Width 200
    $r=New-LanModernRow $c @(); Add-LanModernField $r '' $u.WindowsAccount -Label $u.WindowsAccountLabel -Width 330
    Add-LanModernField $r '' $u.PasswordInput @($u.ShowPassword) -Label $u.PasswordLabel -Width 330
    $u.AccountHint.Height=48; $u.AccountHint.Margin=[Windows.Forms.Padding]::new(0,0,0,8); $c.Controls.Add($u.AccountHint)
    $null=New-LanModernRow $c @($u.Reconnect)
    $u.Map.Text='เชื่อมต่อไดรฟ์'; $u.Open.Text='เปิดโฟลเดอร์ UNC'
    $u.Open.Width=160; $u.Map.Width=170
    $null=New-LanModernRow $c @($u.Map,$u.Open) -PrimaryFirst
    Add-LanModernStatus $u
    $c=New-LanModernCard $u 'การเชื่อมต่อที่บันทึกไว้'
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'เลือก UNC หรือไดรฟ์เพื่อเปิดหรือจัดการ' $u.SavedMaps -Full
    $null=New-LanModernRow $c @($u.OpenDrive,$u.Unmap)
    $c=New-LanModernCard $u 'เครื่องมือและการตั้งค่าขั้นสูง' -Collapsible -Collapsed -Key Advanced
    $null=New-LanModernRow $c @($u.AutoReconnect)
    $null=New-LanModernRow $c @($u.Tools,$u.WatchToggle,$u.GuestConfig,$u.RestoreGuest)
    $c=New-LanModernCard $u 'บันทึกการทำงาน' -Collapsible -Key Log
    $u.Log.Height=150; Set-LanModernControl $u.Log; $c.Controls.Add($u.Log)
    Set-LanModernListColumns $u.Log @(0.12,0.88)
    Complete-LanModernPage $u
}

function Set-LanModernHostPage {
    param($Form)
    Initialize-LanModernPage $Form; $u=$Form.Tag
    $c=New-LanModernCard $u 'เลือกข้อมูลที่ต้องการแชร์'
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'ชนิดที่แชร์' $u.Kind -Width 180
    Add-LanModernField $r 'ชื่อ Share' $u.Name -Width 300; Add-LanModernField $r 'สิทธิ์' $u.Mode -Width 180
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'Drive / Folder / File' $u.Path @($u.Browse) -Full
    $c=New-LanModernCard $u 'บัญชีและสิทธิ์เข้าใช้'
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'วิธีเข้าใช้' $u.Auth -Width 250
    Add-LanModernField $r '' $u.Principals -Label $u.PrincipalsLabel -Width 470
    $r=New-LanModernRow $c @(); Add-LanModernField $r '' $u.PasswordMethod -Label $u.PasswordLabel -Width 215
    Add-LanModernField $r 'รหัสผ่านเข้าใช้' $u.PasswordInput @($u.RegeneratePassword,$u.ShowPassword) -Width 415
    $r=New-LanModernRow $c @(); Add-LanModernField $r '' $u.AccountName @($u.ReuseAccount) -Label $u.AccountNameLabel -Width 415
    $null=New-LanModernRow $c @($u.AutoStart)
    $u.Create.Width=170; $null=New-LanModernRow $u.LayoutRoot @($u.Create) -PrimaryFirst
    Add-LanModernStatus $u
    $c=New-LanModernCard $u 'รายการที่แชร์จากเครื่องนี้'
    $u.ShareList.Height=190; Set-LanModernControl $u.ShareList; $c.Controls.Add($u.ShareList)
    $u.CopyLogin.Width=180; $u.CopyOnline.Width=210
    $null=New-LanModernRow $c @($u.Stop,$u.Refresh,$u.CopyUnc,$u.CopyLogin,$u.CopyOnline)
    $c=New-LanModernCard $u 'เครื่องมือและการตั้งค่าขั้นสูง' -Collapsible -Collapsed -Key Advanced
    $null=New-LanModernRow $c @($u.CheckShare)
    $note=New-Object Windows.Forms.Label;$note.Text='ตรวจแชร์: ตรวจ SMB, บัญชี และสิทธิ์ที่โปรแกรมตั้ง โดยไม่แก้ค่า';$note.Height=48;$c.Controls.Add($note)
    $null=New-LanModernRow $c @($u.GuestCheck,$u.GuestConfig,$u.GuestRestore)
    $note=New-Object Windows.Forms.Label;$note.Text='Guest: ตรวจอย่างเดียว / เปิดเข้าใช้ไม่ใส่รหัส / คืนค่าที่โปรแกรมเคยเปลี่ยน';$note.Height=48;$c.Controls.Add($note)
    $null=New-LanModernRow $c @($u.BlankPasswordEnable,$u.BlankPasswordRestore)
    $c=New-LanModernCard $u 'บันทึกการทำงาน' -Collapsible -Key Log
    $u.Progress.Height=36; $c.Controls.Add($u.Progress)
    $u.Log.Height=150; Set-LanModernControl $u.Log; $c.Controls.Add($u.Log)
    Set-LanModernListColumns $u.Log @(0.12,0.88)
    Complete-LanModernPage $u
}

function Set-LanModernOnlinePage {
    param($Form,$Intro,$Note,$Help)
    Initialize-LanModernPage $Form; $u=$Form.Tag
    $c=New-LanModernCard $u 'เครือข่ายส่วนตัวผ่าน NetBird'
    $Intro.Height=40; $c.Controls.Add($Intro)
    $null=New-LanModernRow $c @($u.Install,$u.SignIn,$u.Refresh,$u.Console) -PrimaryFirst
    Add-LanModernStatus $u
    $c=New-LanModernCard $u 'เครื่องที่อนุญาตให้เข้าใช้'
    $Note.Height=48; $c.Controls.Add($Note)
    $empty=New-Object Windows.Forms.Label
    $empty.Text='ยังไม่มีเครื่องอื่นในเครือข่าย • ให้เครื่องครูลงทะเบียน NetBird ในเครือข่ายเดียวกันก่อน'
    $empty.ForeColor=[Drawing.ColorTranslator]::FromHtml('#64748B');$empty.Height=44;$c.Controls.Add($empty);$u.EmptyPeerHint=$empty
    Set-LanModernControl $u.Peers; $u.Peers.Height=190; $c.Controls.Add($u.Peers)
    Set-LanModernListColumns $u.Peers @(0.32,0.22,0.18,0.12,0.16)
    $null=New-LanModernRow $c @($u.Enable,$u.Disable) -PrimaryFirst
    $c=New-LanModernCard $u 'ลงทะเบียนเครื่องครั้งแรก' -Collapsible -Collapsed -Key Enrollment
    $r=New-LanModernRow $c @(); Add-LanModernField $r 'Setup Key ของเครื่องนี้' $u.SetupKey @($u.Enroll) -Full
    $c=New-LanModernCard $u 'วิธีเริ่มใช้งาน'
    $Help.Height=80; $Help.ForeColor=[Drawing.ColorTranslator]::FromHtml('#64748B'); $c.Controls.Add($Help)
    Complete-LanModernPage $u
}

function Set-LanModernShell {
    param($Form,$ShowAfterLabel)
    $u=$Form.Tag; $tabs=$u.Tabs
    $Form.SuspendLayout()
    $area=[Windows.Forms.Screen]::FromControl($Form).WorkingArea
    $Form.MinimumSize=[Drawing.Size]::new(900,700)
    $Form.Size=[Drawing.Size]::new([Math]::Max(900,[Math]::Min(1200,$area.Width-32)),[Math]::Max(700,[Math]::Min(850,$area.Height-32)))
    $Form.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F5F9')
    $side=New-Object Windows.Forms.Panel; $side.BackColor=[Drawing.Color]::White; $Form.Controls.Add($side)
    $brand=Add-LanUiLabel $side 'LAN SHARE' 20 70 160; $brand.Font=New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold); $brand.Height=38
    $by=Add-LanUiLabel $side 'TIGER TECH' 22 110 155; $by.ForeColor=[Drawing.ColorTranslator]::FromHtml('#EA580C'); $by.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)
    $logo=New-Object Windows.Forms.PictureBox; $logo.SetBounds(20,20,42,42); $logo.SizeMode='Zoom'
    $logoPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'icon\Tiger_Tech_Share_File.png'
    if([IO.File]::Exists($logoPath)){$original=[Drawing.Image]::FromFile($logoPath);try{$logo.Image=$original.Clone()}finally{$original.Dispose()};$Form.Add_Disposed({if($logo.Image){$logo.Image.Dispose()}}.GetNewClosure())}
    $side.Controls.Add($logo)
    $title=Add-LanUiLabel $Form '' 220 20 700; $title.Font=New-Object Drawing.Font('Segoe UI',21,[Drawing.FontStyle]::Bold); $title.Height=44
    $subtitle=Add-LanUiLabel $Form '' 222 67 800; $subtitle.ForeColor=[Drawing.ColorTranslator]::FromHtml('#64748B')
    $names=@('ใช้ไฟล์','แชร์ไฟล์','Online'); $descriptions=@('เชื่อมต่อและจัดการไดรฟ์ที่แชร์','เลือกข้อมูลและกำหนดสิทธิ์เข้าใช้','แชร์กับครูที่อยู่คนละสถานที่')
    $nav=@()
    foreach($index in 0..2){
        $button=Add-LanUiButton $side ('0'+($index+1)+'   '+$names[$index]) 12 (168+$index*58) 166
        Set-LanModernControl $button; $button.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold); $button.Height=46; $button.TextAlign='MiddleLeft'; $button.Padding=[Windows.Forms.Padding]::new(12,0,0,0); $button.FlatAppearance.BorderSize=0
        $button.AccessibleName=$names[$index]; $button.TabIndex=$index
        $button.Add_Click({$tabs.SelectedIndex=$index}.GetNewClosure()); $nav+=@($button)
    }
    $footer=Add-LanUiLabel $side ($env:COMPUTERNAME+"`r`n"+'LAN File Sharing'+(Get-LanVersionSuffix)) 20 600 160; $footer.Height=55; $footer.ForeColor=[Drawing.ColorTranslator]::FromHtml('#94A3B8'); $footer.Font=New-Object Drawing.Font('Segoe UI',9)
    $startup=New-Object Windows.Forms.Panel; $startup.BackColor=[Drawing.Color]::White; $Form.Controls.Add($startup)
    $toggle=Add-LanUiButton $startup '+  การเปิดโปรแกรมอัตโนมัติ' 18 5 340
    Set-LanModernControl $toggle; $toggle.FlatAppearance.BorderSize=0; $toggle.TextAlign='MiddleLeft'
    $body=New-Object LanModernStack; $body.SetBounds(18,48,900,200); $body.Visible=$false; $startup.Controls.Add($body)
    $null=New-LanModernRow $body @($u.StartWithHost,$u.StartMinimized)
    $ShowAfterLabel.Width=230; $u.ShowAfterNote.Width=225
    $null=New-LanModernRow $body @($ShowAfterLabel,$u.ShowAfter,$u.ShowAfterNote)
    $u.StartupStatus.Height=52; $body.Controls.Add($u.StartupStatus)
    $null=New-LanModernRow $body @($u.StartupButton)
    $u.StartupHelp.Height=44; $body.Controls.Add($u.StartupHelp)
    $u.Navigation=$nav; $u.PageTitle=$title; $u.Sidebar=$side; $u.StartupPanel=$startup; $u.StartupToggle=$toggle; $u.StartupBody=$body
    $layout={
        $w=$Form.ClientSize.Width; $h=$Form.ClientSize.Height; $x=196; $content=$w-$x-12
        $side.SetBounds(0,0,184,$h); $footer.Top=$h-76
        $title.Width=$content-24; $subtitle.Width=$content-24
        $height=if($body.Visible){[Math]::Min(300,$body.PreferredSize.Height+60)}else{48}
        $startup.SetBounds($x,$h-$height,$content,$height); $body.Width=$content-36
        $tabs.SetBounds($x,100,$content,[Math]::Max(150,$h-100-$height-12))
    }.GetNewClosure()
    $select={
        $i=$tabs.SelectedIndex; if($i -lt 0){return}; $title.Text=$names[$i];$subtitle.Text=$descriptions[$i]
        foreach($j in 0..2){$nav[$j].BackColor=if($i -eq $j){[Drawing.ColorTranslator]::FromHtml('#FFF0E4')}else{[Drawing.Color]::White};$nav[$j].ForeColor=if($i -eq $j){[Drawing.ColorTranslator]::FromHtml('#C2410C')}else{[Drawing.ColorTranslator]::FromHtml('#64748B')}}
        $tabs.TabPages[$i].Controls[0].Show()
    }.GetNewClosure()
    $toggle.Add_Click({$body.Visible=-not $body.Visible;$toggle.Text=$(if($body.Visible){'−  '}else{'+  '})+'การเปิดโปรแกรมอัตโนมัติ';& $layout}.GetNewClosure())
    $Form.Add_Resize($layout); $tabs.Add_SelectedIndexChanged($select)
    $Form.Add_Shown({& $select; & $layout}.GetNewClosure())
    if($tabs.SelectedIndex -lt 0){$tabs.SelectedIndex=0}
    $Form.ResumeLayout(); & $select; & $layout
}
