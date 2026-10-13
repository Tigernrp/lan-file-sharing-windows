[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+$')][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
if (-not [IO.Directory]::Exists($rootFull)) { throw 'SBOM source root is missing.' }
if (-not [IO.File]::Exists((Join-Path $rootFull 'THIRD_PARTY_NOTICES.md'))) { throw 'Third-party notices are missing.' }
$relativeFiles = if ([IO.Directory]::Exists((Join-Path $rootFull '.git'))) {
    @(& git -C $rootFull ls-files)
} else {
    @(Get-ChildItem -LiteralPath $rootFull -File -Recurse | ForEach-Object { $_.FullName.Substring($rootFull.Length + 1).Replace('\','/') })
}
if ($LASTEXITCODE -ne 0) { throw 'Unable to read source inventory for the SBOM.' }
$components = New-Object 'System.Collections.Generic.List[object]'
foreach ($relative in @($relativeFiles | Sort-Object -Unique)) {
    $path = Join-Path $rootFull $relative.Replace('/', '\')
    if (-not [IO.File]::Exists($path)) { throw 'SBOM inventory references a missing file.' }
    if ([IO.Path]::GetExtension($path) -in @('.exe','.dll','.msi','.zip','.rar','.7z')) { throw 'Undocumented bundled binary or archive is not allowed in source inventory.' }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $components.Add([ordered]@{
        type='file'; 'bom-ref'=('source:' + $relative); name=$relative; version=$Version
        hashes=@([ordered]@{alg='SHA-256';content=$hash})
        licenses=@([ordered]@{license=[ordered]@{id='MIT'}})
    })
}
$components.Add([ordered]@{
    type='application'; 'bom-ref'='external:netbird'; name='NetBird'; version='external-current'; scope='optional'
    description='Optional external network client downloaded from its official source after explicit user action.'
    externalReferences=@([ordered]@{type='website';url='https://netbird.io/'})
})
$document = [ordered]@{
    '$schema'='https://cyclonedx.org/schema/bom-1.5.schema.json'
    bomFormat='CycloneDX'; specVersion='1.5'; serialNumber=('urn:uuid:' + [guid]::NewGuid().ToString()); version=1
    metadata=[ordered]@{
        timestamp=[DateTime]::UtcNow.ToString('o')
        component=[ordered]@{type='application';'bom-ref'='pkg:generic/lan-file-sharing@'+$Version;name='LAN File Sharing';version=$Version;licenses=@([ordered]@{license=[ordered]@{id='MIT'}})}
    }
    components=$components.ToArray()
}
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $outputFull
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($outputFull, ($document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
Write-Output $outputFull
