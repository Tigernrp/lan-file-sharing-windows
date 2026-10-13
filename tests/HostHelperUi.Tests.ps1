foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
$script:launcherSourcePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'installer\Launcher.cs'
Describe 'Actual process helper host UI' {
    BeforeEach {
        $script:fakeRoot=Join-Path $TestDrive 'helper-root'
        [IO.Directory]::CreateDirectory((Join-Path $script:fakeRoot 'src'))|Out-Null
        foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','InstallLocation','Startup')){
            [IO.File]::WriteAllText((Join-Path $script:fakeRoot "src/$m.ps1"),'')
        }
        # Only the privileged OS boundary is replaced. The actual generated helper, process,
        # result files, click handler and completion polling remain unchanged.
        [IO.File]::WriteAllText((Join-Path $script:fakeRoot 'src/HostBridge.ps1'),@'
function New-LanHostBridgeAdapter { @{} }
function Invoke-LanHostRequest { param($Action,$Payload,$Adapter)
 if($Payload.Name -eq 'FailFixture'){throw 'Fixture host boundary failure'}
 $marker=Join-Path $PSScriptRoot 'share-created.txt'
 if($Action -eq 'Create'){[IO.File]::WriteAllText($marker,'created')}
 if($Action -eq 'Stop'){Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue}
 if($Action -eq 'Create' -and $Payload.Name -eq 'ProtectedFixture'){
  return [pscustomobject]@{Name=$Payload.Name;NtfsPolicy='Preserved';UserName='FixtureAccount';InitialPassword='Fixture-only-Pw!'}
 }
 [pscustomobject]@{Name=$Payload.Name;NtfsPolicy='Preserved';Stopped=$true;Summary=$(if($Action -eq 'Stop'){'หยุดแชร์แล้ว และคืนสิทธิ์เดิมเรียบร้อย'}else{'Tool completed: '+$Action})}
}
function Get-LanPublicShares { param($StatePath)
 if(-not [IO.File]::Exists((Join-Path $PSScriptRoot 'share-created.txt'))){return}
 [pscustomobject]@{Id='fixture';Name='HelperFixture';Kind='Folder';SourcePath='F:\Fixture';Mode='Read';AuthMode='WindowsCurrent';AutoStart=$false;Status='Running'}
}
'@,(New-Object Text.UTF8Encoding($true)))
        Mock Get-LanHostStatePath {Join-Path $TestDrive 'state.json'}
        Mock Get-LanPublicShares {@()}
        Mock Invoke-LanHostRequest { @() }
    }
    It 'consumes a Protected result once while its owned credential dialog stays open across poll ticks' {
        $f=New-LanHostForm -UseBridge:$true
        try{
            $u=$f.Tag;$u.Root=$script:fakeRoot;$u.PreferencePath=Join-Path $TestDrive 'modal-ui.json';$f.Show()
            $u.Kind.Text='Folder';$u.Path.Text='F:\Fixture';$u.Name.Text='ProtectedFixture';$u.Auth.Text='Protected Password'
            $u.PasswordMethod.Text='กำหนดเอง';$u.PasswordInput.Text='Fixture-only-Pw!'
            $script:credentialDialogCount=0;$script:credentialDialogDepth=0;$script:credentialDialogPeak=0;$script:credentialDialogOwner=$null
            $u.CredentialPresenter={param($owner,$text,$title)
                $script:credentialDialogCount++;$script:credentialDialogDepth++
                $script:credentialDialogPeak=[Math]::Max($script:credentialDialogPeak,$script:credentialDialogDepth)
                $script:credentialDialogOwner=$owner
                $until=[DateTime]::UtcNow.AddMilliseconds(1800)
                while([DateTime]::UtcNow -lt $until){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 25}
                $script:credentialDialogDepth--
            }
            $u.Create.PerformClick();$job=$u.Job
            if(-not $job){throw ('Fixture Create did not launch: '+$u.Status.Text)}
            $paths=@($job.JobHelperPath,$job.JobPayloadPath,$job.JobOutputPath,$job.JobErrorPath,$job.JobStdoutPath,$job.JobResultPath)
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $script:credentialDialogPeak|Should Be 1
            $script:credentialDialogCount|Should Be 1
            $script:credentialDialogOwner|Should Be $f
            $u.Job|Should BeNullOrEmpty
            $u.Status.Text|Should Match 'แชร์พร้อมใช้.*ProtectedFixture'
            $u.PasswordInput.UseSystemPasswordChar|Should Be $true
            foreach($p in $paths){[IO.File]::Exists($p)|Should Be $false}
            # Polling must resume and process a later diagnostic, rather than remain paused.
            $u.AdvancedToggle.PerformClick();$u.GuestCheck.PerformClick()
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $u.Status.Text|Should Be 'Tool completed: CheckGuest'
        }finally{$f.Close();$f.Dispose()}
    }
    It 'shows actual helper results and deletes all temporary transport files after create and stop' {
        $f=New-LanHostForm -UseBridge:$true
        try{
            $u=$f.Tag;$u.Root=$script:fakeRoot;$u.PreferencePath=Join-Path $TestDrive 'ui.json';$f.Show()
            $u.Kind.Text='Folder';$u.Path.Text='F:\Fixture';$u.Name.Text='HelperFixture';$u.Auth.Text='WindowsCurrent'
            $u.Create.PerformClick();$job=$u.Job
            $paths=@($job.JobHelperPath,$job.JobPayloadPath,$job.JobOutputPath,$job.JobErrorPath,$job.JobStdoutPath,$job.JobResultPath)
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $u.Status.Text|Should Match 'แชร์พร้อมใช้.*HelperFixture'
            $u.ShareList.Items.Count|Should Be 1
            foreach($p in $paths){[IO.File]::Exists($p)|Should Be $false}
            $u.ShareList.Items[0].Selected=$true;$u.Stop.PerformClick();$stop=$u.Job
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $u.Status.Text|Should Match 'หยุดแชร์แล้ว'
            [IO.File]::Exists($stop.JobPayloadPath)|Should Be $false
        }finally{$f.Dispose()}
    }
    It 'runs every separate host tool through the actual click and helper completion' {
        $script:toolEntries=@([pscustomobject]@{Id='fixture';Name='HelperFixture';AuthMode='WindowsCurrent';Status='Running'})
        Mock Get-LanPublicShares {$script:toolEntries}
        $f=New-LanHostForm -UseBridge:$true
        try{
            $u=$f.Tag;$u.Root=$script:fakeRoot;$u.PreferencePath=Join-Path $TestDrive 'tool-ui.json';$f.Show();$u.AdvancedToggle.PerformClick()
            $entries=@([pscustomobject]@{Id='fixture';Name='HelperFixture';AuthMode='WindowsCurrent';Status='Running'})
            Update-LanHostList -Ui $u -Entries $entries -StatePath $u.StatePath
            $u.ShareList.Items[0].Selected=$true
            foreach($pair in @(@($u.GuestCheck,'CheckGuest'),@($u.GuestConfig,'ConfigureGuest'),@($u.GuestRestore,'RestoreGuest'),@($u.CheckShare,'CheckShare'),@($u.BlankPasswordEnable,'EnableBlankPassword'),@($u.BlankPasswordRestore,'RestoreBlankPassword'))){
                $u.Auth.Text='WindowsCurrent'
                if($pair[1] -eq 'CheckShare'){
                    Update-LanHostList -Ui $u -Entries $entries -StatePath $u.StatePath
                    $u.ShareList.Items[0].Selected=$true
                }
                $pair[0].PerformClick();if(-not $u.Job){throw ('Tool click did not launch: '+$pair[1]+'; '+$u.Status.Text+'; Visible='+$pair[0].Visible+'; Enabled='+$pair[0].Enabled)}
                $u.Create.Enabled|Should Be $false
                $deadline=[DateTime]::UtcNow.AddSeconds(20)
                while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                $u.Status.Text|Should Be ('Tool completed: '+$pair[1])
                $u.Create.Enabled|Should Be $true
            }
        }finally{$f.Dispose()}
    }
    It 'accepts a completed helper result even while a diagnostic file is locked' {
        $f=New-LanHostForm -UseBridge:$true;$held=$null
        try{
            $u=$f.Tag;$u.Root=$script:fakeRoot;$u.PreferencePath=Join-Path $TestDrive 'locked-ui.json';$f.Show()
            $u.Kind.Text='Folder';$u.Path.Text='F:\Fixture';$u.Name.Text='HelperFixture';$u.Auth.Text='WindowsCurrent'
            $u.Create.PerformClick();$job=$u.Job;$job.WaitForExit(20000)|Should Be $true
            $locked=Join-Path $TestDrive 'locked-stderr.txt';[IO.File]::WriteAllText($locked,'diagnostic only')
            $held=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $job.JobErrorPath=$locked
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $u.Status.Text|Should Match 'แชร์พร้อมใช้.*HelperFixture'
        }finally{if($held){$held.Dispose()};$f.Dispose()}
    }
    It 'rejects an empty helper result: <Content>' -TestCases @(@{Content=' '},@{Content='null'}) {
        param($Content)
        $f=New-LanHostForm -UseBridge:$true
        try{
            $u=$f.Tag;$u.Root=$script:fakeRoot;$u.PreferencePath=Join-Path $TestDrive 'empty-ui.json';$f.Show()
            $u.Kind.Text='Folder';$u.Path.Text='F:\Fixture';$u.Name.Text='HelperFixture';$u.Auth.Text='WindowsCurrent'
            $u.Create.PerformClick();$u.Job.WaitForExit(20000)|Should Be $true
            [IO.File]::WriteAllText($u.Job.JobResultPath,$Content)
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $u.Status.Text|Should Match 'เริ่มแชร์ไม่สำเร็จ'
        }finally{$f.Dispose()}
    }
    It 'surfaces the helper error rather than reporting missing result files' {
        $f=New-LanHostForm -UseBridge:$true
        try{
            $u=$f.Tag;$u.Root=$script:fakeRoot;$u.PreferencePath=Join-Path $TestDrive 'error-ui.json';$f.Show()
            $u.Kind.Text='Folder';$u.Path.Text='F:\Fixture';$u.Name.Text='FailFixture';$u.Auth.Text='WindowsCurrent'
            $u.Create.PerformClick();$deadline=[DateTime]::UtcNow.AddSeconds(20)
            while($u.Job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $u.Status.Text|Should Match 'Fixture host boundary failure'
            $u.Create.Enabled|Should Be $true;$u.Stop.Enabled|Should Be $true
        }finally{$f.Dispose()}
    }
    It 'uses Windows PowerShell modules when an incompatible Security module is inherited' {
        $bad=Join-Path $TestDrive 'incompatible-modules\Microsoft.PowerShell.Security'
        [IO.Directory]::CreateDirectory($bad)|Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'Microsoft.PowerShell.Security.psd1'),"@{RootModule='bad.psm1';ModuleVersion='99.0';GUID='42d05767-cd43-4bdd-8b8a-e21bd3d04ed5';FunctionsToExport=@('Get-ExecutionPolicy')}")
        [IO.File]::WriteAllText((Join-Path $bad 'bad.psm1'),"function Get-ExecutionPolicy { 'bad' }; throw 'Incompatible Security module was loaded'")
        $original=$env:PSModulePath;$f=New-LanHostForm -WireEvents:$false
        $job=$null
        try{
            $env:PSModulePath=(Split-Path $bad -Parent)+';'+(Join-Path $PSHOME 'Modules')
            $job=& $f.Tag.BridgeJobStarter $script:fakeRoot @{Name='HelperFixture'}
            $job.WaitForExit(20000)|Should Be $true
            $result=Get-Content $job.JobResultPath -Raw|ConvertFrom-Json
            $result.Error|Should BeNullOrEmpty
            $result.Name|Should Be 'HelperFixture'
            (Get-Content $job.JobOutputPath -Raw)|Should Match 'policy=Bypass'
        }finally{
            $env:PSModulePath=$original;$f.Dispose()
            if($job){foreach($p in @($job.JobHelperPath,$job.JobPayloadPath,$job.JobOutputPath,$job.JobErrorPath,$job.JobStdoutPath,$job.JobResultPath)){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue};$job.Dispose()}
        }
    }
    It 'launches Windows PowerShell with its own Security module despite an inherited incompatible module' {
        $bad=Join-Path $TestDrive 'launcher-modules\Microsoft.PowerShell.Security';[IO.Directory]::CreateDirectory($bad)|Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'Microsoft.PowerShell.Security.psd1'),"@{RootModule='bad.psm1';ModuleVersion='99.0';GUID='ba5a6b54-ff0e-4171-bfa5-bc404c609fcd';FunctionsToExport=@('Get-ExecutionPolicy')}")
        [IO.File]::WriteAllText((Join-Path $bad 'bad.psm1'),"function Get-ExecutionPolicy { 'bad' }; throw 'Incompatible Security module was loaded'")
        [IO.File]::WriteAllText((Join-Path $script:fakeRoot 'LanShare.ps1'),@'
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'policy.txt'),[string](Get-ExecutionPolicy))
'@)
        $launcher=Join-Path $script:fakeRoot 'LanFileSharing.exe'
        $compilerOutput=& (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe') /nologo /target:winexe /reference:System.Windows.Forms.dll "/out:$launcher" $script:launcherSourcePath
        if($LASTEXITCODE -ne 0){throw ($compilerOutput -join "`n")}
        $original=$env:PSModulePath
        try{
            $env:PSModulePath=(Split-Path $bad -Parent)+';'+(Join-Path $PSHOME 'Modules')
            $p=Start-Process -FilePath $launcher -WindowStyle Hidden -PassThru
            try{$p.WaitForExit(10000)|Should Be $true}finally{$p.Dispose()}
            $policy=Join-Path $script:fakeRoot 'policy.txt';$deadline=[DateTime]::UtcNow.AddSeconds(10)
            while(-not [IO.File]::Exists($policy) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
            [IO.File]::ReadAllText($policy)|Should Be 'Bypass'
        }finally{$env:PSModulePath=$original}
    }
}
