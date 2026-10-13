$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'tools\PublicSource.psm1'
Import-Module $modulePath -Force

Describe 'Privacy-safe public source export' {
    BeforeEach {
        $script:scratchRoot = Join-Path $repoRoot ('.superpowers\sdd\public-source-tests-' + [guid]::NewGuid().ToString('N'))
        $script:sourceRoot = Join-Path $script:scratchRoot 'source'
        $script:destinationRoot = Join-Path $script:scratchRoot 'public'
        [IO.Directory]::CreateDirectory($script:sourceRoot) | Out-Null
    }

    AfterEach {
        if ([IO.Directory]::Exists($script:scratchRoot)) {
            [IO.Directory]::Delete($script:scratchRoot, $true)
        }
    }

    function Write-TestManifest {
        param(
            [string[]]$Files = @('safe.ps1'),
            [object[]]$Trees = @(),
            [object[]]$SensitivePatterns = @()
        )

        $manifestPath = Join-Path $script:sourceRoot 'manifest.json'
        $manifest = [ordered]@{
            Files = @($Files)
            Trees = @($Trees)
            DeniedDirectories = @('.git', '.superpowers', 'artifacts', 'release', 'open-source')
            DeniedFiles = @('handoff.md')
            DeniedExtensions = @('.exe', '.dll', '.msi', '.zip', '.rar', '.7z', '.pdb', '.log')
            SensitivePatterns = @($SensitivePatterns)
        }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        return $manifestPath
    }

    It 'exports_only_allowlisted_files' {
        $safePath = Join-Path $script:sourceRoot 'safe.ps1'
        $privatePath = Join-Path $script:sourceRoot 'private.txt'
        $safeBytes = [byte[]](0, 1, 2, 13, 10, 255)
        [IO.File]::WriteAllBytes($safePath, $safeBytes)
        [IO.File]::WriteAllText($privatePath, 'must not be copied')
        $manifestPath = Write-TestManifest

        $result = New-LanPublicSourceSnapshot -SourceRoot $script:sourceRoot -DestinationRoot $script:destinationRoot -Version 'test' -ManifestPath $manifestPath

        $result.CopiedFiles | Should Be @('safe.ps1')
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:destinationRoot 'safe.ps1'))) | Should Be ([Convert]::ToBase64String($safeBytes))
        Test-Path -LiteralPath (Join-Path $script:destinationRoot 'private.txt') | Should Be $false
        $result.RejectedFindings.Count | Should Be 0
    }

    It 'rejects_private_directories' {
        $releaseDir = Join-Path $script:sourceRoot 'release'
        [IO.Directory]::CreateDirectory($releaseDir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $releaseDir 'payload.ps1'), 'safe')
        $manifestPath = Write-TestManifest -Files @() -Trees @([pscustomobject]@{ Path = 'release'; Include = @('*.ps1') })

        { Get-LanPublicSourceManifest -SourceRoot $script:sourceRoot -ManifestPath $manifestPath } | Should Throw
    }

    It 'rejects_sensitive_values_case_insensitively' {
        $sensitivePath = Join-Path $script:sourceRoot 'safe.ps1'
        $sensitiveLabel = 'SeTuP' + '_KeY'
        [IO.File]::WriteAllText($sensitivePath, ($sensitiveLabel + ' = abcdefghijklmnopqrstuvwxyz123456'))
        $patterns = @([pscustomobject]@{ Id = 'netbird-setup-key'; Pattern = '(?im)setup[_ -]?key\s*[:=]\s*[a-z0-9_-]{16,}' })
        $manifestPath = Write-TestManifest -SensitivePatterns $patterns

        $result = Test-LanPublicSourceContent -Root $script:sourceRoot -PatternsPath $manifestPath

        $result.Passed | Should Be $false
        $result.Findings.Count | Should Be 1
        $result.Findings[0].Rule | Should Be 'netbird-setup-key'
        ($result.Findings[0].PSObject.Properties.Name -contains 'MatchedText') | Should Be $false
    }

    It 'rejects_thai_credential_labels' {
        $sensitivePath = Join-Path $script:sourceRoot 'safe.ps1'
        $thaiLabel = ([char]0x0E23).ToString() + [char]0x0E2B + [char]0x0E31 + [char]0x0E2A + [char]0x0E1C + [char]0x0E48 + [char]0x0E32 + [char]0x0E19
        [IO.File]::WriteAllText($sensitivePath, ($thaiLabel + ' : school-secret-987654'))
        $patterns = @([pscustomobject]@{ Id = 'thai-password-value'; Pattern = '(?im)\u0e23\u0e2b\u0e31\u0e2a\u0e1c\u0e48\u0e32\u0e19\s*[:=]\s*\S{8,}' })
        $manifestPath = Write-TestManifest -SensitivePatterns $patterns

        $result = Test-LanPublicSourceContent -Root $script:sourceRoot -PatternsPath $manifestPath

        $result.Passed | Should Be $false
        $result.Findings[0].Rule | Should Be 'thai-password-value'
    }

    It 'rejects_reparse_points' {
        $existingJunction = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force | Where-Object {
            $_.PSIsContainer -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        } | Select-Object -First 1)
        $existingJunction.Count | Should Be 1
        $manifestPath = Write-TestManifest -Files @() -Trees @([pscustomobject]@{ Path = $existingJunction[0].Name; Include = @('*.ps1') })

        { Get-LanPublicSourceManifest -SourceRoot $env:USERPROFILE -ManifestPath $manifestPath } | Should Throw
    }

    It 'rejects_path_traversal' {
        [IO.File]::WriteAllText((Join-Path $script:scratchRoot 'outside.ps1'), 'safe')
        $manifestPath = Write-TestManifest -Files @('..\outside.ps1')

        { Get-LanPublicSourceManifest -SourceRoot $script:sourceRoot -ManifestPath $manifestPath } | Should Throw
    }

    It 'refuses_nonempty_destination' {
        [IO.File]::WriteAllText((Join-Path $script:sourceRoot 'safe.ps1'), 'safe')
        [IO.Directory]::CreateDirectory($script:destinationRoot) | Out-Null
        $marker = Join-Path $script:destinationRoot 'keep.txt'
        [IO.File]::WriteAllText($marker, 'keep')
        $manifestPath = Write-TestManifest

        { New-LanPublicSourceSnapshot -SourceRoot $script:sourceRoot -DestinationRoot $script:destinationRoot -Version 'test' -ManifestPath $manifestPath } | Should Throw
        [IO.File]::ReadAllText($marker) | Should Be 'keep'
    }
}
