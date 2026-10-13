Describe 'client installer' {
    It 'installs the launcher and client code for the current user without deleting other files' {
        $root = Split-Path -Parent $PSScriptRoot
        $destination = Join-Path $TestDrive 'client app'
        $installer = Join-Path $root 'Install-LanClient.ps1'
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        & $shell -NoProfile -ExecutionPolicy Bypass -File $installer -InstallRoot $destination | Out-Null
        $LASTEXITCODE | Should Be 0
        Test-Path -LiteralPath (Join-Path $destination 'Start-LanShare.cmd') | Should Be $true
        Test-Path -LiteralPath (Join-Path $destination 'LanShare.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $destination 'src\ClientMap.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $destination 'Diagnose-LanClient.cmd') | Should Be $true

        Set-Content -LiteralPath (Join-Path $destination 'personal-note.txt') -Value 'keep'
        & $shell -NoProfile -ExecutionPolicy Bypass -File $installer -InstallRoot $destination | Out-Null
        $LASTEXITCODE | Should Be 0
        Get-Content -LiteralPath (Join-Path $destination 'personal-note.txt') | Should Be 'keep'
    }
}
