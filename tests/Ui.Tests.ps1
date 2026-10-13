. "$PSScriptRoot/../src/Ui.ps1"

# Load every module the way the application does, instead of a hand-kept list: a missing module
# only showed up when a form was built with events wired, which made the failure look unrelated.
foreach ($module in @('Selection','State','Progress','Auth','SingleFile','ClientMap','Host',
                       'InstallLocation','Startup','HostBridge','UserStartup')) {
    . "$PSScriptRoot/../src/$module.ps1"
}

$script:uiNativeClientFactory=${function:New-LanClientAdapter}
Describe 'Windows Forms modes and controls' {
    BeforeEach {
        $script:uiTestStatePath=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'-host.json')
        Mock Get-LanHostStatePath {$script:uiTestStatePath}
        Mock Get-LanUiPreferencePath {Join-Path $TestDrive 'ui-preferences.json'}
        $script:uiTestClient=& $script:uiNativeClientFactory
        $script:uiTestClient.StatePath=Join-Path $TestDrive 'client-mappings.json'
        $script:uiTestClient.CredentialPath=Join-Path $TestDrive 'client-credentials.json'
        Mock New-LanClientAdapter {$script:uiTestClient}
    }
    It 'explains the empty log pane instead of showing nothing' {
        # A freshly installed machine has no progress file yet, and an empty box looks broken.
        # The pane is refreshed directly here: a WinForms timer only ticks inside the running
        # application message loop, so a test cannot wait for the timer itself.
        $script:progressDir = Join-Path $TestDrive 'progress-empty'
        New-Item -ItemType Directory -Path $script:progressDir -Force | Out-Null
        $env:LanProgressDirectory = $script:progressDir
        try {
            Clear-LanProgress
            $form = New-LanHostForm -WireEvents:$false
            try {
                $ui = $form.Tag
                Update-LanHostLogPane -State $ui
                $ui.Log.Items.Count | Should Be 1
                $ui.Log.Items[0].SubItems[1].Text | Should Match 'ยังไม่มีบันทึก'
                $ui.Progress.Text | Should Be 'พร้อมทำงาน'

                # Once a real log exists the hint is replaced by the actual steps.
                Start-LanProgress -Message 'เริ่มทดสอบ'
                Write-LanProgress -Message 'ขั้นตอนจริง'
                Update-LanHostLogPane -State $ui
                $ui.Log.Items.Count | Should BeGreaterThan 1
                $ui.Log.Items[1].SubItems[1].Text | Should Be 'ขั้นตอนจริง'
                $ui.Progress.Text | Should Match 'ขั้นตอนจริง'
            } finally { $form.Dispose() }
        } finally {
            $env:LanProgressDirectory = $null
            Clear-LanProgress
        }
    }
    It 'survives a clipboard locked by another program' {
        # "Access denied" from SetText is another program holding the clipboard, not the user's
        # mistake. It must be retried, and then reported with the text so it can still be selected by
        # hand instead of leaving a dead button.
        $real = 'BU'
        $state = Join-Path $TestDrive 'state.json'
        $cipher = Protect-LanSecret -Text 'Pw12345!'
        $record = [pscustomobject]@{ Shares = @([pscustomobject]@{
            Id='id-1'; Name=$real; AuthMode='Protected'; Status='Running'
            NetworkProfile=[pscustomobject]@{Name='LAN';InterfaceAlias='Wi-Fi'}
            CredentialInfo=[pscustomobject]@{UserName='LFS_abc';PasswordCipher=$cipher} }) }
        $newUi = {
            $ui = @{ ShareList = New-Object Windows.Forms.ListView; Status = New-Object Windows.Forms.Label }
            $row = New-Object Windows.Forms.ListViewItem($real)
            foreach ($v in @('Folder','C:\x','Modify','Protected Password','True','Running',"\\HOST\$real")) { [void]$row.SubItems.Add([string]$v) }
            [void]$ui.ShareList.Items.Add($row); $row.Selected = $true
            return $ui
        }
        $read = { param($p) $record }

        # Retried until it succeeds.
        $script:tries = 0
        $ui = & $newUi
        Invoke-LanCopyLogin -Ui $ui -StatePath $state -ReadState $read -SetClipboardText {
            param($t); $script:tries++
            if ($script:tries -lt 3) { throw 'Access denied.' }
        }
        $script:tries | Should Be 3
        $ui.Status.Text | Should Match 'BU'

        # Never succeeds: the text is shown instead.
        $ui2 = & $newUi
        Invoke-LanCopyLogin -Ui $ui2 -StatePath $state -ReadState $read -SetClipboardText { param($t) throw 'Access denied.' }
        $ui2.Status.Text | Should Match 'clipboard'
        $ui2.Status.Text | Should Match 'LFS_abc'
    }
    It 'hands over the account and password even while the share waits for its network' {
        # The account and password exist from the moment the share is created, so they must be
        # available immediately. Refusing while the status was not Running left the user with no way
        # to prepare the other machine — which is exactly the report that started this change.
        $script:copied = $null
        $state = Join-Path $TestDrive 'state.json'
        $cipher = Protect-LanSecret -Text 'Pw12345!'
        $record = [pscustomobject]@{
            Shares = @([pscustomobject]@{
                Name='Test'; AuthMode='Protected'; Status='WaitingNetwork'
                NetworkProfile=[pscustomobject]@{Name='@WNP-WiFi';InterfaceAlias='Wi-Fi'}
                CredentialInfo=[pscustomobject]@{UserName='LFS_abc';PasswordCipher=$cipher}
            })
        }
        $row = New-Object Windows.Forms.ListViewItem('Test')
        foreach ($v in @('Folder','C:\x','Modify','Protected Password','True','WaitingNetwork','\\HOST\Test')) { [void]$row.SubItems.Add([string]$v) }
        $list = New-Object Windows.Forms.ListView
        [void]$list.Items.Add($row); $row.Selected = $true
        $status = New-Object Windows.Forms.Label
        $ui = @{ ShareList=$list; Status=$status }
        Invoke-LanCopyLogin -Ui $ui -StatePath $state -SetClipboardText { param($t) $script:copied = $t } `
            -ReadState { param($p) $record } -Unprotect { param($c) Unprotect-LanSecret -CipherText $c }
        ($null -eq $script:copied) | Should Be $false
        $script:copied | Should Match 'LFS_abc'
        $script:copied | Should Match 'Pw12345!'
        $script:copied | Should Match 'WaitingNetwork'
        $status.Text | Should Match 'WaitingNetwork'
        $list.Dispose()
    }

    It 'does not warn about functions that live inside a here-string' {
        # This check was written twice with different rules: the deploy script ignored here-strings and
        # the window did not, so the window warned about "Add-Trace" and "Set-Result" — helper-process
        # functions that are never loaded here. A false alarm cannot be told apart from a real one, and
        # the healthy window refused to start. Both callers now share one scan.
        $dir = Join-Path $TestDrive 'scan'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $lines = @(
            'function Get-RealThing { }'
            '$body = @'''
            'function Get-HelperOnly { }'
            '''@'
            '# function Get-CommentedOut { }'
        )
        [IO.File]::WriteAllText((Join-Path $dir 'Ui.ps1'), (($lines -join "`n") + "`n"))
        $names = @(Get-LanDefinedFunction -Path (Join-Path $dir 'Ui.ps1'))
        ($names -contains 'Get-RealThing') | Should Be $true
        ($names -contains 'Get-HelperOnly') | Should Be $false
        ($names -contains 'Get-CommentedOut') | Should Be $false
    }

    It 'reports a genuinely missing function and stays quiet on a healthy tree' {
        $healthy = Join-Path $TestDrive 'healthy'
        New-Item -ItemType Directory -Path $healthy -Force | Out-Null
        # A module whose only function is already loaded must not be reported.
        [IO.File]::WriteAllText((Join-Path $healthy 'Selection.ps1'), 'function Get-LanDefinedFunction { }')
        ($null -eq (Assert-LanCodeMatchesDisk -SourceRoot $healthy)) | Should Be $true

        $broken = Join-Path $TestDrive 'broken'
        New-Item -ItemType Directory -Path $broken -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $broken 'Ui.ps1'), 'function This-FunctionIsNotLoaded { }')
        $warning = Assert-LanCodeMatchesDisk -SourceRoot $broken
        ($null -eq $warning) | Should Be $false
        $warning | Should Match 'This-FunctionIsNotLoaded'
    }
    It 'fills every field from a pasted login block and ignores an ordinary path' {
        # This is what makes sharing between machines whose account names differ easy: the sharer
        # copies one block and the client pastes it once. An ordinary path must pass through
        # untouched, otherwise typing a UNC by hand would stop working.
        $nl = "`r`n"
        $block = "LAN File Sharing${nl}ผู้ใช้ : LFS_abc123${nl}รหัสผ่าน : Pw12345!${nl}UNC : \\HOST\share"
        $parsed = ConvertFrom-LanLoginBlock -Text $block
        $parsed.UserName | Should Be 'LFS_abc123'
        $parsed.Password | Should Be 'Pw12345!'
        $parsed.Unc | Should Be '\\HOST\share'

        ($null -eq (ConvertFrom-LanLoginBlock -Text '\\HOST\share')) | Should Be $true
        ($null -eq (ConvertFrom-LanLoginBlock -Text '')) | Should Be $true
        # A block without an address cannot be used, and must say so rather than fail silently.
        { ConvertFrom-LanLoginBlock -Text "ผู้ใช้ : x${nl}รหัสผ่าน : y" } | Should Throw 'UNC'
    }

    It 'fills the client fields when a login block is pasted into the path box' {
        $form = New-LanClientForm -WireEvents:$true
        try {
            $form.Show()
            $ui = $form.Tag
            $nl = "`r`n"
            $ui.Unc.Text = "LAN File Sharing${nl}ผู้ใช้ : LFS_abc123${nl}รหัสผ่าน : Pw12345!${nl}UNC : \\HOST\share"
            # TextChanged is synchronous: the real event handler must apply the block itself.
            # Calling the parser again would already see an ordinary UNC path.
            $ui.Unc.Text | Should Be '\\HOST\share'
            $ui.Auth.Text | Should Be 'Protected Password'
            $ui.WindowsAccount.Text | Should Be 'LFS_abc123'
            $ui.PasswordInput.Text | Should Be 'Pw12345!'
            $ui.Status.Text | Should Match 'LFS_abc123'

            # An ordinary path must be left exactly as typed and reported as not a block.
            $ui.Unc.Text = '\\OTHER\share'
            (Set-LanClientFromLoginBlock -Ui $ui) | Should Be $false
            $ui.Unc.Text | Should Be '\\OTHER\share'
            $ui.WindowsAccount.Text | Should Be 'LFS_abc123'   # untouched
        } finally { $form.Close(); $form.Dispose() }
    }
    It 'fills editable client fields from the dedicated one-paste box and clears the exposed block' {
        $form = New-LanClientForm -WireEvents:$true
        try {
            $form.Show()
            $ui = $form.Tag
            $nl = "`r`n"

            $ui.LoginBlockInput | Should Not BeNullOrEmpty
            $ui.LoginBlockInput.Multiline | Should Be $true
            $ui.LoginBlockInput.Text = "LAN File Sharing${nl}ผู้ใช้ : Kss${nl}รหัสผ่าน : Pw12345!${nl}UNC : \\HOST\Lessons"

            $ui.LoginBlockInput.Text | Should Be ''
            $ui.Unc.Text | Should Be '\\HOST\Lessons'
            $ui.Auth.Text | Should Be 'Protected Password'
            $ui.WindowsAccount.Text | Should Be 'Kss'
            $ui.PasswordInput.Text | Should Be 'Pw12345!'
            $ui.PasswordInput.UseSystemPasswordChar | Should Be $true
            $ui.Status.Text | Should Match 'Kss'

            # Every populated field remains editable after automatic detection.
            $ui.WindowsAccount.Text = 'ManualUser'
            $ui.PasswordInput.Text = 'ManualPassword'
            $ui.Unc.Text = '\\OTHER\ManualShare'
            $ui.WindowsAccount.Text | Should Be 'ManualUser'
            $ui.PasswordInput.Text | Should Be 'ManualPassword'
            $ui.Unc.Text | Should Be '\\OTHER\ManualShare'
        } finally { $form.Close(); $form.Dispose() }
    }
    It 'keeps existing client fields unchanged when the dedicated paste block is incomplete' {
        $form = New-LanClientForm -WireEvents:$true
        try {
            $form.Show()
            $ui = $form.Tag
            $ui.Unc.Text = '\\CURRENT\Share'
            $ui.WindowsAccount.Text = 'CurrentUser'
            $ui.PasswordInput.Text = 'CurrentPassword'

            $ui.LoginBlockInput.Text = "LAN File Sharing`r`nผู้ใช้ : NewUser`r`nUNC : \\NEW\Share"

            $ui.Unc.Text | Should Be '\\CURRENT\Share'
            $ui.WindowsAccount.Text | Should Be 'CurrentUser'
            $ui.PasswordInput.Text | Should Be 'CurrentPassword'
            $ui.LoginBlockInput.Text | Should Match 'NewUser'
            $ui.Status.Text | Should Match 'รหัสผ่าน'
        } finally { $form.Close(); $form.Dispose() }
    }
    It 'keeps both log panes inside the window at every size' {
        # Adding a pane to the client tab without growing the tab area put it below the visible
        # region, so the log disappeared from the tab that had always had one. Both panes must stay
        # inside their form when the window is at its smallest and when it is maximised.
        foreach ($size in @(@(990,1015),@(990,720),@(1400,1000))) {
            $form = New-LanMainForm -WireEvents:$false
            try {
                $form.Size = [Drawing.Size]::new($size[0],$size[1])
                $form.CreateControl(); $form.PerformLayout()
                $ui = $form.Tag
                $hostLog = $ui.HostForm.Tag.Log
                $clientLog = $ui.ClientForm.Tag.Log
                foreach($pane in @($hostLog,$clientLog)){
                    ($pane.Bottom -le $pane.Parent.ClientSize.Height) | Should Be $true
                    ($pane.Right -le $pane.Parent.ClientSize.Width) | Should Be $true
                }
                $ui.HostForm.Tag.ScrollHost.AutoScroll | Should Be $true
                $ui.ClientForm.Tag.ScrollHost.AutoScroll | Should Be $true
            } finally { $form.Dispose() }
        }
    }
    It 'shows a live log pane on the client tab too' {
        # The sharing tab always had one; the client tab had none, so a slow connection looked frozen.
        $form = New-LanClientForm -WireEvents:$true
        try {
            $form.Show()
            $ui = $form.Tag
            $ui.Log | Should Not BeNullOrEmpty
            $ui.LogTimer | Should Not BeNullOrEmpty
            ($ui.LogTimer.Enabled) | Should Be $true

            Clear-LanClientLog
            Update-LanClientLogPane -State $ui
            # An empty pane says why it is empty rather than looking broken.
            $ui.Log.Items.Count | Should Be 1
            $ui.Log.Items[0].SubItems[1].Text | Should Match 'ยังไม่มีบันทึก'

            Add-LanClientLog 'ขั้นตอนทดสอบ'
            Update-LanClientLogPane -State $ui
            $ui.Log.Items.Count | Should Be 1
            $ui.Log.Items[0].SubItems[1].Text | Should Be 'ขั้นตอนทดสอบ'

            # The client log must not be the sharing log: the two sides run on different machines and
            # the sharing log belongs to the machine-wide progress folder.
            (Get-LanClientLogPath) | Should Not Be (Get-LanProgressLogPath)
        } finally { Clear-LanClientLog; $form.Close(); $form.Dispose() }
    }

    It 'keeps the startup check boxes clear of the tab control' {
        # Growing the tab control to make room for the log panes put it on top of the per-user startup
        # controls, so the check boxes stopped being visible at all — they were still created, just
        # covered. This checks the two areas never overlap and both fit inside the window.
        $form = New-LanMainForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            $ui.StartupToggle.PerformClick()
            $tabsBottom = $ui.Tabs.Location.Y + $ui.Tabs.Height
            ($tabsBottom) | Should BeLessThan ($ui.StartupPanel.Top + 1)
            foreach ($control in @($ui.StartWithHost,$ui.StartMinimized,$ui.StartupButton,$ui.StartupHelp)) {
                ($control.Bottom -le $control.Parent.ClientSize.Height) | Should Be $true
            }
        } finally { $form.Close(); $form.Dispose() }
    }

    It 'offers automatic reconnection on the client tab' {
        Mock Get-LanUserStartupSettings { [pscustomobject]@{AutoReconnect=$true;StartWithHost=$false;StartMinimized=$false;ShowAfterSeconds=15} }
        $form = New-LanClientForm -WireEvents:$true
        try {
            $form.Show()
            $ui = $form.Tag
            $ui.AutoReconnect | Should Not BeNullOrEmpty
            # On by default: reconnecting saved drives is what a reboot usually needs.
            ($ui.AutoReconnect.Checked) | Should Be $true
            $ui.ReconnectTimer | Should Not BeNullOrEmpty
        } finally { $form.Close(); $form.Dispose() }
    }
    It 'keeps the account label clear of the box beside it' {
        # The Thai label was wider than its 125 px slot and ran into the account box.
        $form = New-LanClientForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            $ui.WindowsAccountLabel.Bottom | Should BeLessThan ($ui.WindowsAccount.Parent.Top + 1)
            $ui.PasswordLabel.Bottom | Should BeLessThan ($ui.PasswordInput.Parent.Top + 1)
        } finally { $form.Close(); $form.Dispose() }
    }
    It 'shows the password field only for the mode that uses it' {
        # Protected Password is the mode that works between machines whose Windows account names
        # differ, so its account and password fields must be the ones on show. The other modes must
        # not offer a password box that Windows would ignore.
        $form = New-LanClientForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            foreach ($mode in @('WindowsCurrent','Protected Password','Guest')) {
                $ui.Auth.SelectedIndex = [array]::IndexOf(@($ui.Auth.Items),[string]$mode)
                Update-LanClientCredentialFields -Ui $ui
                if ($mode -eq 'Protected Password') {
                    ($ui.PasswordInput.Visible) | Should Be $true
                    ($ui.WindowsAccount.Visible) | Should Be $true
                    ($ui.AccountHint.Visible) | Should Be $true
                    # The hint must say that the computer name may be left off, because that was the
                    # part that was not clear.
                    $ui.AccountHint.Text | Should Match 'LFS_'
                    $ui.AccountHint.Text | Should Match 'ใส่หรือไม่ใส่ชื่อเครื่อง'
                } else {
                    ($ui.PasswordInput.Visible) | Should Be $false
                    ($ui.AccountHint.Visible) | Should Be $false
                }
            }
        } finally { $form.Close(); $form.Dispose() }
    }
    It 'shows a live progress log panel that fits inside the window' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $ui = $form.Tag
            $ui.Log | Should Not BeNullOrEmpty
            $ui.Progress | Should Not BeNullOrEmpty
            $ui.LogTimer | Should Not BeNullOrEmpty
            # The log must be visible without resizing, and every control inside the client area.
            ($ui.Log.Bottom -le $ui.Log.Parent.ClientSize.Height) | Should Be $true
            $ui.ScrollHost.AutoScroll | Should Be $true
            foreach ($control in $form.Controls) {
                ($control.Bottom -le $form.ClientSize.Height) | Should Be $true
                ($control.Right -le $form.ClientSize.Width) | Should Be $true
            }
        } finally { $form.Dispose() }
    }
    It 'has a Windows launcher and PowerShell entry point' {
        [IO.File]::Exists((Join-Path $PSScriptRoot '../LanShare.ps1')) | Should Be $true
        [IO.File]::Exists((Join-Path $PSScriptRoot '../Start-LanShare.cmd')) | Should Be $true
    }
    It 'provides all sharer selections, rights and default boot sharing' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $ui = $form.Tag
            @($ui.Kind.Items) | Should Be @('Drive','Folder','File')
            @($ui.Mode.Items) | Should Be @('Read','Modify')
            $ui.AutoStart.Checked | Should Be $true
            $ui.Create.Text | Should Match 'แชร์'
            $ui.Stop.Text | Should Match 'หยุด'
            $ui.CopyUnc.Text | Should Match 'Copy UNC'
            $ui.ShareList | Should Not BeNullOrEmpty
        } finally { $form.Dispose() }
    }
    It 'shows passwordless LAN policy controls only for WindowsCurrent sharing' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $form.Tag.Auth.SelectedItem='WindowsCurrent'
            $form.Tag.ScrollHost.ScrollControlIntoView($form.Tag.AdvancedToggle)
            $form.Tag.AdvancedToggle.PerformClick()
            $form.Tag.BlankPasswordEnable.Visible | Should Be $true
            $form.Tag.BlankPasswordRestore.Visible | Should Be $true
            $form.Tag.Auth.SelectedItem='Protected Password'
            $form.Tag.BlankPasswordEnable.Visible | Should Be $false
        } finally { $form.Dispose() }
    }

    It 'accepts a separate Windows account on the client tab' {
        $form = New-LanClientForm -WireEvents:$false
        try {
            $form.Tag.WindowsAccount | Should Not BeNullOrEmpty
            $form.Tag.WindowsAccountLabel.Text | Should Match 'บัญชีบนเครื่องผู้แชร์'
            $form.Tag.WindowsAccountLabel.Bottom | Should BeLessThan ($form.Tag.WindowsAccount.Parent.Top + 1)
            $accountField=$form.Tag.WindowsAccount.Parent.Parent
            $form.Tag.Auth.Parent.Parent.Parent.Bottom | Should BeLessThan ($accountField.Parent.Top + 1)
            $accountField.Parent.Bottom | Should BeLessThan ($form.Tag.Open.Parent.Top + 1)
        } finally { $form.Dispose() }
    }

    It 'switches Drive to Folder for a selected Downloads subfolder on any local drive' {
        $downloads=Join-Path $TestDrive 'Downloads'
        New-Item -ItemType Directory -Path $downloads -Force | Out-Null
        $form=New-LanHostForm -WireEvents:$false
        try {
            $ui=$form.Tag
            $ui.Kind.Text='Drive'
            $ui.Path.Text=$downloads
            Sync-LanUiKindForPath -Ui $ui
            $ui.Kind.Text | Should Be 'Folder'
            $ui.Status.Text | Should Match 'Folder'
        } finally { $form.Dispose() }
    }

    It 'keeps Drive for a volume root and preserves explicit File selection' {
        $root=[IO.Path]::GetPathRoot($TestDrive)
        $form=New-LanHostForm -WireEvents:$false
        try {
            $ui=$form.Tag
            $ui.Kind.Text='Drive'
            $ui.Path.Text=$root
            Sync-LanUiKindForPath -Ui $ui
            $ui.Kind.Text | Should Be 'Drive'
            $ui.Kind.Text='File'
            $ui.Path.Text=Join-Path $TestDrive 'note.txt'
            Sync-LanUiKindForPath -Ui $ui
            $ui.Kind.Text | Should Be 'File'
        } finally { $form.Dispose() }
    }

    It 'keeps host labels clear of their selected values' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            foreach ($pair in @(
                @('ชนิดที่แชร์',$ui.Kind),
                @('Drive / Folder / File',$ui.Path),
                @('ชื่อ Share',$ui.Name),
                @('วิธีเข้าใช้',$ui.Auth),
                @('รหัสผ่าน',$ui.PasswordMethod),
                @('บัญชีที่อนุญาต (ว่าง = ทุกบัญชีที่ยืนยันตัวตน)',$ui.Principals)
            )) {
                if(-not $pair[1].Visible){continue}
                $label = @($pair[1].Parent.Parent.Controls | Where-Object { $_ -is [Windows.Forms.Label] })[0]
                $label.Bottom | Should BeLessThan ($pair[1].Parent.Top + 1)
            }
        } finally { $form.Dispose() }
    }

    It 'explains that a custom share account must not reuse an existing Windows login name' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $form.Tag.AccountNameLabel.Text | Should Match 'ห้ามซ้ำ'
        } finally { $form.Dispose() }
    }

    It 'defaults to Protected Password and exposes password choices only for that mode' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            @($ui.Auth.Items) | Should Be @('Protected Password','WindowsCurrent','Guest')
            $ui.Auth.Text | Should Be 'Protected Password'
            $ui.GuestConfig | Should Not BeNullOrEmpty
            $ui.Auth.SelectedItem='WindowsCurrent'
            $ui.PasswordInput.Visible | Should Be $false
            $ui.Auth.SelectedItem='Protected Password'
            $ui.PasswordInput.Visible | Should Be $true
            @($ui.PasswordMethod.Items) | Should Be @('โปรแกรมสุ่ม','กำหนดเอง')
            $ui.PasswordMethod.SelectedIndex | Should Be 0
            $ui.PasswordInput.Text.Length | Should BeGreaterThan 24
            $ui.PasswordInput.UseSystemPasswordChar | Should Be $false
            (Get-LanHostProtectedPassword -Ui $ui) | Should Be $ui.PasswordInput.Text
            $firstRandom = $ui.PasswordInput.Text
            $ui.RegeneratePassword.PerformClick()
            $ui.PasswordInput.Text | Should Not Be $firstRandom
            $ui.PasswordMethod.SelectedIndex = 1
            $ui.PasswordInput.UseSystemPasswordChar | Should Be $true
            $ui.PasswordInput.Text | Should BeNullOrEmpty
            { Get-LanHostProtectedPassword -Ui $ui } | Should Throw 'Password is required'
            $ui.PasswordInput.Text = 'Chosen#Pass123'
            (Get-LanHostProtectedPassword -Ui $ui) | Should Be 'Chosen#Pass123'
            $ui.Auth.SelectedItem='WindowsCurrent'
            $ui.PasswordInput.Visible | Should Be $false
            (Get-LanHostProtectedPassword -Ui $ui) | Should BeNullOrEmpty
            $ui.Status | Should Not BeNullOrEmpty
        } finally { $form.Dispose() }
    }

    It 'maps the visible Protected Password label to the persisted auth mode' {
        (ConvertTo-LanAuthMode -Label 'Protected Password') | Should Be 'Protected'
        (ConvertTo-LanAuthLabel -Mode 'Protected') | Should Be 'Protected Password'
    }
    It 'shows the new label for an existing Protected share' {
        $path = Join-Path $TestDrive 'existing-protected.json'
        $state = Read-LanState -Path $path
        $state.Shares = @([pscustomobject]@{
            Id='existing'; Name='Existing'; Kind='Folder'; SourcePath='C:\Shared'; Mode='Read'
            AuthMode='Protected'; AutoStart=$true; Status='Running'
        })
        Write-LanState -Path $path -State $state
        $form = New-LanHostForm -WireEvents:$false
        try {
            Update-LanHostList -Ui $form.Tag -StatePath $path
            $form.Tag.ShareList.Items[0].SubItems[4].Text | Should Be 'Protected Password'
        } finally { $form.Dispose() }
    }
    It 'loads the sharer list through the elevated bridge when running unelevated' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Tag.UseBridge=$true
            $form.Tag.BridgeAdapter=@{Exchange={ param($action,$payload) @([pscustomobject]@{
                Id='remote';Name='Remote';Kind='Folder';SourcePath='F:\Data';Mode='Read';
                AuthMode='WindowsCurrent';AutoStart=$true;Status='Running';LastError=$null
            }) }}
            Update-LanHostList -Ui $form.Tag -StatePath (Join-Path $TestDrive 'missing-host-state.json')
            $form.Tag.ShareList.Items.Count | Should Be 1
            $form.Tag.ShareList.Items[0].Text | Should Be 'Remote'
        } finally { $form.Dispose() }
    }

    It 'shows no phantom share row when the saved host list is empty' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Tag.UseBridge=$true
            $form.Tag.BridgeAdapter=@{Exchange={ param($action,$payload) return $null }}
            Update-LanHostList -Ui $form.Tag -StatePath (Join-Path $TestDrive 'empty-host-state.json')
            $form.Tag.ShareList.Items.Count | Should Be 0
            $form.Tag.Status.Text | Should Not Match 'ไม่มีข้อมูลวิธีเข้าใช้'
            $form.Tag.Status.Text | Should Match 'ยังไม่มีรายการแชร์'
        } finally { $form.Dispose() }
    }
    It 'hides a share row with no name or id so Stop cannot target it' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            Update-LanHostList -Ui $form.Tag -StatePath (Join-Path $TestDrive 'unused.json') -Entries @([pscustomobject]@{})
            $form.Tag.ShareList.Items.Count | Should Be 0
        } finally { $form.Dispose() }
    }

    It 'explains missing path and share name before attempting an elevated create' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            { Assert-LanHostCreateFields -Ui $form.Tag } | Should Throw 'Drive / Folder / File'
            $form.Tag.Path.Text='F:\'
            { Assert-LanHostCreateFields -Ui $form.Tag } | Should Throw 'ชื่อ Share'
            $form.Tag.Name.Text='Laptop'
            { Assert-LanHostCreateFields -Ui $form.Tag } | Should Not Throw
        } finally { $form.Dispose() }
    }
    It 'shows the missing-path message when Start Share is clicked' {
        $form = New-LanHostForm -UseBridge:$true
        try {
            $form.Tag.BridgeAdapter=@{Exchange={ param($action,$payload) return $null }}
            $form.Show()
            $form.Tag.Create.PerformClick()
            $form.Tag.Status.Text | Should Match 'กรุณาเลือก Drive / Folder / File'
            $form.Tag.Create.Enabled | Should Be $true
        } finally { $form.Dispose() }
    }

    It 'keeps the host window responsive while a bridge Create request is running' {
        $form = New-LanHostForm -UseBridge:$true
        try {
            $ui = $form.Tag
            $ui.BridgeJobStarter = {
                param($root,$payload)
                Start-Job -ArgumentList $payload.Name -ScriptBlock {
                    param($name)
                    Start-Sleep -Milliseconds 1800
                    [pscustomobject]@{Name=$name;NtfsPolicy='Preserved';Shares=@([pscustomobject]@{
                        Id='async';Name=$name;Kind='Drive';SourcePath='C:\';Mode='Modify';
                        AuthMode='WindowsCurrent';AutoStart=$true;Status='Running'
                    })}
                }
            }
            $ui.Kind.Text='Drive'; $ui.Path.Text='C:\'; $ui.Name.Text='AsyncTest'; $ui.Mode.Text='Modify'
            $form.Show()
            $ui.Create.PerformClick()
            # What matters is that the press handed the work to a helper and returned: a job exists,
            # the button is locked against a second press, and the window itself is still enabled so it
            # keeps repainting. Wall-clock timing is deliberately not asserted — it measured whatever
            # Start-Job happened to cost on the machine, which varied by seconds and failed spuriously.
            ($null -eq $ui.Job) | Should Be $false
            $ui.Create.Enabled | Should Be $false
            $form.Enabled | Should Be $true
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while (-not $ui.Create.Enabled -and [DateTime]::UtcNow -lt $deadline) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            $ui.Create.Enabled | Should Be $true
            $ui.Status.Text | Should Match 'NTFS'
            $ui.ShareList.Items.Count | Should Be 1
        } finally {
            if ($form.Tag.Job) { Stop-Job $form.Tag.Job -ErrorAction SilentlyContinue; Remove-Job $form.Tag.Job -Force -ErrorAction SilentlyContinue }
            $form.Dispose()
        }
    }

    It 'shows a saved share with no access mode without crashing the sharer tab' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Tag.UseBridge=$true
            $form.Tag.BridgeAdapter=@{Exchange={ param($action,$payload) @([pscustomobject]@{
                Id='legacy';Name='OldShare';Kind='Folder';SourcePath='F:\Data';Mode='Read';
                AuthMode='';AutoStart=$true;Status='Running';LastError=$null
            }) }}
            Update-LanHostList -Ui $form.Tag -StatePath (Join-Path $TestDrive 'unused.json')
            $form.Tag.ShareList.Items.Count | Should Be 1
            $form.Tag.ShareList.Items[0].SubItems[4].Text | Should Be 'Unknown'
            $form.Tag.ShareList.Items[0].Tag | Should Be 'legacy'
            $form.Tag.Status.Text | Should Match 'OldShare.*วิธีเข้าใช้'
        } finally { $form.Dispose() }
    }

    It 'shows a host list loading error in the window instead of throwing from tab open' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Tag.UseBridge=$true
            $form.Tag.BridgeAdapter=@{Exchange={ throw 'host state unavailable' }}
            Show-LanHostList -Ui $form.Tag -StatePath (Join-Path $TestDrive 'unused.json')
            $form.Tag.Status.Text | Should Match 'host state unavailable'
            $form.Tag.ShareList.Items.Count | Should Be 0
        } finally { $form.Dispose() }
    }

    It 'selects the newly created share after refreshing the host list' {
        $path = Join-Path $TestDrive 'copy-unc-shares.json'
        $state = Read-LanState -Path $path
        $state.Shares = @([pscustomobject]@{
            Id='new-share'; Name='LaptopKs'; Kind='Drive'; SourcePath='F:\'; Mode='Modify'
            AuthMode='WindowsCurrent'; AutoStart=$true; Status='Running'
        })
        Write-LanState -Path $path -State $state
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            Update-LanHostList -Ui $form.Tag -StatePath $path -SelectName 'LaptopKs'
            $form.Tag.ShareList.SelectedItems.Count | Should Be 1
            $form.Tag.ShareList.SelectedItems[0].Text | Should Be 'LaptopKs'
        } finally { $form.Dispose() }
    }
    It 'copies the full UNC of the selected running share' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            $row = New-Object Windows.Forms.ListViewItem('LaptopKs')
            foreach ($value in @('Drive','F:\','Modify','WindowsCurrent','True','Running','\\SCHOOL-HOST\LaptopKs')) {
                [void]$row.SubItems.Add($value)
            }
            [void]$ui.ShareList.Items.Add($row)
            $row.Selected = $true
            $captured = [pscustomobject]@{Text=$null}
            $copy = { param($text) $captured.Text = $text }.GetNewClosure()
            Invoke-LanCopyUnc -Ui $ui -SetClipboardText $copy
            $captured.Text | Should Be '\\SCHOOL-HOST\LaptopKs'
            $ui.Status.Text | Should Match 'คัดลอก UNC แล้ว'
        } finally { $form.Dispose() }
    }
    It 'copies the most recently selected share when the user switches rows' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            foreach ($name in @('First','Second')) {
                $row = New-Object Windows.Forms.ListViewItem($name)
                foreach ($value in @('Folder','F:\Data','Read','WindowsCurrent','True','Running',"\\SCHOOL-HOST\$name")) {
                    [void]$row.SubItems.Add($value)
                }
                [void]$ui.ShareList.Items.Add($row)
            }
            $ui.ShareList.Items[0].Selected = $true
            $ui.ShareList.Items[1].Selected = $true
            $captured = [pscustomobject]@{Text=$null}
            $copy = { param($text) $captured.Text = $text }.GetNewClosure()
            Invoke-LanCopyUnc -Ui $ui -SetClipboardText $copy
            $captured.Text | Should Be '\\SCHOOL-HOST\Second'
        } finally { $form.Dispose() }
    }
    It 'does not copy when no share is selected' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            $captured = [pscustomobject]@{Text=$null}
            $copy = { param($text) $captured.Text = $text }.GetNewClosure()
            Invoke-LanCopyUnc -Ui $ui -SetClipboardText $copy
            $captured.Text | Should BeNullOrEmpty
            $ui.Status.Text | Should Match 'เลือก'
        } finally { $form.Dispose() }
    }
    It 'runs the copy action from the host Copy UNC button' {
        $form = New-LanHostForm
        try {
            $form.Show()
            $form.Tag.ShareList.Items.Clear()
            $form.Tag.CopyUnc.PerformClick()
            $form.Tag.Status.Text | Should Match 'เลือกรายการแชร์'
        } finally { $form.Dispose() }
    }
    It 'does not copy a share that is not running' {
        $form = New-LanHostForm -WireEvents:$false
        try {
            $form.Show()
            $ui = $form.Tag
            $row = New-Object Windows.Forms.ListViewItem('Stopped')
            foreach ($value in @('Folder','F:\Data','Read','WindowsCurrent','False','Stopped','\\SCHOOL-HOST\Stopped')) {
                [void]$row.SubItems.Add($value)
            }
            [void]$ui.ShareList.Items.Add($row)
            $row.Selected = $true
            $captured = [pscustomobject]@{Text=$null}
            $copy = { param($text) $captured.Text = $text }.GetNewClosure()
            Invoke-LanCopyUnc -Ui $ui -SetClipboardText $copy
            $captured.Text | Should BeNullOrEmpty
            $ui.Status.Text | Should Match 'ยังไม่พร้อม'
        } finally { $form.Dispose() }
    }
    It 'provides UNC open, Map Drive, reconnect and unmap controls' {
        $form = New-LanClientForm -WireEvents:$false
        try {
            $ui = $form.Tag
            $ui.Open | Should Not BeNullOrEmpty
            $ui.Map | Should Not BeNullOrEmpty
            $ui.OpenDrive | Should Not BeNullOrEmpty
            $ui.Unmap | Should Not BeNullOrEmpty
            $ui.SavedMaps | Should Not BeNullOrEmpty
            $ui.RestoreGuest | Should Not BeNullOrEmpty
            $ui.Reconnect.Checked | Should Be $true
            @($ui.Auth.Items) | Should Be @('Protected Password','WindowsCurrent','Guest')
            $ui.Auth.Text | Should Be 'Protected Password'
            @($ui.Letter.Items)[0] | Should Be 'Auto'
        } finally { $form.Dispose() }
    }
    It 'lists mappings saved by an earlier client session' {
        $path = Join-Path $TestDrive 'saved-maps.json'
        Write-LanClientMappings -Path $path -Mappings @([pscustomobject]@{Letter='P';Unc='\\server\share';AuthMode='Protected';Persistent=$true})
        $form = New-LanClientForm -WireEvents:$false
        try {
            # SkipLivenessCheck keeps the cleanup away from this machine's real drives: the fixture describes
            # mappings that exist only in the test.
            $adapter = @{StatePath=$path;SkipLivenessCheck=$true}
            Update-LanClientMapList -Ui $form.Tag -Adapter $adapter
            $form.Tag.SavedMaps.Items.Count | Should Be 1
            $form.Tag.MapEntries[0].Letter | Should Be 'P'
        } finally { $form.Dispose() }
    }
    It 'grows the tab control with the window so the log pane stays visible' {
        # This is the regression that made a maximised window worse: the tab control was anchored
        # to the top only, so it kept its 675 px height while the startup settings stayed at their
        # fixed offset. The startup block then covered the bottom of the host tab, hiding the log
        # pane completely on a maximised window. The tab control must keep growing with the window.
        $form = New-LanMainForm -WireEvents:$false
        try {
            $tabs = $form.Tag.Tabs
            ($tabs.Anchor -band [Windows.Forms.AnchorStyles]::Bottom) | Should Not Be 0

            $form.Size = [Drawing.Size]::new(990,700)
            $form.CreateControl(); $form.PerformLayout()
            $small = $tabs.Height
            $form.Size = [Drawing.Size]::new(1400,1000)
            $form.PerformLayout()
            ($tabs.Height -gt $small) | Should Be $true

            # The host tab must be tall enough for the whole host layout, whose last element (the
            # progress label) ends at y=730 inside the embedded form. The number follows the layout on
            # purpose: this is the assertion that catches a tab too short to show its own content.
            ($form.Tag.HostForm.ClientSize.Height -ge 731) | Should Be $true
        } finally { $form.Dispose() }
    }
    It 'keeps shared startup controls accessible below the workspace' {
        $form = New-LanMainForm -WireEvents:$false
        try {
            $ui = $form.Tag
            $form.Show(); $ui.StartupToggle.PerformClick()
            foreach ($control in @($ui.StartWithHost,$ui.StartMinimized,$ui.ShowAfter,$ui.StartupButton,$ui.StartupStatus,$ui.StartupHelp)) {
                $control.Visible | Should Be $true
                ($control.Bottom -le $control.Parent.ClientSize.Height) | Should Be $true
            }
            ($ui.StartupPanel.Bottom -le $form.ClientSize.Height) | Should Be $true
            ($form.MinimumSize.Width) | Should Be 900
            # 700 is the smallest height at which both log panes still fit inside their tabs.
            ($form.MinimumSize.Height) | Should Be 700
        } finally { $form.Dispose() }
    }
    It 'hides to the notification area instead of exiting when the window is closed' {
        # Closing by accident used to stop the share. Only the tray's Exit may end the process; the
        # title bar X, Alt+F4 and the system menu must leave the program running in the background.
        #
        # The close is raised through Form.Close(), which is exactly what the title bar X does, so
        # the real FormClosing handler in the form runs. Reflection is deliberately not used:
        # PowerShell wraps arguments in a PSObject that reflection then refuses to convert.
        $form = New-LanMainForm -WireEvents:$true
        try {
            $ui = $form.Tag
            $ui.ExitRequested = $false
            $form.Show()
            $form.Close()
            # The close was cancelled: the window is hidden but the form still exists.
            ($form.Visible) | Should Be $false
            ($form.IsDisposed) | Should Be $false
            ($ui.ExitRequested) | Should Be $false

            # The tray's Exit sets the flag and then closes, and that one really closes.
            $ui.ExitRequested = $true
            $form.Close()
            ($form.IsDisposed) | Should Be $true
        } finally {
            if (-not $form.IsDisposed) { $form.Dispose() }
        }
    }
    It 'does not cancel the close when Windows itself is shutting down' {
        # Cancelling a shutdown close would make Windows wait for the process, so a shutdown must be
        # allowed through even while the program is resident in the notification area. That reason
        # can only be raised by the system, so the handler's condition is checked at the source.
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/Ui.ps1'))
        $source | Should Match 'CloseReason\]::WindowsShutDown'
        $source | Should Match 'CloseReason\]::TaskManagerClosing'
        # And that check must come before the cancel, or a shutdown would be blocked.
        $index = $source.IndexOf('CloseReason]::WindowsShutDown')
        $cancel = $source.IndexOf('$eventArgs.Cancel=$true')
        ($index -lt $cancel) | Should Be $true
    }
}
