# Loaded in the same order the window loads them. Ui.ps1 calls into the layers below it — the version shown in
# the title comes from Selection.ps1 and the mapping helpers come from ClientMap.ps1 — so sourcing Ui.ps1 first
# left those undefined and five tests failed for a reason that had nothing to do with startup preferences.
. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/ClientMap.ps1"
. "$PSScriptRoot/../src/InstallLocation.ps1"
. "$PSScriptRoot/../src/Startup.ps1"
. "$PSScriptRoot/../src/HostBridge.ps1"
. "$PSScriptRoot/../src/UserStartup.ps1"
. "$PSScriptRoot/../src/Ui.ps1"

$script:startupClientFactory=${function:New-LanClientAdapter}
Describe 'per-user launch preferences and combined window' {
    BeforeEach {
        # Form startup must never restore or reconnect the user's real profiles
        # while these tests exercise only startup controls and window composition.
        $script:startupClientAdapter=& $script:startupClientFactory
        $script:startupClientAdapter.StatePath=Join-Path $TestDrive 'startup-mappings.json'
        $script:startupClientAdapter.CredentialPath=Join-Path $TestDrive 'startup-credentials.json'
        Mock New-LanClientAdapter {$script:startupClientAdapter}
    }
    It 'defaults both startup switches to Off' {
        $adapter=@{ReadPreference={ $null };ReadRun={ $null }}
        $settings=Get-LanUserStartupSettings -Adapter $adapter
        $settings.StartWithHost | Should Be $false
        $settings.StartMinimized | Should Be $false
    }

    It 'registers only a per-user login command with the auto-launch marker' {
        $script:preferences=@{}
        $script:run=$null
        $adapter=@{
            ReadPreference={ param($name) $script:preferences[$name] }
            WritePreference={ param($name,$value) $script:preferences[$name]=$value }
            ReadRun={ $script:run }
            WriteRun={ param($value) $script:run=$value }
            RemoveRun={ $script:run=$null }
        }
        Set-LanUserStartupSettings -StartWithHost $true -StartMinimized $true -LauncherPath 'C:\Program Files\LanFileSharing\LanFileSharing.exe' -Adapter $adapter
        $script:run | Should Be '"C:\Program Files\LanFileSharing\LanFileSharing.exe" --auto'
        $settings=Get-LanUserStartupSettings -Adapter $adapter
        $settings.StartWithHost | Should Be $true
        $settings.StartMinimized | Should Be $true
        Set-LanUserStartupSettings -StartWithHost $false -StartMinimized $false -LauncherPath 'C:\Program Files\LanFileSharing\LanFileSharing.exe' -Adapter $adapter
        $script:run | Should BeNullOrEmpty
    }

    It 'places sharer and file-user controls in actual tab pages' {
        $form=New-LanMainForm -WireEvents:$false
        try {
            $ui=$form.Tag
            $ui.Tabs.TabPages.Count | Should Be 3
            $ui.Tabs.TabPages[2].Text | Should Be 'Online'
            $ui.Tabs.TabPages[0].Text | Should Be 'เครื่องผู้ใช้ไฟล์'
            $ui.Tabs.TabPages[1].Text | Should Be 'เครื่องผู้แชร์'
            $ui.Tabs.TabPages[0].Controls.Contains($ui.ClientForm) | Should Be $true
            $ui.Tabs.TabPages[1].Controls.Contains($ui.HostForm) | Should Be $true
            $ui.ClientForm.Contains($ui.ClientForm.Tag.Map) | Should Be $true
            $ui.HostForm.Contains($ui.HostForm.Tag.CopyUnc) | Should Be $true
        } finally { $form.Dispose() }
    }

    It 'hides only an automatic startup and has a recoverable tray action' {
        $settings=[pscustomobject]@{StartWithHost=$true;StartMinimized=$true}
        (Test-LanStartHidden -AutoLaunch $true -Settings $settings) | Should Be $true
        (Test-LanStartHidden -AutoLaunch $false -Settings $settings) | Should Be $false
        $form=New-LanMainForm -WireEvents:$false
        try {
            $form.Tag.TrayOpen | Should Not BeNullOrEmpty
            $form.Tag.TrayExit | Should Not BeNullOrEmpty
        } finally { $form.Dispose() }
    }

    It 'signals an existing window instead of creating a second instance' {
        # A private name keeps this test independent of a copy of the app that may be running.
        $name='Local\LanFileSharing-Test-'+[guid]::NewGuid().ToString('N')
        $first=New-LanSingleInstance -Name $name
        try {
            $first.IsFirst | Should Be $true
            $second=New-LanSingleInstance -Name $name
            $second.IsFirst | Should Be $false
            $first.Wake.WaitOne(1000) | Should Be $true
        } finally { Close-LanSingleInstance -Instance $first }
    }
    It 'sends the restore signal from another process in the same Windows session' {
        $name='Local\LanFileSharing-Test-'+[guid]::NewGuid().ToString('N')
        $first=New-LanSingleInstance -Name $name
        $job=$null
        try {
            $module=Join-Path $PSScriptRoot '../src/UserStartup.ps1'
            $job=Start-Job -ArgumentList $module,$name -ScriptBlock {
                param($path,$name)
                . $path
                $other=New-LanSingleInstance -Name $name
                return $other.IsFirst
            }
            Wait-Job -Job $job -Timeout 30 | Out-Null
            $job.State | Should Be 'Completed'
            (Receive-Job -Job $job) | Should Be $false
            $first.Wake.WaitOne(1000) | Should Be $true
        } finally {
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
            Close-LanSingleInstance -Instance $first
        }
    }

    It 'reports the auto-start state and whether it matches this installation' {
        $launcher='C:\Program Files\LanFileSharing\LanFileSharing.exe'
        $script:run=$null
        $script:pref=@{}
        $adapter=@{
            ReadPreference={ param($name) $script:pref[$name] }
            WritePreference={ param($name,$value) $script:pref[$name]=$value }
            ReadRun={ $script:run }
            WriteRun={ param($value) $script:run=$value }
            RemoveRun={ $script:run=$null }
        }
        # Off: the window must say so rather than staying silent.
        $state=Get-LanUserStartupState -Adapter $adapter
        $state.Enabled | Should Be $false
        $state.Description | Should Match 'ยังไม่เปิด'
        (Test-LanUserStartupRegistered -LauncherPath $launcher -Adapter $adapter) | Should Be $false

        # On with the window shown.
        Set-LanUserStartupSettings -StartWithHost $true -StartMinimized $false -LauncherPath $launcher -Adapter $adapter
        $state=Get-LanUserStartupState -Adapter $adapter
        $state.Enabled | Should Be $true
        $state.StartMinimized | Should Be $false
        $state.LoginCommand | Should Match '--auto'
        $state.Description | Should Match 'แสดงหน้าต่าง'
        (Test-LanUserStartupRegistered -LauncherPath $launcher -Adapter $adapter) | Should Be $true

        # On and staying in the tray first, then showing the window after the configured wait.
        Set-LanUserStartupSettings -StartWithHost $true -StartMinimized $true -LauncherPath $launcher -ShowAfterSeconds 20 -Adapter $adapter
        $state=Get-LanUserStartupState -Adapter $adapter
        $state.StartMinimized | Should Be $true
        $state.ShowAfterSeconds | Should Be 20
        $state.Description | Should Match 'เด้งหน้าต่างหลัง 20 วินาที'

        # Zero means the tray only, and the window must say exactly that.
        Set-LanUserStartupSettings -StartWithHost $true -StartMinimized $true -LauncherPath $launcher -ShowAfterSeconds 0 -Adapter $adapter
        $state=Get-LanUserStartupState -Adapter $adapter
        $state.ShowAfterSeconds | Should Be 0
        $state.Description | Should Match 'ถาดระบบเท่านั้น'

        # A missing preference keeps the documented default rather than meaning "never".
        $fresh=@{ ReadPreference={ $null }; ReadRun={ '"C:\x\LanFileSharing.exe" --auto' } }
        (Get-LanUserStartupSettings -Adapter $fresh).ShowAfterSeconds | Should Be 15

        # A command left by another installation is still reported as registered but as not
        # matching this one, so the window can warn instead of claiming success.
        $script:run='C:\Other\LanFileSharing.exe --auto'
        (Test-LanUserStartupRegistered -LauncherPath $launcher -Adapter $adapter) | Should Be $false
        (Get-LanUserStartupState -Adapter $adapter).Enabled | Should Be $true
        # Any registered auto command counts, even with extra arguments or no trailing marker.
        $script:run='"C:\Program Files\LanFileSharing\LanFileSharing.exe" --auto --quiet'
        (Get-LanUserStartupSettings -Adapter $adapter).StartWithHost | Should Be $true
    }
    It 'offers a startup button and disables minimizing when auto-start is off' {
        $form=New-LanMainForm -WireEvents:$false
        try {
            $ui=$form.Tag
            $ui.StartupButton | Should Not BeNullOrEmpty
            $ui.StartupButton.Text | Should Match 'Startup'
            $ui.StartupStatus | Should Not BeNullOrEmpty
            $ui.StartWithHost.Text | Should Match 'อัตโนมัติ'
            $ui.StartMinimized.Text | Should Match 'ถาดระบบ'
        } finally { $form.Dispose() }
    }
    It 'starts hidden only for auto-launch and restores through the tray Open action' {
        $settings=[pscustomobject]@{StartWithHost=$true;StartMinimized=$true}
        $autoForm=New-LanMainForm -AutoLaunch $true -StartupSettings $settings
        try {
            $autoForm.Tag.StartHidden | Should Be $true
            $autoForm.Show()
            [Windows.Forms.Application]::DoEvents()
            $autoForm.Visible | Should Be $false
            $autoForm.Tag.TrayOpen.PerformClick()
            $autoForm.Visible | Should Be $true
        } finally { $autoForm.Dispose() }
        $manualForm=New-LanMainForm -AutoLaunch $false -StartupSettings $settings
        try {
            $manualForm.Show()
            [Windows.Forms.Application]::DoEvents()
            $manualForm.Visible | Should Be $true
        } finally { $manualForm.Dispose() }
    }
    It 'loads the sharer tab through the bridge while the main window remains unelevated' {
        Mock Get-LanPublicShares { @([pscustomobject]@{
            Id='test';Name='Data';Kind='Folder';SourcePath='F:\Data';Mode='Read';
            AuthMode='WindowsCurrent';AutoStart=$true;Status='Running';LastError=$null
        }) }
        Mock Get-LanHostStatePath { Join-Path $TestDrive 'host-state.json' }
        $settings=[pscustomobject]@{StartWithHost=$false;StartMinimized=$false}
        $form=New-LanMainForm -SelectHost $true -StartupSettings $settings
        $form.Tag.HostForm.Tag.BridgeAdapter=@{Exchange={ param($action,$payload) @([pscustomobject]@{
            Id='test';Name='Data';Kind='Folder';SourcePath='F:\Data';Mode='Read';
            AuthMode='WindowsCurrent';AutoStart=$true;Status='Running';LastError=$null
        }) }}
        try {
            $form.Show()
            [Windows.Forms.Application]::DoEvents()
            $form.Tag.HostForm.Tag.ShareList.Items.Count | Should Be 1
        } finally { $form.Dispose() }
    }
}
