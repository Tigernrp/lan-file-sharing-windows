$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'installer\ReleaseBuild.psm1'
Import-Module $modulePath -Force

Describe 'Two-stage release build' {
    BeforeAll {
        $script:outputRoot = Join-Path $repoRoot ('artifacts\release-build-tests-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:outputRoot) | Out-Null
        $script:payloadPath = New-LanUnsignedPayload -SourceRoot $repoRoot -Version '3.81' -OutputDirectory $script:outputRoot
    }

    AfterAll {
        if ([IO.Directory]::Exists($script:outputRoot)) { [IO.Directory]::Delete($script:outputRoot, $true) }
    }

    It 'stamps consistent launcher metadata' {
        $stage = Expand-LanPayloadArchive -PayloadPath $script:payloadPath -DestinationRoot (Join-Path $script:outputRoot 'metadata')
        try {
            $metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage 'LanFileSharing.exe'))
            $metadata.ProductName | Should Be 'LAN File Sharing'
            $metadata.CompanyName | Should Be 'LAN File Sharing contributors'
            $metadata.FileVersion | Should Match '^3\.81\.'
            $metadata.ProductVersion | Should Match '^3\.81(?:\.|$)'
            $metadata.OriginalFilename | Should Be 'LanFileSharing.exe'
            $metadata.LegalCopyright | Should Match 'LAN File Sharing contributors'
        } finally {
            if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
        }
    }

    It 'creates an exact signing inventory without a final checksum manifest' {
        $inspection = Test-LanPayloadArchive -PayloadPath $script:payloadPath -Version '3.81'
        $inspection.Passed | Should Be $true
        ($inspection.Inventory -contains 'LanFileSharing.exe') | Should Be $true
        ($inspection.Inventory -contains 'LanShare.ps1') | Should Be $true
        ($inspection.Inventory -contains 'src/Ui.ps1') | Should Be $true
        ($inspection.Inventory -contains 'version.txt') | Should Be $true
        ($inspection.Inventory -contains 'payload.inventory.json') | Should Be $true
        ($inspection.Inventory -contains 'manifest.sha256') | Should Be $false
    }

    It 'rejects wrong versions and unsigned signed-stage input' {
        (Test-LanPayloadArchive -PayloadPath $script:payloadPath -Version '9.99').Passed | Should Be $false
        (Test-LanSignedPayload -PayloadPath $script:payloadPath -Version '3.81' -ExpectedSignerPattern 'SignPath Foundation' -RequireTimestamp $true).Passed | Should Be $false
    }

    It 'rejects missing extra duplicate traversal and changed-hash archive entries' {
        foreach ($case in @('missing','extra','duplicate','traversal','changed-hash')) {
            $bad = New-TestPayloadMutation -PayloadPath $script:payloadPath -OutputPath (Join-Path $script:outputRoot ($case + '.zip')) -Mutation $case
            (Test-LanPayloadArchive -PayloadPath $bad -Version '3.81').Passed | Should Be $false
        }
    }

    It 'rejects invalid signer and missing timestamp independently' {
        Mock Get-AuthenticodeSignature -ModuleName ReleaseBuild {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Unexpected Publisher' }; TimeStamperCertificate = [pscustomobject]@{ Subject = 'CN=Timestamp' } }
        }
        (Test-LanSignedPayload -PayloadPath $script:payloadPath -Version '3.81' -ExpectedSignerPattern 'SignPath Foundation' -RequireTimestamp $true).Passed | Should Be $false

        Mock Get-AuthenticodeSignature -ModuleName ReleaseBuild {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=SignPath Foundation' }; TimeStamperCertificate = $null }
        }
        (Test-LanSignedPayload -PayloadPath $script:payloadPath -Version '3.81' -ExpectedSignerPattern 'SignPath Foundation' -RequireTimestamp $true).Passed | Should Be $false
    }

    It 'builds an explicitly labelled unsigned development installer with safe audit mode' {
        $installer = New-LanInstallerFromPayload -PayloadPath $script:payloadPath -Version '3.81' -OutputDirectory $script:outputRoot -RequireSignedPayload $false
        [IO.Path]::GetFileName($installer) | Should Match 'UNSIGNED-DEVELOPMENT'

        $verify = Join-Path $script:outputRoot 'verify.txt'
        $process = Start-Process -FilePath $installer -ArgumentList ('--verify "' + $verify + '"') -Wait -PassThru -WindowStyle Hidden
        $process.ExitCode | Should Be 0
        [IO.File]::ReadAllText($verify) | Should Match '^OK files=\d+'

        $audit = Join-Path $script:outputRoot 'audit.json'
        $process = Start-Process -FilePath $installer -ArgumentList ('--audit "' + $audit + '"') -Wait -PassThru -WindowStyle Hidden
        $process.ExitCode | Should Be 0
        $report = Get-Content -LiteralPath $audit -Raw | ConvertFrom-Json
        $report.version | Should Be '3.81'
        @($report.files).Count | Should BeGreaterThan 5
        @($report.files | Where-Object { $_.path -match '\.ps1$' }).Count | Should BeGreaterThan 0

        $relativeReport = 'relative-audit.json'
        $process = Start-Process -FilePath $installer -ArgumentList ('--audit "' + $relativeReport + '"') -Wait -PassThru -WindowStyle Hidden -WorkingDirectory $script:outputRoot
        $process.ExitCode | Should Not Be 0
        Test-Path -LiteralPath (Join-Path $script:outputRoot $relativeReport) | Should Be $false
        @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'LanFileSharing-*audit*' -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'refuses a normal release installer from unsigned payload input' {
        { New-LanInstallerFromPayload -PayloadPath $script:payloadPath -Version '3.81' -OutputDirectory $script:outputRoot -RequireSignedPayload $true } | Should Throw
    }
}
