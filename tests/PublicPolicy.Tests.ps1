$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Public repository policy and disclosure' {
    It 'contains all required policy files' {
        $required = @(
            'LICENSE',
            'PRIVACY.md',
            'SECURITY.md',
            'CONTRIBUTING.md',
            'CODE_SIGNING_POLICY.md',
            'THIRD_PARTY_NOTICES.md'
        )
        foreach ($relative in $required) {
            Test-Path -LiteralPath (Join-Path $repoRoot $relative) -PathType Leaf | Should Be $true
        }
    }

    It 'uses the MIT license owned by LAN File Sharing contributors' {
        $license = Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE') -Raw
        $license | Should Match 'MIT License'
        $license | Should Match 'LAN File Sharing contributors'
        $license | Should Match 'Permission is hereby granted, free of charge'
    }

    It 'documents privacy and explicit NetBird network behavior' {
        $privacy = Get-Content -LiteralPath (Join-Path $repoRoot 'PRIVACY.md') -Raw
        $privacy | Should Match '(?i)no telemetry'
        $privacy | Should Match '(?i)NetBird'
        $privacy | Should Match '(?i)explicit user action'
        $privacy | Should Match '(?i)installation|sign-in|connection|status'
    }

    It 'documents administrative changes and complete removal' {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $readme | Should Match '(?i)administrator|administrative'
        $readme | Should Match '(?i)local account'
        $readme | Should Match '(?i)SMB'
        $readme | Should Match '(?i)Windows Firewall'
        $readme | Should Match '(?i)startup'
        $readme | Should Match '(?i)uninstall|remove'
    }

    It 'provides a private security reporting route and forbids credentials in issues' {
        $security = Get-Content -LiteralPath (Join-Path $repoRoot 'SECURITY.md') -Raw
        $security | Should Match '(?i)private vulnerability reporting'
        $security | Should Match '(?i)do not.*credentials.*issues|never.*credentials.*issues'
    }

    It 'states the SignPath acknowledgement and release governance' {
        $policy = Get-Content -LiteralPath (Join-Path $repoRoot 'CODE_SIGNING_POLICY.md') -Raw
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $requiredAcknowledgement = 'Free code signing provided by SignPath.io, certificate by SignPath Foundation'
        $policy | Should Match ([regex]::Escape($requiredAcknowledgement))
        $readme | Should Match ([regex]::Escape($requiredAcknowledgement))
        $policy | Should Match '(?i)multi-factor authentication|MFA'
        $policy | Should Match '(?i)author'
        $policy | Should Match '(?i)reviewer'
        $policy | Should Match '(?i)approver'
    }

    It 'documents third-party components without changing their licenses' {
        $notices = Get-Content -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Raw
        $notices | Should Match '(?i)NetBird'
        $notices | Should Match '(?i)original license'
    }
}
