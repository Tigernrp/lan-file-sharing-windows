$modulePath = Join-Path $PSScriptRoot '../src/InstallLocation.ps1'
if (Test-Path -LiteralPath $modulePath) { . $modulePath }

Describe 'chosen LAN File Sharing installation location' {
    It 'uses the exact requested defaults for 64-bit and 32-bit Windows' {
        (Get-LanDefaultInstallRoot -Is64BitOs $true) | Should Be 'C:\Program Files\LanFileSharing'
        (Get-LanDefaultInstallRoot -Is64BitOs $false) | Should Be 'C:\Program Files (x86)\LanFileSharing'
    }

    It 'round-trips only the selected application location' {
        $script:record = $null
        $adapter = @{
            ReadRecord = { $script:record }
            WriteRecord = { param($path) $script:record = $path }
            DeleteRecord = { $script:record = $null }
        }
        Write-LanInstallRecord -Path 'D:\Protected\LanFileSharing' -Adapter $adapter
        (Get-LanInstallRecord -Adapter $adapter).InstallRoot | Should Be 'D:\Protected\LanFileSharing'
        { Remove-LanInstallRecord -ExpectedPath 'D:\Other\LanFileSharing' -Adapter $adapter } | Should Throw
        (Get-LanInstallRecord -Adapter $adapter).InstallRoot | Should Be 'D:\Protected\LanFileSharing'
        Remove-LanInstallRecord -ExpectedPath 'D:\Protected\LanFileSharing' -Adapter $adapter
        Get-LanInstallRecord -Adapter $adapter | Should BeNullOrEmpty
    }

    It 'accepts a fixed NTFS destination beneath a protected parent' {
        $adapter = @{
            GetDrive = { param($root) [pscustomobject]@{DriveType='Fixed';DriveFormat='NTFS'} }
            GetPathInfo = { param($path) [pscustomobject]@{Exists=$true;Reparse=$false;OwnerSid='S-1-5-32-544';UntrustedWrite=$false;UntrustedDelete=$false} }
        }
        (Assert-LanSafeInstallRoot -Path 'D:\Protected\LanFileSharing' -Adapter $adapter) | Should Be 'D:\Protected\LanFileSharing'
    }

    It 'accepts the actual Windows Program Files parent on this machine' {
        { Assert-LanSafeInstallRoot -Path 'C:\Program Files\LanFileSharing' } | Should Not Throw
    }

    It 'rejects network, reparse and user-writable destinations' {
        $adapter = @{
            GetDrive = { param($root) [pscustomobject]@{DriveType='Fixed';DriveFormat='NTFS'} }
            GetPathInfo = { param($path) [pscustomobject]@{Exists=$true;Reparse=$false;OwnerSid='S-1-5-32-544';UntrustedWrite=$false;UntrustedDelete=$false} }
        }
        { Assert-LanSafeInstallRoot -Path '\\server\share\LanFileSharing' -Adapter $adapter } | Should Throw
        $adapter.GetPathInfo = { param($path) [pscustomobject]@{Exists=$true;Reparse=$true;OwnerSid='S-1-5-32-544';UntrustedWrite=$false;UntrustedDelete=$false} }
        { Assert-LanSafeInstallRoot -Path 'D:\Linked\LanFileSharing' -Adapter $adapter } | Should Throw
        $adapter.GetPathInfo = { param($path) [pscustomobject]@{Exists=$true;Reparse=$false;OwnerSid='S-1-5-32-544';UntrustedWrite=$true;UntrustedDelete=$false} }
        { Assert-LanSafeInstallRoot -Path 'D:\Writable\LanFileSharing' -Adapter $adapter } | Should Throw
    }

    It 'requires a protected existing parent except for the requested 32-bit default' {
        $adapter = @{
            GetDrive = { param($root) [pscustomobject]@{DriveType='Fixed';DriveFormat='NTFS'} }
            GetPathInfo = {
                param($path)
                $missing = $path -in @('D:\Missing','C:\Program Files (x86)')
                [pscustomobject]@{Exists=(-not $missing);Reparse=$false;OwnerSid='S-1-5-32-544';UntrustedWrite=$false;UntrustedDelete=$false}
            }
        }
        { Assert-LanSafeInstallRoot -Path 'D:\Missing\LanFileSharing' -Adapter $adapter } | Should Throw
        (Assert-LanSafeInstallRoot -Path 'C:\Program Files (x86)\LanFileSharing' -Adapter $adapter) | Should Be 'C:\Program Files (x86)\LanFileSharing'
    }
    It 'creates the missing requested 32-bit parent with a protected ACL' {
        $script:protectedParent=$null
        $script:parentCreated=$false
        $adapter = @{
            GetPathInfo = { param($path) [pscustomobject]@{Exists=$script:parentCreated;Reparse=$false;OwnerSid='S-1-5-32-544';UntrustedWrite=$false} }
            CreateProtectedParent = { param($path) $script:protectedParent=$path; $script:parentCreated=$true }
        }
        Initialize-LanInstallParent -Path 'C:\Program Files (x86)\LanFileSharing' -Adapter $adapter
        $script:protectedParent | Should Be 'C:\Program Files (x86)'
        $script:parentCreated=$false
        { Initialize-LanInstallParent -Path 'D:\Missing\LanFileSharing' -Adapter $adapter } | Should Throw
    }
}
