. "$PSScriptRoot/../src/Selection.ps1"

Describe 'LAN selection' {
    It 'recognizes only the Windows volume root for the special drive policy' {
        Test-LanSystemDriveRoot -Path 'C:\' -Kind Drive -WindowsDirectory 'C:\Windows' | Should Be $true
        Test-LanSystemDriveRoot -Path 'C:\Users\Teacher\Downloads' -Kind Folder -WindowsDirectory 'C:\Windows' | Should Be $false
        Test-LanSystemDriveRoot -Path 'D:\' -Kind Drive -WindowsDirectory 'C:\Windows' | Should Be $false
    }

    It 'allows a Drive share containing a reparse child without following the child' {
        $root = Join-Path $TestDrive 'drive-with-link'
        $outside = Join-Path $TestDrive 'outside-drive-link'
        New-Item -ItemType Directory -Path $root,$outside -Force | Out-Null
        $link = Join-Path $root 'node_modules'
        cmd /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { return }
        $selection = [pscustomobject]@{Kind='Drive';FullPath=$root}
        { Assert-LanShareRoot -Selection $selection } | Should Not Throw
        $selection.Kind = 'Folder'
        { Assert-LanShareRoot -Selection $selection } | Should Not Throw
    }

    It 'resolves a folder and records its volume' {
        $folder = Join-Path $TestDrive 'shared'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $result = Resolve-LanSelection -Kind Folder -Path $folder
        $result.Kind | Should Be 'Folder'
        $result.FullPath | Should Be ([IO.Path]::GetFullPath($folder).TrimEnd('\'))
        $result.VolumeId | Should Not BeNullOrEmpty
    }

    It 'resolves a file without treating its parent as the share' {
        $file = Join-Path $TestDrive 'chosen.txt'
        Set-Content -LiteralPath $file -Value 'hello'
        $result = Resolve-LanSelection -Kind File -Path $file
        $result.Kind | Should Be 'File'
        $result.FullPath | Should Be ([IO.Path]::GetFullPath($file))
    }

    It 'resolves an entire drive only from its root' {
        $root = [IO.Path]::GetPathRoot($TestDrive)
        $result = Resolve-LanSelection -Kind Drive -Path $root
        $result.FullPath | Should Be $root
        { Resolve-LanSelection -Kind Drive -Path $TestDrive } | Should Throw
    }

    It 'rejects missing and wrong-kind paths' {
        { Resolve-LanSelection -Kind File -Path (Join-Path $TestDrive 'absent.txt') } | Should Throw
        { Resolve-LanSelection -Kind Folder -Path $TestDrive/absent } | Should Throw
        { Resolve-LanSelection -Kind File -Path $TestDrive } | Should Throw
    }

    It 'validates Windows share names' {
        { Assert-LanShareName -Name 'Team_Data-1' } | Should Not Throw
        { Assert-LanShareName -Name 'bad/name' } | Should Throw
        { Assert-LanShareName -Name ('x' * 81) } | Should Throw
        { Assert-LanShareName -Name 'C$' } | Should Throw
    }

    It 'detects overlap with path boundaries' {
        $a = Join-Path $TestDrive 'data'
        $b = Join-Path $TestDrive 'data2'
        (Test-LanOverlap -Candidate (Join-Path $a 'child') -Existing @($a)) | Should Be $true
        (Test-LanOverlap -Candidate $a -Existing @((Join-Path $a 'child'))) | Should Be $true
        (Test-LanOverlap -Candidate $b -Existing @($a)) | Should Be $false
    }

    It 'shares a folder that contains a linked directory without following the link' {
        $root = Join-Path $TestDrive 'root'
        New-Item -ItemType Directory -Path $root | Out-Null
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        $link = Join-Path $root 'link'
        cmd /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { return }
        $selection = Resolve-LanSelection -Kind Folder -Path $root
        # The link is pruned, not fatal: the user shares the folder they selected and the walk
        # never enters the target, so the share cannot silently reach outside the path.
        { Assert-LanShareRoot -Selection $selection } | Should Not Throw
        # A selected directory that is itself a link is also shared as selected, not refused.
        $linkSelection = Resolve-LanSelection -Kind Folder -Path $link
        { Assert-LanShareRoot -Selection $linkSelection } | Should Not Throw
    }

    It 'validates the selected root without enumerating descendants on every worker pass' {
        $root=Join-Path $TestDrive 'root-check-only'
        [IO.Directory]::CreateDirectory((Join-Path $root 'nested'))|Out-Null
        Mock Test-LanDriveMetadataChild { throw 'Root validation enumerated a descendant' }
        Assert-LanShareRoot -Selection ([pscustomobject]@{Kind='Folder';FullPath=$root}) | Should Be $true
    }
    It 'refuses only the Windows directory' {
        $windows = $env:windir
        $windowsSelection = [pscustomobject]@{Kind='Folder';FullPath=$windows}
        { Assert-LanShareRoot -Selection $windowsSelection } | Should Throw 'Windows directory'
        $insideWindows = [pscustomobject]@{Kind='Folder';FullPath=(Join-Path $windows 'System32')}
        { Assert-LanShareRoot -Selection $insideWindows } | Should Throw 'Windows directory'
        # Everything outside the Windows directory is allowed to be shared.
        $allowed = [pscustomobject]@{Kind='Folder';FullPath=$TestDrive}
        { Assert-LanShareRoot -Selection $allowed } | Should Not Throw
    }

    It 'does not inspect Windows volume metadata for any share kind' {
        $root = Join-Path $TestDrive 'drive-like'
        $metadata = Join-Path $root 'System Volume Information'
        $outside = Join-Path $TestDrive 'outside-drive'
        New-Item -ItemType Directory -Path $metadata -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $link = Join-Path $metadata 'blocked-link'
        cmd /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { return }
        # A Drive share skips scanning the Windows volume entirely.
        $selection = [pscustomobject]@{Kind='Drive';FullPath=$root}
        { Assert-LanShareRoot -Selection $selection } | Should Not Throw
        # A Folder share scans, but the Windows-owned container is pruned rather than entered,
        # so the reparse point inside it is never evaluated or recorded.
        $selection.Kind = 'Folder'
        { Assert-LanShareRoot -Selection $selection } | Should Not Throw
        # A linked directory in an ordinary folder is pruned the same way.
        $ordinaryLink = Join-Path $root 'ordinary-link'
        cmd /c "mklink /J `"$ordinaryLink`" `"$outside`"" | Out-Null
        if (Test-Path -LiteralPath $ordinaryLink) {
            { Assert-LanShareRoot -Selection $selection } | Should Not Throw
        }
    }
    It 'resolves paths itself when the framework refuses them' {
        # [IO.Path]::GetFullPath throws for a component longer than 255 characters or for a path
        # containing a character Win32 forbids. Those paths exist on real machines — OneDrive and
        # robocopy create them — and a bare framework exception told the user nothing useful.
        (Resolve-LanFullPath 'C:\temp\a\..\b') | Should Be 'C:\temp\b'
        (Resolve-LanFullPath 'C:/temp/a/b') | Should Be 'C:\temp\a\b'
        (Resolve-LanFullPath 'C:\temp\') | Should Be 'C:\temp\'
        (Resolve-LanFullPath 'C:\') | Should Be 'C:\'
        (Resolve-LanFullPath 'C:\Users\Teacher\OneDrive\Desktop\04-08-69 กิจกรรมประวัติศาสตร์') |
            Should Be 'C:\Users\Teacher\OneDrive\Desktop\04-08-69 กิจกรรมประวัติศาสตร์'
        # An unusable path reports what is wrong, and names the path, instead of a raw exception.
        $long = 'C:\temp\' + ('b' * 300)
        { Resolve-LanFullPath $long } | Should Throw 'cannot be used'
        { Resolve-LanFullPath 'C:\temp\a<b>c' } | Should Throw 'cannot be used'
        { Resolve-LanFullPath '' } | Should Throw 'empty'
    }
    It 'resolves paths manually for the inputs the framework refuses' {
        # Exercised directly: the framework ACCEPTS the hostile paths below, so going through
        # Resolve-LanFullPath would never reach this code.
        (Resolve-LanPathManually 'C:\temp\a\..\b') | Should Be 'C:\temp\b'
        (Resolve-LanPathManually 'C:/temp/a/b') | Should Be 'C:\temp\a\b'
        (Resolve-LanPathManually 'C:\temp\.') | Should Be 'C:\temp'
        (Resolve-LanPathManually 'C:\temp\') | Should Be 'C:\temp\'
        (Resolve-LanPathManually 'C:\') | Should Be 'C:\'
        (Resolve-LanPathManually 'C:\Users\Teacher\OneDrive\Desktop\04-08-69 กิจกรรมประวัติศาสตร์') |
            Should Be 'C:\Users\Teacher\OneDrive\Desktop\04-08-69 กิจกรรมประวัติศาสตร์'
        # A ".." that reaches the root is refused, not silently dropped.
        { Resolve-LanPathManually 'C:\..\..\escape' } | Should Throw 'escapes its root'
        { Resolve-LanPathManually 'C:\a\..\..\b' } | Should Throw 'escapes its root'
        { Resolve-LanPathManually '' } | Should Throw 'empty'
    }
}
