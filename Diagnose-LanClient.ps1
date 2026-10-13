$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
try {
    . (Join-Path $root 'src/Auth.ps1')
    . (Join-Path $root 'src/ClientMap.ps1')
    $unc = '\\SCHOOL-HOST\Laptop'
    $adapter = New-LanClientAdapter
    $blankAccount = & $adapter.GetBlankPasswordAccount
    $credential = Resolve-LanClientCredentials -Root $unc -AuthMode WindowsCurrent -Adapter $adapter
    $existing = & $adapter.GetSession $unc
    Write-Host "Windows user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "Blank-password account detected: $(if ($blankAccount) { $blankAccount } else { '<none>' })"
    Write-Host "Program would use: $(if ($credential) { $credential.UserName } else { '<Windows default>' })"
    Write-Host "Existing SMB connection user: $(if ($existing) { $existing } else { '<none>' })"
    try {
        $null = Get-Item -LiteralPath $unc -ErrorAction Stop
        Write-Host 'Share root access: OK'
    } catch {
        Write-Host "Share root access: $($_.Exception.Message)"
    }
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $clientBytes = [IO.File]::ReadAllBytes((Join-Path $root 'src/ClientMap.ps1'))
        $hash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($clientBytes)).Replace('-', '')
    } finally {
        $hashAlgorithm.Dispose()
    }
    Write-Host "Program file SHA256: $hash"
} catch {
    Write-Host "Diagnostic error: $($_.Exception.Message)"
    exit 1
}
