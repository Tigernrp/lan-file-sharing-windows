[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+$')][string]$Version,
    [string]$SignerPattern = '^CN=SignPath Foundation',
    [switch]$RequireTimestamp,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$VerificationAdapterPath
)
$ErrorActionPreference = 'Stop'
$reasons = New-Object 'System.Collections.Generic.List[string]'
$installerFull = [IO.Path]::GetFullPath($InstallerPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$adapter = $null
if (-not [string]::IsNullOrWhiteSpace($VerificationAdapterPath)) {
    try { $adapter = Get-Content -LiteralPath $VerificationAdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $reasons.Add('adapter:invalid') }
}

$outer = $null; $metadata = $null; $audit = $null; $sha256 = ''
if (-not [IO.File]::Exists($installerFull)) {
    $reasons.Add('installer:missing')
} else {
    $sha256 = (Get-FileHash -LiteralPath $installerFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($null -ne $adapter) {
        $outer = $adapter.outerSignature
        $metadata = $adapter.metadata
        $audit = $adapter.audit
    } else {
        $signature = Get-AuthenticodeSignature -LiteralPath $installerFull
        $outer = [pscustomobject]@{
            status = [string]$signature.Status
            signer = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
            timestampPresent = ($null -ne $signature.TimeStamperCertificate)
            timestampValid = ([string]$signature.Status -eq 'Valid' -and $null -ne $signature.TimeStamperCertificate)
        }
        $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($installerFull)
        $metadata = [pscustomobject]@{
            productName=$versionInfo.ProductName; companyName=$versionInfo.CompanyName
            fileVersion=$versionInfo.FileVersion; productVersion=$versionInfo.ProductVersion
            originalFilename=$versionInfo.OriginalFilename
        }
        $auditPath = Join-Path (Split-Path -Parent $outputFull) ('payload-audit-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $audit = & (Join-Path $PSScriptRoot 'Get-ReleaseInventory.ps1') -InstallerPath $installerFull -OutputPath $auditPath
        } catch { $reasons.Add('payload:audit-failed') }
        finally { if ([IO.File]::Exists($auditPath)) { [IO.File]::Delete($auditPath) } }
    }
}

if ($null -ne $outer) {
    if ([string]$outer.status -ne 'Valid') { $reasons.Add('installer:signature-invalid') }
    if ([string]$outer.signer -notmatch $SignerPattern) { $reasons.Add('installer:signer-mismatch') }
    if ($RequireTimestamp -and -not [bool]$outer.timestampPresent) { $reasons.Add('installer:timestamp-missing') }
    if ($RequireTimestamp -and -not [bool]$outer.timestampValid) { $reasons.Add('installer:timestamp-invalid') }
}
if ($null -ne $metadata) {
    if ([string]$metadata.productName -ne 'LAN File Sharing') { $reasons.Add('metadata:product-name') }
    if ([string]$metadata.companyName -ne 'LAN File Sharing contributors') { $reasons.Add('metadata:company-name') }
    if ([string]$metadata.fileVersion -notmatch ('^' + [regex]::Escape($Version) + '(?:\.|$)')) { $reasons.Add('metadata:file-version') }
    if ([string]$metadata.productVersion -notmatch ('^' + [regex]::Escape($Version) + '(?:\.|$)')) { $reasons.Add('metadata:product-version') }
    if ([string]$metadata.originalFilename -notmatch '^LanFileSharing-Setup-v[0-9]+\.[0-9]+\.exe$') { $reasons.Add('metadata:original-filename') }
}
if ($null -ne $audit) {
    if ([string]$audit.version -ne $Version) { $reasons.Add('payload:version') }
    if (-not [bool]$audit.payloadInventoryVerified) { $reasons.Add('payload:inventory') }
    $paths = @{}
    foreach ($file in @($audit.files)) {
        $path = [string]$file.path
        if ([string]::IsNullOrWhiteSpace($path) -or $paths.ContainsKey($path.ToLowerInvariant())) { $reasons.Add('payload:duplicate-or-empty-path'); continue }
        $paths[$path.ToLowerInvariant()] = $true
        if ([string]$file.sha256 -notmatch '^[a-fA-F0-9]{64}$') { $reasons.Add(('payload:hash:{0}' -f $path)) }
        if ($path -match '\.(?:exe|ps1|psm1)$') {
            if (-not [bool]$file.signed -or [string]$file.signatureStatus -ne 'Valid') { $reasons.Add(('payload:signature:{0}' -f $path)); continue }
            if ([string]$file.signer -notmatch $SignerPattern) { $reasons.Add(('payload:signer:{0}' -f $path)) }
            if ($RequireTimestamp -and (-not [bool]$file.timestampPresent -or -not [bool]$file.timestampValid)) { $reasons.Add(('payload:timestamp:{0}' -f $path)) }
        }
    }
}

$publicFiles = @()
if ($null -ne $audit) {
    $publicFiles = @($audit.files | ForEach-Object {
        [ordered]@{
            path=[string]$_.path; sha256=([string]$_.sha256).ToLowerInvariant(); signed=[bool]$_.signed
            signatureStatus=[string]$_.signatureStatus; signer=[string]$_.signer
            timestampPresent=[bool]$_.timestampPresent; timestampValid=[bool]$_.timestampValid
        }
    })
}
$report = [ordered]@{
    schemaVersion=1; version=$Version; passed=($reasons.Count -eq 0); reasons=@($reasons | Sort-Object -Unique)
    installer=[ordered]@{
        fileName=[IO.Path]::GetFileName($installerFull); sha256=$sha256
        signatureStatus=if($outer){[string]$outer.status}else{''}; signer=if($outer){[string]$outer.signer}else{''}
        timestampPresent=if($outer){[bool]$outer.timestampPresent}else{$false}; timestampValid=if($outer){[bool]$outer.timestampValid}else{$false}
        metadata=$metadata
    }
    payload=[ordered]@{ inventoryVerified=if($audit){[bool]$audit.payloadInventoryVerified}else{$false}; files=$publicFiles }
}
$parent = Split-Path -Parent $outputFull
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($outputFull, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
if ($report.passed) { Write-Host 'RELEASE VERIFICATION PASSED'; exit 0 }
Write-Host 'RELEASE VERIFICATION FAILED'
$report.reasons | ForEach-Object { Write-Host ('  ' + $_) }
exit 1
