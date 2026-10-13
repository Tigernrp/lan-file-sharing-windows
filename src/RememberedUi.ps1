function Get-LanUiPreferencePath {
    param($Ui)
    if($Ui.PreferencePath){return [string]$Ui.PreferencePath}
    if($Ui.Adapter -and $Ui.Adapter.StatePath){return Join-Path (Split-Path -Parent ([string]$Ui.Adapter.StatePath)) 'ui.json'}
    if($Ui.StatePath -and [string]$Ui.StatePath -ne (Join-Path $env:ProgramData 'LanFileSharing\state.json')){return Join-Path (Split-Path -Parent ([string]$Ui.StatePath)) 'ui.json'}
    return Join-Path $env:LOCALAPPDATA 'LanFileSharing\ui.json'
}

function Get-LanUiPreferences {
    param($Ui)
    $path=Get-LanUiPreferencePath $Ui
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{LastHostShareId='';LastClientConnectionKey=''}}
    try{return [IO.File]::ReadAllText($path)|ConvertFrom-Json -ErrorAction Stop}
    catch{throw "อ่านค่าหน้าจอที่บันทึกไว้ไม่ได้: $($_.Exception.Message)"}
}

function Set-LanUiPreference {
    param($Ui,[ValidateSet('LastHostShareId','LastClientConnectionKey')][string]$Name,[string]$Value)
    $current=Get-LanUiPreferences $Ui
    $current|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    $path=Get-LanUiPreferencePath $Ui;$dir=Split-Path -Parent $path
    [IO.Directory]::CreateDirectory($dir)|Out-Null
    $temp=Join-Path $dir ('.ui-'+[guid]::NewGuid().ToString('N')+'.tmp');$backup=$temp+'.bak'
    try{
        [IO.File]::WriteAllText($temp,($current|ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,$backup);[IO.File]::Delete($backup)}else{[IO.File]::Move($temp,$path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Restore-LanHostFields {
    param($Ui,$Entry)
    if(-not $Entry){return}
    $Ui.Kind.SelectedItem=[string]$Entry.Kind;$Ui.Path.Text=[string]$Entry.SourcePath
    $Ui.Name.Text=[string]$Entry.Name;$Ui.Mode.SelectedItem=[string]$Entry.Mode
    $Ui.Auth.SelectedItem=ConvertTo-LanAuthLabel $Entry.AuthMode
    $Ui.AutoStart.Checked=[bool]$Entry.AutoStart
    $principals=@()
    foreach($sid in @($Entry.AllowedSids)){
        if(-not $sid -or $sid -eq 'S-1-5-11' -or $Entry.AuthMode -ne 'WindowsCurrent'){continue}
        try{$principals+=([Security.Principal.SecurityIdentifier]::new([string]$sid)).Translate([Security.Principal.NTAccount]).Value}
        catch{throw "เรียกคืนบัญชีที่อนุญาตไม่ได้: $sid"}
    }
    $Ui.Principals.Text=$principals -join ','
    if($Entry.AuthMode -eq 'Protected' -and $Entry.CredentialInfo){
        $Ui.AccountName.Text=[string]$Entry.CredentialInfo.UserName
        $Ui.PasswordMethod.SelectedItem='กำหนดเอง'
        $Ui.PasswordInput.Text=Unprotect-LanSecret ([string]$Entry.CredentialInfo.PasswordCipher)
        $Ui.PasswordInput.UseSystemPasswordChar=$true;$Ui.ShowPassword.Text='แสดง'
    }
    $Ui.CurrentShareId=[string]$Entry.Id
    Set-LanUiPreference $Ui LastHostShareId ([string]$Entry.Id)
}

function Restore-LanHostSelection {
    param($Ui,[switch]$Initial)
    if($Ui.RefreshingShares){return}
    $selected=@($Ui.ShareList.SelectedItems)
    $entries=@((Read-LanState -Path $Ui.StatePath).Shares)
    $entry=$null
    if($selected.Count -gt 0){$entry=@($entries|Where-Object Id -eq $selected[0].Tag)|Select-Object -First 1}
    elseif($Initial){
        $id=[string](Get-LanUiPreferences $Ui).LastHostShareId
        $entry=@($entries|Where-Object Id -eq $id)|Select-Object -First 1
        if(-not $entry){$entry=$entries|Select-Object -Last 1}
    }
    if(-not $entry){return}
    Restore-LanHostFields $Ui $entry
    foreach($row in $Ui.ShareList.Items){if($row.Tag -eq $entry.Id){$row.Selected=$true;$row.Focused=$true;break}}
}

function Restore-LanClientFields {
    param($Ui,$Entry)
    if(-not $Entry){return}
    $Ui.CurrentMap=$Entry
    $Ui.RestoringClientFields=$true
    try{
        $Ui.CredentialWasRemembered=$false;$Ui.RememberedCredentialHost=''
        $Ui.Unc.Text=if($Entry.Path){[string]$Entry.Path}else{[string]$Entry.Unc}
        $Ui.Unc.ForeColor=[Drawing.Color]::Black
        $Ui.Letter.SelectedItem=if($Entry.Letter){[string]$Entry.Letter}else{'Auto'}
        $Ui.Auth.SelectedItem=ConvertTo-LanAuthLabel ([string]$Entry.AuthMode)
        Update-LanClientCredentialFields $Ui
        $Ui.WindowsAccount.Text=[string]$Entry.WindowsAccount
        $Ui.PasswordInput.Clear();$Ui.PasswordInput.UseSystemPasswordChar=$true;$Ui.ShowPassword.Text='แสดง'
        if($Entry.AuthMode -eq 'Protected'){
            try{
                $runtime=@{};foreach($key in $Ui.Adapter.Keys){$runtime[$key]=$Ui.Adapter[$key]}
                $runtime.VerifiedOnlineTarget=$null
                if($Entry.Transport -eq 'NetBird'){
                    $guard=Test-LanClientOnlineTarget -Entry $Entry -Adapter $runtime
                    if(-not $guard.Ready){throw $guard.Reason}
                    $runtime.VerifiedOnlineTarget=$Entry
                }
                $hostName=if($Entry.HostName){[string]$Entry.HostName}else{([string]$Entry.Unc).TrimStart('\').Split('\')[0]}
                $credential=Get-LanRememberedCredential -HostName $hostName -Adapter $runtime
                if($credential){
                    $Ui.WindowsAccount.Text=$credential.UserName;$Ui.PasswordInput.Text=$credential.Password
                    $Ui.CredentialWasRemembered=$true;$Ui.RememberedCredentialHost=$hostName
                }
            }catch{
                # A pending/replaced NetBird peer must not release its remembered secret into the form.
                $Ui.Status.Text='จำรายการไว้แล้ว รอยืนยันตัวตนเครื่องปลายทาง: '+$_.Exception.Message
            }
        }
        $Ui.OpenDrive.Text=if($Entry.Letter){'เปิดไดรฟ์'}else{'เปิด UNC ที่จำไว้'}
        $Ui.Unmap.Text=if($Entry.Letter){'ยกเลิก Map'}else{'ลืม UNC นี้'}
        $Ui.Unmap.Width=150;$Ui.OpenDrive.Width=170
        $Ui.ClientFieldsRestored=$true
        $target=if(-not $Entry.Letter -and $Entry.Path){[string]$Entry.Path}else{[string]$Entry.Unc}
        Set-LanUiPreference $Ui LastClientConnectionKey ([string]$Entry.Letter+'|'+$target)
    }finally{$Ui.RestoringClientFields=$false}
}

function Enable-LanClientAutomaticStartup {
    param($Ui)
    if(-not $Ui.Reconnect.Checked){return}
    $adapter=if($Ui.StartupAdapter){$Ui.StartupAdapter}else{New-LanUserStartupAdapter}
    $settings=Get-LanUserStartupSettings $adapter
    $launcher=Join-Path $Ui.Root 'LanFileSharing.exe'
    if(-not [IO.File]::Exists($launcher)){return 'ยังลงทะเบียนเปิดอัตโนมัติไม่ได้: ไม่พบตัวโปรแกรมที่ติดตั้ง'}
    try{
        Set-LanUserStartupSettings -StartWithHost $true -StartMinimized $settings.StartMinimized -LauncherPath $launcher -ShowAfterSeconds $settings.ShowAfterSeconds -AutoReconnect $settings.AutoReconnect -Adapter $adapter|Out-Null
        $Ui.AutoReconnect.Checked=$settings.AutoReconnect
        if($Ui.OwnerStartupUi){$Ui.OwnerStartupUi.StartWithHost.Checked=$true}
    }catch{return 'บันทึกการเชื่อมต่ออัตโนมัติไม่สำเร็จ: '+$_.Exception.Message}
}

function Complete-LanClientRememberedConnection {
    param($Ui,$Entry)
    if(-not $Entry){return}
    $warnings=New-Object Collections.Generic.List[string]
    if($Entry.PersistenceWarning){$warnings.Add([string]$Entry.PersistenceWarning)}
    try{
            $target=if(-not $Entry.Letter -and $Entry.Path){[string]$Entry.Path}else{[string]$Entry.Unc}
            Set-LanUiPreference $Ui LastClientConnectionKey ([string]$Entry.Letter+'|'+$target)
    }catch{$warnings.Add($_.Exception.Message)}
    try{$warning=[string](Enable-LanClientAutomaticStartup $Ui);if($warning){$warnings.Add($warning)}}catch{$warnings.Add($_.Exception.Message)}
    if($warnings.Count -gt 0){$Ui.Status.Text+=' — เชื่อมต่อแล้ว แต่จำค่าไม่ครบ: '+($warnings -join ' ')}
    elseif($Ui.Reconnect.Checked -and $Ui.AutoReconnect.Checked){$Ui.Status.Text+=' — จำค่าแล้ว ครั้งต่อไปเชื่อมต่อให้อัตโนมัติ'}
    else{$Ui.Status.Text+=' — จำค่าแล้ว (ปิดการเชื่อมต่อเมื่อเข้าสู่ Windows ไว้)'}
}
