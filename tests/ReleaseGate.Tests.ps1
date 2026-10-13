$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$gateScript = Join-Path $repoRoot 'tools\Test-ReleaseArtifact.ps1'
$sbomScript = Join-Path $repoRoot 'tools\New-ReleaseSbom.ps1'

Describe 'Signed release verification gate' {
    BeforeEach {
        $script:scratch = Join-Path $repoRoot ('artifacts\release-gate-tests-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:scratch) | Out-Null
        $script:installer = Join-Path $script:scratch 'LanFileSharing-Setup-v3.82.exe'
        [IO.File]::WriteAllBytes($script:installer, [byte[]](77,90,1,2,3,4))
        $script:report = Join-Path $script:scratch 'release-verification.json'
    }
    AfterEach { if ([IO.Directory]::Exists($script:scratch)) { [IO.Directory]::Delete($script:scratch, $true) } }

    function New-ValidAdapter {
        param([hashtable]$Overrides = @{})
        $adapter = [ordered]@{
            outerSignature = [ordered]@{ status='Valid'; signer='CN=SignPath Foundation'; timestampPresent=$true; timestampValid=$true }
            metadata = [ordered]@{ productName='LAN File Sharing'; companyName='LAN File Sharing contributors'; fileVersion='3.82.0.0'; productVersion='3.82'; originalFilename='LanFileSharing-Setup-v3.82.exe' }
            audit = [ordered]@{
                version='3.82'; payloadInventoryVerified=$true
                files=@(
                    [ordered]@{ path='LanFileSharing.exe'; sha256=('a'*64); signed=$true; signatureStatus='Valid'; signer='CN=SignPath Foundation'; timestampPresent=$true; timestampValid=$true },
                    [ordered]@{ path='LanShare.ps1'; sha256=('b'*64); signed=$true; signatureStatus='Valid'; signer='CN=SignPath Foundation'; timestampPresent=$true; timestampValid=$true },
                    [ordered]@{ path='version.txt'; sha256=('c'*64); signed=$false; signatureStatus='NotApplicable'; signer=''; timestampPresent=$false; timestampValid=$false }
                )
            }
            secretValue = 'must-never-appear-in-output'
        }
        foreach ($key in $Overrides.Keys) { $adapter[$key] = $Overrides[$key] }
        $path = Join-Path $script:scratch ('adapter-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, ($adapter | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        return $path
    }

    function Invoke-Gate {
        param([string]$Path = $script:installer, [string]$AdapterPath)
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$gateScript,'-InstallerPath',$Path,'-Version','3.82','-SignerPattern','^CN=SignPath Foundation','-RequireTimestamp','-OutputPath',$script:report)
        if ($AdapterPath) { $arguments += @('-VerificationAdapterPath',$AdapterPath) }
        $output = (& powershell.exe @arguments 2>&1 | Out-String)
        [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=$output }
    }

    It 'rejects an absent installer with a redacted report' {
        $result = Invoke-Gate -Path (Join-Path $script:scratch 'absent.exe') -AdapterPath (New-ValidAdapter)
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Not Match 'must-never-appear'
    }

    It 'rejects unsigned outer wrong signer missing timestamp malformed timestamp and changed version' {
        $badCases = @(
            @{ outerSignature=[ordered]@{status='NotSigned';signer='';timestampPresent=$false;timestampValid=$false} },
            @{ outerSignature=[ordered]@{status='Valid';signer='CN=Wrong Publisher';timestampPresent=$true;timestampValid=$true} },
            @{ outerSignature=[ordered]@{status='Valid';signer='CN=SignPath Foundation';timestampPresent=$false;timestampValid=$false} },
            @{ outerSignature=[ordered]@{status='Valid';signer='CN=SignPath Foundation';timestampPresent=$true;timestampValid=$false} },
            @{ metadata=[ordered]@{productName='LAN File Sharing';companyName='LAN File Sharing contributors';fileVersion='9.99.0.0';productVersion='9.99';originalFilename='LanFileSharing-Setup-v3.82.exe'} }
        )
        foreach ($case in $badCases) {
            $result = Invoke-Gate -AdapterPath (New-ValidAdapter -Overrides $case)
            $result.ExitCode | Should Not Be 0
        }
    }

    It 'rejects payload inventory mismatch and one unsigned inner script' {
        $adapterPath = New-ValidAdapter
        $adapter = Get-Content $adapterPath -Raw | ConvertFrom-Json
        $adapter.audit.payloadInventoryVerified = $false
        [IO.File]::WriteAllText($adapterPath, ($adapter | ConvertTo-Json -Depth 8))
        (Invoke-Gate -AdapterPath $adapterPath).ExitCode | Should Not Be 0

        $adapterPath = New-ValidAdapter
        $adapter = Get-Content $adapterPath -Raw | ConvertFrom-Json
        $adapter.audit.files[1].signed = $false
        $adapter.audit.files[1].signatureStatus = 'NotSigned'
        [IO.File]::WriteAllText($adapterPath, ($adapter | ConvertTo-Json -Depth 8))
        (Invoke-Gate -AdapterPath $adapterPath).ExitCode | Should Not Be 0
    }

    It 'passes a fully valid adapter fixture and writes only public verification fields' {
        $result = Invoke-Gate -AdapterPath (New-ValidAdapter)
        $result.ExitCode | Should Be 0
        $verification = Get-Content -LiteralPath $script:report -Raw | ConvertFrom-Json
        $verification.passed | Should Be $true
        $verification.installer.sha256 | Should Match '^[a-f0-9]{64}$'
        $verification.installer.signer | Should Match 'SignPath Foundation'
        @($verification.payload.files).Count | Should Be 3
        ([IO.File]::ReadAllText($script:report)) | Should Not Match 'must-never-appear'
    }

    It 'generates a valid CycloneDX 1.5 SBOM with NetBird as optional external dependency' {
        $sbom = Join-Path $script:scratch 'sbom.cdx.json'
        & $sbomScript -Root $repoRoot -Version '3.82' -OutputPath $sbom
        $LASTEXITCODE | Should Be 0
        $document = Get-Content -LiteralPath $sbom -Raw | ConvertFrom-Json
        $document.bomFormat | Should Be 'CycloneDX'
        $document.specVersion | Should Be '1.5'
        $document.serialNumber | Should Match '^urn:uuid:'
        $document.metadata.component.licenses[0].license.id | Should Be 'MIT'
        @($document.components | Where-Object { $_.name -eq 'NetBird' -and $_.scope -eq 'optional' }).Count | Should Be 1
        @($document.components | Where-Object { -not $_.name -or -not $_.version }).Count | Should Be 0
    }
}
