Add-Type -AssemblyName System.IO.Compression
Describe 'single-file Windows setup' {
    BeforeAll {
        $script:setup = Join-Path $PSScriptRoot '../artifacts/development-unsigned/LanFileSharing-Setup-v3.81-UNSIGNED-DEVELOPMENT.exe'
        if (-not [IO.File]::Exists($script:setup)) {
            & (Join-Path $PSScriptRoot '../installer/Build-Release.ps1') -DevelopmentUnsigned -Version '3.81' | Out-Null
        }
    }
    It 'has an installer builder, GUI, elevated engine and normal-user launcher source' {
        foreach ($name in @('Build-Release.ps1','SetupForm.cs','InstallEngine.cs','Launcher.cs')) {
            [IO.File]::Exists((Join-Path $PSScriptRoot "../installer/$name")) | Should Be $true
        }
    }

    It 'has a bundled installation action that preflights before reset' {
        $action=Join-Path $PSScriptRoot '../Installer-Action.ps1'
        [IO.File]::Exists($action) | Should Be $true
        if (Test-Path -LiteralPath $action) {
            $tokens=$null; $errors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($action,[ref]$tokens,[ref]$errors)
            @($errors).Count | Should Be 0
        }
    }

    It 'builds a standalone setup executable with an embedded verified payload' {
        $setup=$script:setup
        [IO.File]::Exists($setup) | Should Be $true
        if (Test-Path -LiteralPath $setup) {
            $bytes=[IO.File]::ReadAllBytes($setup)
            [Text.Encoding]::ASCII.GetString($bytes,0,2) | Should Be 'MZ'
            $assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom($setup)
            (@($assembly.GetManifestResourceNames()) -contains 'LanFileSharing.Payload.zip') | Should Be $true
        }
    }

    It 'verifies every embedded payload hash without installing or requesting UAC' {
        $setup=$script:setup
        $report=Join-Path $TestDrive 'verification.txt'
        $process=Start-Process -FilePath $setup -ArgumentList ('--verify "'+$report+'"') -Wait -PassThru -WindowStyle Hidden
        $process.ExitCode | Should Be 0
        [IO.File]::ReadAllText($report) | Should Match '^OK files=\d+'
        $assembly=[Reflection.Assembly]::LoadFrom($setup)
        $resource=$assembly.GetManifestResourceStream('LanFileSharing.Payload.zip')
        try {
            $archive=New-Object IO.Compression.ZipArchive($resource,[IO.Compression.ZipArchiveMode]::Read)
            try {
                $names=@($archive.Entries | ForEach-Object { $_.FullName })
                foreach($name in @('LanFileSharing.exe','HostHelper.ps1','Reset-LanShare.ps1','Installer-Action.ps1','OnlineSetup.ps1','OnlineSignIn.ps1','src/UserStartup.ps1','src/HostBridge.ps1','manifest.sha256')) {
                    ($names -contains $name) | Should Be $true
                }
            } finally { $archive.Dispose() }
        } finally { $resource.Dispose() }
    }

    It 'reports the requested 64-bit or 32-bit default without changing the computer' {
        $setup=$script:setup
        $report=Join-Path $TestDrive 'inspect.txt'
        $process=Start-Process -FilePath $setup -ArgumentList ('--inspect "'+$report+'"') -Wait -PassThru -WindowStyle Hidden
        $process.ExitCode | Should Be 0
        $expected=if([Environment]::Is64BitOperatingSystem){'C:\Program Files\LanFileSharing'}else{'C:\Program Files (x86)\LanFileSharing'}
        [IO.File]::ReadAllText($report) | Should Match ([regex]::Escape('Default='+$expected))
    }

    It 'contains the uninstall and Windows Installed Apps registration paths' {
        $setup=$script:setup
        $assembly=[Reflection.Assembly]::LoadFrom($setup)
        $engine=$assembly.GetType('InstallEngine',$true)
        $flags=[Reflection.BindingFlags]'Static, NonPublic'
        $engine.GetMethod('RunInteractiveUninstall',$flags) | Should Not BeNullOrEmpty
        $engine.GetMethod('RegisterUninstall',$flags) | Should Not BeNullOrEmpty
        $engine.GetMethod('RemoveUninstallRegistration',$flags) | Should Not BeNullOrEmpty
        $engine.GetMethod('ElevatedBootstrap',$flags) | Should Not BeNullOrEmpty
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../installer/InstallEngine.cs'))
        $source | Should Match 'UninstallString'
        $source | Should Match '\-\-uninstall-temp'
        $source | Should Match 'start.FileName = protectedBootstrap \? elevationSource'
        $source | Should Match 'protectedStage = CreateStage\(true\)'
        $action=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../Installer-Action.ps1'))
        $action | Should Match '\$Phase -eq ''Uninstall'''
    }
}
