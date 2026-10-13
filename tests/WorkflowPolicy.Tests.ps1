$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ciPath = Join-Path $repoRoot '.github\workflows\ci.yml'
$releasePath = Join-Path $repoRoot '.github\workflows\release.yml'
$payloadConfigPath = Join-Path $repoRoot '.signpath\artifact-configurations\payload.xml'
$installerConfigPath = Join-Path $repoRoot '.signpath\artifact-configurations\installer.xml'
$policyPath = Join-Path $repoRoot 'CODE_SIGNING_POLICY.md'

Describe 'GitHub and SignPath workflow policy' {
    It 'runs public validation on Windows for pushes and pull requests without signing secrets' {
        Test-Path -LiteralPath $ciPath | Should Be $true
        $ci = Get-Content -LiteralPath $ciPath -Raw
        $ci | Should Match '(?m)^\s*pull_request\s*:'
        $ci | Should Match '(?m)^\s*push\s*:'
        $ci | Should Match 'runs-on:\s*windows-latest'
        $ci | Should Match '(?ms)permissions:\s*\r?\n\s*contents:\s*read'
        $ci | Should Match 'Test-PublicRepository\.ps1'
        $ci | Should Match 'Check-Encoding\.ps1'
        $ci | Should Match 'Run-Tests\.ps1'
        $ci | Should Match 'Install-Module\s+Pester\s+-RequiredVersion\s+4\.10\.1'
        $ci | Should Match '(?ms)- name:\s*Build and verify development installer\s*\r?\n\s*shell:\s*powershell\s*\r?\n'
        (Get-Content -LiteralPath (Join-Path $repoRoot 'tests\Run-Tests.ps1') -Raw) | Should Match 'Version\.Major\s+-eq\s+4'
        $ci | Should Not Match 'SIGNPATH_API_TOKEN|secrets\.'
        $ci | Should Not Match 'upload-artifact[^\r\n]*\.exe'
    }

    It 'guards exact version tags and preflights every required SignPath setting' {
        Test-Path -LiteralPath $releasePath | Should Be $true
        $release = Get-Content -LiteralPath $releasePath -Raw
        $release | Should Match 'runs-on:\s*windows-latest'
        $release | Should Match 'Install-Module\s+Pester\s+-RequiredVersion\s+4\.10\.1'
        $release | Should Match '\^v\[0-9\]\+\\\.\[0-9\]\+\$'
        foreach ($name in @(
            'SIGNPATH_API_TOKEN',
            'SIGNPATH_ORGANIZATION_ID',
            'SIGNPATH_PROJECT_SLUG',
            'SIGNPATH_PAYLOAD_CONFIGURATION',
            'SIGNPATH_INSTALLER_CONFIGURATION'
        )) {
            $release | Should Match $name
        }
        $release | Should Match 'Required SignPath settings are present'
        foreach ($step in @(
            'Build unsigned payload for SignPath',
            'Verify signed payload and build unsigned installer',
            'Run final signed release gate and prepare public files'
        )) {
            $release | Should Match ('(?ms)- name:\s*' + [regex]::Escape($step) + '\s*\r?\n\s*shell:\s*powershell\s*\r?\n')
        }
    }

    It 'bounds every installer self-check and terminates a timed-out process tree' {
        $module = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\ReleaseBuild.psm1') -Raw
        $entry = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\Build-Release.ps1') -Raw
        foreach ($source in @($module, $entry)) {
            $source | Should Match 'WaitForExit\s*\('
            $source | Should Match 'TimeoutSeconds'
            $source | Should Match 'taskkill\.exe\s+/PID'
            $source | Should Not Match 'Start-Process[^\r\n]+-Wait'
        }
    }

    It 'submits exactly two bounded signing requests and waits for both outputs' {
        $release = Get-Content -LiteralPath $releasePath -Raw
        ([regex]::Matches($release, 'signpath/github-action-submit-signing-request@v3')).Count | Should Be 2
        ([regex]::Matches($release, 'wait-for-completion:\s*["'']?true')).Count | Should Be 2
        ([regex]::Matches($release, 'wait-for-completion-timeout-in-seconds:\s*["'']?1800')).Count | Should Be 2
        $release | Should Match 'output-artifact-directory:\s*artifacts/signed-payload'
        $release | Should Match 'output-artifact-directory:\s*artifacts/signed-installer'
        $release | Should Not Match 'continue-on-error:\s*true'
    }

    It 'runs the final release gate before creating a draft with signed assets only' {
        $release = Get-Content -LiteralPath $releasePath -Raw
        $gateIndex = $release.LastIndexOf('Test-ReleaseArtifact.ps1')
        $publishIndex = $release.IndexOf('gh release create')
        ($gateIndex -ge 0) | Should Be $true
        ($publishIndex -gt $gateIndex) | Should Be $true
        $release | Should Match 'gh release create[^\r\n]*--draft'
        $release | Should Match '(?ms)publish:\s*.*needs:\s*build_sign_verify.*if:\s*\$\{\{\s*success\(\)\s*\}\}'

        $publishBlock = $release.Substring($publishIndex)
        $publishBlock | Should Match 'signed-release'
        $publishBlock | Should Not Match 'unsigned|development-unsigned'
        $release | Should Match 'retention-days:\s*1'
    }

    It 'defines restrictive payload and installer artifact configurations' {
        foreach ($path in @($payloadConfigPath, $installerConfigPath)) {
            Test-Path -LiteralPath $path | Should Be $true
            [xml]$xml = Get-Content -LiteralPath $path -Raw
            $xml.DocumentElement.NamespaceURI | Should Be 'http://signpath.io/artifact-configuration/v1'
            $xml.OuterXml | Should Match 'parameter name="version" required="true"'
            $xml.OuterXml | Should Match 'authenticode-sign'
            $xml.OuterXml | Should Match 'hash-algorithm="sha256"'
        }
        ([xml](Get-Content -LiteralPath $payloadConfigPath -Raw)).OuterXml | Should Match 'powershell-file'
        ([xml](Get-Content -LiteralPath $payloadConfigPath -Raw)).OuterXml | Should Match 'pe-file'
        ([xml](Get-Content -LiteralPath $installerConfigPath -Raw)).OuterXml | Should Match 'original-filename="LanFileSharing-Setup-v\$\{version\}\.exe"'
    }

    It 'documents timeout cancellation and private diagnostic artifact behavior' {
        $policy = Get-Content -LiteralPath $policyPath -Raw
        $policy | Should Match '(?i)timeout'
        $policy | Should Match '(?i)cancel'
        $policy | Should Match '(?i)private.*diagnostic|diagnostic.*private'
        $policy | Should Match '(?i)draft release'
    }
}
