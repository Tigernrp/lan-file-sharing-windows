. "$PSScriptRoot/../src/State.ps1"

Describe 'LAN durable state' {
    It 'removes only empty ghost share records and keeps real shares' {
        $path = Join-Path $TestDrive 'ghost-shares.json'
        $state = New-LanEmptyState
        $state.Shares = @([pscustomobject]@{},[pscustomobject]@{Id='real';Name='Laptop';SourcePath='F:\';SharePath='F:\'})
        Write-LanState -Path $path -State $state

        $result = Remove-LanGhostShares -StatePath $path

        $result.Removed | Should Be 1
        $after = Read-LanState -Path $path
        @($after.Shares).Count | Should Be 1
        $after.Shares[0].Id | Should Be 'real'
    }

    It 'keeps an incomplete entry that still has identifying data or cleanup records' {
        $path = Join-Path $TestDrive 'partial-shares.json'
        $state = New-LanEmptyState
        $state.Shares = @([pscustomobject]@{Name='PossiblyReal'},[pscustomobject]@{AclRecords=@(@{Path='F:\'})})
        Write-LanState -Path $path -State $state

        $result = Remove-LanGhostShares -StatePath $path

        $result.Removed | Should Be 0
        @((Read-LanState -Path $path).Shares).Count | Should Be 2
    }
    It 'returns an empty versioned manifest when missing' {
        $state = Read-LanState -Path (Join-Path $TestDrive 'missing.json')
        $state.Version | Should Be 1
        @($state.Shares).Count | Should Be 0
    }

    It 'round-trips all share modes and boot identities' {
        $path = Join-Path $TestDrive 'manifest.json'
        $state = Read-LanState -Path $path
        $state.Shares = @(
            @{ Id='one'; AuthMode='Protected'; AutoStart=$true; VolumeId='AAAA'; FileId='01' },
            @{ Id='two'; AuthMode='WindowsCurrent'; AutoStart=$false; VolumeId='BBBB'; FileId=$null },
            @{ Id='three'; AuthMode='Guest'; AutoStart=$true; VolumeId='CCCC'; FileId=$null }
        )
        $state.Journal = @(@{ Id='one'; Phase='Preparing' })
        $state.GuestSnapshots = @(@{ Role='Host'; Setting='Enabled'; Original=0 })
        Write-LanState -Path $path -State $state
        $read = Read-LanState -Path $path
        @($read.Shares).Count | Should Be 3
        $read.Shares[0].AutoStart | Should Be $true
        $read.Shares[1].AuthMode | Should Be 'WindowsCurrent'
        $read.Shares[2].AuthMode | Should Be 'Guest'
        $read.Journal[0].Phase | Should Be 'Preparing'
        $read.GuestSnapshots[0].Original | Should Be 0
    }

    It 'rejects malformed state rather than clearing it' {
        $path = Join-Path $TestDrive 'bad.json'
        [IO.File]::WriteAllText($path, '{bad')
        { Read-LanState -Path $path } | Should Throw
    }

    It 'replaces an existing manifest atomically' {
        $path = Join-Path $TestDrive 'replace.json'
        $state = Read-LanState -Path $path
        Write-LanState -Path $path -State $state
        $state.Shares = @(@{ Id='new' })
        Write-LanState -Path $path -State $state
        (Read-LanState -Path $path).Shares[0].Id | Should Be 'new'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.lanstate-*').Count | Should Be 0
    }

    It 'encrypts a secret without retaining its plaintext on disk' {
        $secret = 'SensitiveTestPassword-123!'
        $cipher = Protect-LanSecret -Text $secret
        $cipher | Should Not Be $secret
        (Unprotect-LanSecret -CipherText $cipher) | Should Be $secret
        $path = Join-Path $TestDrive 'cipher.txt'
        [IO.File]::WriteAllText($path, $cipher)
        [IO.File]::ReadAllText($path).Contains($secret) | Should Be $false
    }

    It 'keeps client mappings separate from host shares' {
        $path = Join-Path $TestDrive 'mappings.json'
        @(Read-LanClientMappings -Path $path).Count | Should Be 0
        [IO.File]::WriteAllText($path, '[{"Letter":"P","Unc":"\\\\host\\share"}]')
        $maps = @(Read-LanClientMappings -Path $path)
        $maps.Count | Should Be 1
        $maps[0].Letter | Should Be 'P'
    }
}
