. "$PSScriptRoot/../src/Online.ps1"

Describe 'NetBird automatic install and repair' {
    It 'accepts only Windows 10 or 11 x64' {
        { Assert-LanOnlineSetupPlatform -Adapter @{IsWindows={$true};Is64Bit={$true};OsVersion={[version]'10.0.19045'}} } | Should Not Throw
        { Assert-LanOnlineSetupPlatform -Adapter @{IsWindows={$true};Is64Bit={$false};OsVersion={[version]'10.0.19045'}} } | Should Throw
        { Assert-LanOnlineSetupPlatform -Adapter @{IsWindows={$false};Is64Bit={$true};OsVersion={[version]'10.0.19045'}} } | Should Throw
        { Assert-LanOnlineSetupPlatform -Adapter @{IsWindows={$true};Is64Bit={$true};OsVersion={[version]'6.3'}} } | Should Throw
    }

    It 'uses the official moving x64 MSI endpoint and rejects an unexpected redirect' {
        (Get-LanNetBirdStableInstallerUri).AbsoluteUri | Should Be 'https://pkgs.netbird.io/windows/msi/x64'
        { Assert-LanNetBirdInstallerUri 'https://github.com/netbirdio/netbird/releases/download/v0.80.0/netbird_installer_0.80.0_windows_amd64.msi' } | Should Not Throw
        { Assert-LanNetBirdInstallerUri 'https://release-assets.githubusercontent.com/github-production-release-asset/123/file.msi' } | Should Not Throw
        { Assert-LanNetBirdInstallerUri 'http://pkgs.netbird.io/windows/msi/x64' } | Should Throw
        { Assert-LanNetBirdInstallerUri 'https://example.org/netbird.msi' } | Should Throw
        { Assert-LanNetBirdInstallerUri 'https://github.com/other/netbird/releases/download/v1/netbird.msi' } | Should Throw
    }

    It 'stops before installation when the MSI signature is not valid' {
        $ran=$false
        $adapter=@{
            GetSignature={param($p)[pscustomobject]@{Status='NotSigned';SignerCertificate=$null}}
            RunInstaller={param($p,$a)$script:ran=$true;[pscustomobject]@{ExitCode=0}}
        }
        { Install-LanNetBirdMsi -Path 'C:\Temp\netbird.msi' -Adapter $adapter } | Should Throw
        $ran | Should Be $false
    }

    It 'runs MSI silently without requesting a restart' {
        $script:seenArgs=''
        $adapter=@{
            GetSignature={param($p)[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=NetBird GmbH'}}}
            RunInstaller={param($p,$a)$script:seenArgs=$a;[pscustomobject]@{ExitCode=0;Stdout='';Stderr=''}}
        }
        (Install-LanNetBirdMsi -Path 'C:\Temp\netbird.msi' -Adapter $adapter).ExitCode | Should Be 0
        $script:seenArgs | Should Match '/i\s+"C:\\Temp\\netbird\.msi"'
        $script:seenArgs | Should Match '/qn'
        $script:seenArgs | Should Match '/norestart'
        $script:seenArgs | Should Not Match '/forcerestart'
    }

    It 'recreates a stale service and waits for the daemon without deleting its profile' {
        $script:commands=@(); $script:probes=0
        $adapter=@{
            ProbeDaemon={ $script:probes++; return ($script:probes -ge 3) }
            ServiceExists={ $true }
            RunClient={param($p,$a)$script:commands+=,$a;[pscustomobject]@{ExitCode=0;Stdout='';Stderr=''}}
            WaitServiceMissing={ $true }
            Sleep={param($ms)}
        }
        $r=Repair-LanNetBirdService -ClientPath 'C:\Program Files\NetBird\netbird.exe' -Adapter $adapter
        $r.RepairMode | Should Be 'RecreatedService'
        ($script:commands -join '|') | Should Be 'service stop|service uninstall|service reset-params|service install|service start'
        ($script:commands -join '|') | Should Not Match 'default\.json|ProgramData|delete|remove'
        $r.DaemonAnswered | Should Be $true
    }

    It 'does not change a healthy service' {
        $script:commands=@()
        $adapter=@{
            ProbeDaemon={ $true }
            ServiceExists={ $true }
            RunClient={param($p,$a)$script:commands+=,$a;throw 'must not run'}
            WaitServiceMissing={ $true }
            Sleep={param($ms)}
        }
        (Repair-LanNetBirdService -ClientPath 'C:\Program Files\NetBird\netbird.exe' -Adapter $adapter).RepairMode | Should Be 'AlreadyHealthy'
        @($script:commands).Count | Should Be 0
    }

    It 'always removes its private download directory after a failure' {
        $directory=Join-Path $TestDrive 'download';[IO.Directory]::CreateDirectory($directory)|Out-Null
        $script:removed=$false
        $adapter=@{
            IsWindows={$true};Is64Bit={$true};OsVersion={[version]'10.0.19045'}
            FindClient={$null}
            CreateTempDirectory={$directory}
            DownloadInstaller={param($uri,$path)throw 'network unavailable'}
            RemoveTempDirectory={param($path)$script:removed=($path -eq $directory);Remove-Item -LiteralPath $path -Recurse -Force}
        }
        { Invoke-LanOnlineInstallRepair -Adapter $adapter } | Should Throw
        $script:removed | Should Be $true
        Test-Path $directory | Should Be $false
    }

    It 'repairs a trusted existing client without running the same MSI over its locked file' {
        $client=Join-Path $TestDrive 'netbird.exe';[IO.File]::WriteAllText($client,'fixture')
        $script:downloaded=$false;$script:installed=$false
        $adapter=@{
            IsWindows={$true};Is64Bit={$true};OsVersion={[version]'10.0.19045'}
            FindClient={$client};AssertTrustedClient={param($p)}
            GetSignature={param($p)[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=NetBird GmbH'}}}
            ProbeDaemon={$true};ServiceExists={$true};RunClient={param($p,$a)throw 'healthy service must not change'};WaitServiceMissing={$true};Sleep={param($ms)}
            CreateTempDirectory={throw 'download must not start'};DownloadInstaller={$script:downloaded=$true};RunInstaller={$script:installed=$true}
            RemoveTempDirectory={param($p)}
        }
        $result=Invoke-LanOnlineInstallRepair -Adapter $adapter
        $result.Passed | Should Be $true
        $result.PackageAction | Should Be 'UsedExistingClient'
        $script:downloaded | Should Be $false
        $script:installed | Should Be $false
    }
}
