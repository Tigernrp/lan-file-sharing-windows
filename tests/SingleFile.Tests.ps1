. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/SingleFile.ps1"

Describe 'isolated single-file SMB root' {
    BeforeEach {
        $script:source = Join-Path $TestDrive 'selected.txt'
        [IO.File]::WriteAllText($script:source, 'original')
        $script:entry = New-LanSingleFileRoot -SourcePath $script:source -ShareId ([guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        try { Remove-LanSingleFileRoot -Entry $script:entry } catch { }
    }

    It 'exposes only the selected filename in its SMB root' {
        @(Get-ChildItem -LiteralPath $script:entry.Root -Force -File).Count | Should Be 1
        (Get-ChildItem -LiteralPath $script:entry.Root -Force -File).Name | Should Be 'selected.txt'
        (Get-LanFileId $script:entry.LinkPath) | Should Be (Get-LanFileId $script:source)
    }

    It 'applies in-place edits to the original immediately' {
        [IO.File]::WriteAllText($script:entry.LinkPath, 'edited in place')
        [IO.File]::ReadAllText($script:source) | Should Be 'edited in place'
        (Sync-LanSingleFile -Entry $script:entry).Status | Should Be 'InPlace'
    }

    It 'reconciles a replacement-style save to the original path' {
        [IO.File]::Delete($script:entry.LinkPath)
        [IO.File]::WriteAllText($script:entry.LinkPath, 'replacement')
        (Sync-LanSingleFile -Entry $script:entry).Status | Should Be 'Reconciled'
        [IO.File]::ReadAllText($script:source) | Should Be 'replacement'
        (Get-LanFileId $script:entry.LinkPath) | Should Be (Get-LanFileId $script:source)
    }

    It 'keeps both versions on a concurrent source and shared-file edit' {
        [IO.File]::Delete($script:entry.LinkPath)
        [IO.File]::WriteAllText($script:entry.LinkPath, 'client version')
        [IO.File]::WriteAllText($script:source, 'host version')
        (Sync-LanSingleFile -Entry $script:entry).Status | Should Be 'Conflict'
        [IO.File]::ReadAllText($script:source) | Should Be 'host version'
        [IO.File]::ReadAllText($script:entry.LinkPath) | Should Be 'client version'
    }

    It 'never deletes the original on cleanup' {
        Remove-LanSingleFileRoot -Entry $script:entry
        [IO.File]::Exists($script:source) | Should Be $true
        [IO.Directory]::Exists($script:entry.Root) | Should Be $false
    }
}
