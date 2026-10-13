Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Assert-LanReleaseVersion {
    param([Parameter(Mandatory = $true)][string]$Version)
    if ($Version -notmatch '^[0-9]+\.[0-9]+$') { throw 'Release version must use major.minor digits.' }
}

function Get-LanSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-LanArchiveName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or $Name.Contains('\') -or
        $Name.Contains(':') -or $Name.EndsWith('/')) { return $false }
    foreach ($part in $Name.Split('/')) { if ($part -eq '' -or $part -eq '.' -or $part -eq '..') { return $false } }
    return $true
}

function Get-LanCompilerPath {
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    if (-not [IO.File]::Exists($compiler)) { throw 'The .NET Framework C# compiler was not found.' }
    return $compiler
}

function New-LanAssemblyInfoFile {
    param([string]$Directory, [string]$Version)
    $path = Join-Path $Directory 'AssemblyInfo.cs'
    $fourPart = $Version + '.0.0'
    $text = @"
using System.Reflection;
[assembly: AssemblyTitle("LAN File Sharing")]
[assembly: AssemblyProduct("LAN File Sharing")]
[assembly: AssemblyCompany("LAN File Sharing contributors")]
[assembly: AssemblyCopyright("Copyright (c) 2026 LAN File Sharing contributors")]
[assembly: AssemblyVersion("$fourPart")]
[assembly: AssemblyFileVersion("$fourPart")]
[assembly: AssemblyInformationalVersion("$Version")]
"@
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    return $path
}

function Write-LanZipFromItems {
    param([string]$Path, [object[]]$Items)
    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($item in @($Items | Sort-Object Name)) {
                if (-not (Test-LanArchiveName -Name ([string]$item.Name))) { throw 'Invalid archive item name.' }
                $entry = $zip.CreateEntry([string]$item.Name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $output = $entry.Open()
                try { $bytes = [byte[]]$item.Bytes; $output.Write($bytes, 0, $bytes.Length) }
                finally { $output.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-LanZipItems {
    param([Parameter(Mandatory = $true)][string]$PayloadPath)
    if (-not [IO.File]::Exists($PayloadPath)) { throw 'Payload archive is missing.' }
    $items = New-Object 'System.Collections.Generic.List[object]'
    $names = @{}
    $stream = [IO.File]::OpenRead($PayloadPath)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach ($entry in $zip.Entries) {
                if (-not (Test-LanArchiveName -Name $entry.FullName)) { throw 'Payload archive contains an unsafe path.' }
                $key = $entry.FullName.ToLowerInvariant()
                if ($names.ContainsKey($key)) { throw 'Payload archive contains a duplicate entry.' }
                $names[$key] = $true
                $memory = New-Object IO.MemoryStream
                $input = $entry.Open()
                try { $input.CopyTo($memory) } finally { $input.Dispose() }
                $items.Add([pscustomobject]@{ Name = $entry.FullName; Bytes = $memory.ToArray() })
                $memory.Dispose()
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    return $items.ToArray()
}

function Test-LanPayloadArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$AllowSignedChanges
    )
    $findings = New-Object 'System.Collections.Generic.List[string]'
    $inventory = @()
    try {
        Assert-LanReleaseVersion $Version
        $items = @(Get-LanZipItems -PayloadPath $PayloadPath)
        $lookup = @{}
        foreach ($item in $items) { $lookup[$item.Name.ToLowerInvariant()] = $item }
        if (-not $lookup.ContainsKey('payload.inventory.json')) { throw 'Payload inventory is missing.' }
        try { $declaration = [Text.Encoding]::UTF8.GetString($lookup['payload.inventory.json'].Bytes) | ConvertFrom-Json }
        catch { throw 'Payload inventory is invalid JSON.' }
        if ([string]$declaration.version -ne $Version) { throw 'Payload inventory version is wrong.' }
        $declared = @($declaration.files)
        $expectedNames = @($declared | ForEach-Object { [string]$_.path }) + @('payload.inventory.json')
        if (@($expectedNames | Sort-Object -Unique).Count -ne $expectedNames.Count) { throw 'Payload inventory contains duplicate names.' }
        foreach ($name in $expectedNames) {
            if (-not (Test-LanArchiveName $name)) { throw 'Payload inventory contains an unsafe path.' }
            if (-not $lookup.ContainsKey($name.ToLowerInvariant())) { $findings.Add(('missing:{0}' -f $name)) }
        }
        foreach ($item in $items) {
            if ($expectedNames -notcontains $item.Name) { $findings.Add(('extra:{0}' -f $item.Name)) }
        }
        foreach ($file in $declared) {
            $name = [string]$file.path
            if (-not $lookup.ContainsKey($name.ToLowerInvariant())) { continue }
            $signable = [bool]$file.signable
            if (-not $AllowSignedChanges -or -not $signable) {
                $actualHash = Get-LanSha256 $lookup[$name.ToLowerInvariant()].Bytes
                if ($actualHash -ne [string]$file.unsignedSha256) { $findings.Add(('hash:{0}' -f $name)) }
            }
        }
        if ($lookup.ContainsKey('version.txt')) {
            if ([Text.Encoding]::UTF8.GetString($lookup['version.txt'].Bytes).Trim() -ne $Version) { $findings.Add('version:version.txt') }
        } else { $findings.Add('missing:version.txt') }
        $inventory = @($items | ForEach-Object { $_.Name } | Sort-Object)
    } catch {
        $findings.Add(('archive:{0}' -f $_.Exception.Message))
    }
    return [pscustomobject]@{ Passed = ($findings.Count -eq 0); Findings = $findings.ToArray(); Inventory = $inventory }
}

function Expand-LanPayloadArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PayloadPath, [Parameter(Mandatory = $true)][string]$DestinationRoot)
    $destination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
    if ([IO.Directory]::Exists($destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) { throw 'Extraction destination must be empty.' }
    if (-not [IO.Directory]::Exists($destination)) { [IO.Directory]::CreateDirectory($destination) | Out-Null }
    try {
        foreach ($item in @(Get-LanZipItems -PayloadPath $PayloadPath)) {
            $target = [IO.Path]::GetFullPath((Join-Path $destination $item.Name.Replace('/', '\')))
            if (-not $target.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Payload path escapes extraction root.' }
            $parent = Split-Path -Parent $target
            if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
            [IO.File]::WriteAllBytes($target, [byte[]]$item.Bytes)
        }
        return $destination
    } catch {
        if ([IO.Directory]::Exists($destination)) { [IO.Directory]::Delete($destination, $true) }
        throw
    }
}

function New-LanUnsignedPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot, [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$OutputDirectory)
    Assert-LanReleaseVersion $Version
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $stage = Join-Path $output ('.payload-stage-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $compiler = Get-LanCompilerPath
        $launcher = Join-Path $stage 'LanFileSharing.exe'
        $assemblyInfo = New-LanAssemblyInfoFile -Directory $stage -Version $Version
        & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 "/out:$launcher" "/win32icon:$(Join-Path $root 'icon\Tiger_Tech_Share_File.ico')" /reference:System.Windows.Forms.dll (Join-Path $root 'installer\Launcher.cs') $assemblyInfo
        if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($launcher)) { throw 'Compiling LanFileSharing.exe failed.' }
        $sources = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in @('.ps1', '.cmd') })) { $sources.Add([pscustomobject]@{ Source=$file.FullName; Name=$file.Name }) }
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File -Filter '*.ps1')) { $sources.Add([pscustomobject]@{ Source=$file.FullName; Name=('src/' + $file.Name) }) }
        $sources.Add([pscustomobject]@{ Source=$launcher; Name='LanFileSharing.exe' })
        $sources.Add([pscustomobject]@{ Source=(Join-Path $root 'icon\Tiger_Tech_Share_File.ico'); Name='icon/Tiger_Tech_Share_File.ico' })
        $sources.Add([pscustomobject]@{ Source=(Join-Path $root 'icon\Tiger_Tech_Share_File.png'); Name='icon/Tiger_Tech_Share_File.png' })
        $versionBytes = [Text.Encoding]::UTF8.GetBytes($Version)
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($source in @($sources | Sort-Object Name)) {
            $bytes = [IO.File]::ReadAllBytes([string]$source.Source)
            $items.Add([pscustomobject]@{ Name=[string]$source.Name; Bytes=$bytes })
        }
        $items.Add([pscustomobject]@{ Name='version.txt'; Bytes=$versionBytes })
        $inventoryFiles = @($items | Sort-Object Name | ForEach-Object {
            [ordered]@{ path=$_.Name; unsignedSha256=(Get-LanSha256 $_.Bytes); signable=($_.Name -match '\.(?:exe|ps1|psm1)$') }
        })
        $inventoryJson = [ordered]@{ version=$Version; files=$inventoryFiles } | ConvertTo-Json -Depth 6
        $items.Add([pscustomobject]@{ Name='payload.inventory.json'; Bytes=[Text.Encoding]::UTF8.GetBytes($inventoryJson) })
        $path = Join-Path $output ('payload-signing-v' + $Version + '.zip')
        Write-LanZipFromItems -Path $path -Items $items.ToArray()
        $check = Test-LanPayloadArchive -PayloadPath $path -Version $Version
        if (-not $check.Passed) { throw ('Unsigned payload validation failed: ' + ($check.Findings -join ', ')) }
        return $path
    } finally {
        if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
    }
}

function Test-LanSignedPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PayloadPath, [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$ExpectedSignerPattern, [bool]$RequireTimestamp = $true)
    $inspection = Test-LanPayloadArchive -PayloadPath $PayloadPath -Version $Version -AllowSignedChanges
    $findings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($finding in @($inspection.Findings)) { $findings.Add([string]$finding) }
    if ($inspection.Passed) {
        $temporary = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($PayloadPath))) ('.signature-audit-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-LanPayloadArchive -PayloadPath $PayloadPath -DestinationRoot $temporary | Out-Null
            foreach ($relative in @($inspection.Inventory | Where-Object { $_ -match '\.(?:exe|ps1|psm1)$' })) {
                $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $temporary $relative.Replace('/', '\'))
                if ([string]$signature.Status -ne 'Valid') { $findings.Add(('signature:{0}:invalid' -f $relative)); continue }
                if ($null -eq $signature.SignerCertificate -or [string]$signature.SignerCertificate.Subject -notmatch $ExpectedSignerPattern) { $findings.Add(('signature:{0}:signer' -f $relative)) }
                if ($RequireTimestamp -and $null -eq $signature.TimeStamperCertificate) { $findings.Add(('signature:{0}:timestamp' -f $relative)) }
            }
        } finally { if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) } }
    }
    return [pscustomobject]@{ Passed=($findings.Count -eq 0); Findings=$findings.ToArray(); Inventory=$inspection.Inventory }
}

function New-LanFinalPayload {
    param([string]$PayloadPath, [string]$Version, [string]$OutputPath, [bool]$RequireSignedPayload, [string]$ExpectedSignerPattern)
    $check = if ($RequireSignedPayload) { Test-LanSignedPayload -PayloadPath $PayloadPath -Version $Version -ExpectedSignerPattern $ExpectedSignerPattern -RequireTimestamp $true }
             else { Test-LanPayloadArchive -PayloadPath $PayloadPath -Version $Version }
    if (-not $check.Passed) { throw ('Payload validation failed: ' + ($check.Findings -join ', ')) }
    $items = New-Object 'System.Collections.Generic.List[object]'
    $manifest = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-LanZipItems -PayloadPath $PayloadPath | Sort-Object Name)) {
        $items.Add($item)
        $manifest.Add((Get-LanSha256 $item.Bytes) + '  ' + $item.Name)
    }
    $items.Add([pscustomobject]@{ Name='manifest.sha256'; Bytes=[Text.Encoding]::UTF8.GetBytes(($manifest -join "`n") + "`n") })
    Write-LanZipFromItems -Path $OutputPath -Items $items.ToArray()
    return $OutputPath
}

function Invoke-LanInstallerCheck {
    param(
        [string]$Installer,
        [string]$Argument,
        [string]$Report,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    $process = Start-Process -FilePath $Installer -ArgumentList ($Argument + ' "' + $Report + '"') -PassThru -WindowStyle Hidden
    $null = $process.Handle
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            throw ('Installer check timed out after {0}s: {1}' -f $TimeoutSeconds, $Argument)
        }
        $process.Refresh()
        if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($Report)) { throw ('Installer check failed: ' + $Argument) }
    } finally {
        $process.Dispose()
    }
}

function New-LanInstallerFromPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][bool]$RequireSignedPayload,
        [string]$ExpectedSignerPattern = 'SignPath Foundation'
    )
    Assert-LanReleaseVersion $Version
    $root = Split-Path -Parent $PSScriptRoot
    $output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $stage = Join-Path $output ('.installer-stage-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $embedded = New-LanFinalPayload -PayloadPath $PayloadPath -Version $Version -OutputPath (Join-Path $stage 'payload.zip') -RequireSignedPayload $RequireSignedPayload -ExpectedSignerPattern $ExpectedSignerPattern
        $engineSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'InstallEngine.cs'))
        if ($engineSource.IndexOf('"@VERSION@"', [StringComparison]::Ordinal) -lt 0) { throw 'InstallEngine version placeholder is missing.' }
        $engineStamped = Join-Path $stage 'InstallEngine.cs'
        [IO.File]::WriteAllText($engineStamped, $engineSource.Replace('"@VERSION@"', '"' + $Version + '"'), [Text.UTF8Encoding]::new($false))
        $assemblyInfo = New-LanAssemblyInfoFile -Directory $stage -Version $Version
        $name = if ($RequireSignedPayload) { 'LanFileSharing-Setup-v' + $Version + '.exe' } else { 'LanFileSharing-Setup-v' + $Version + '-UNSIGNED-DEVELOPMENT.exe' }
        $installer = Join-Path $output $name
        $compiler = Get-LanCompilerPath
        & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 "/out:$installer" "/win32icon:$(Join-Path $root 'icon\Tiger_Tech_Share_File.ico')" "/resource:$embedded,LanFileSharing.Payload.zip" "/resource:$(Join-Path $root 'icon\Tiger_Tech_Share_File.png'),LanFileSharing.Brand.png" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll /reference:System.Core.dll (Join-Path $PSScriptRoot 'SetupForm.cs') $engineStamped $assemblyInfo
        if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($installer)) { throw 'Compiling the setup executable failed.' }
        $verify = Join-Path $stage 'verify.txt'; Invoke-LanInstallerCheck $installer '--verify' $verify
        if ([IO.File]::ReadAllText($verify) -notmatch '^OK files=\d+') { throw 'Installer verification report is invalid.' }
        $inspect = Join-Path $stage 'inspect.txt'; Invoke-LanInstallerCheck $installer '--inspect' $inspect
        $audit = Join-Path $stage 'audit.json'; Invoke-LanInstallerCheck $installer '--audit' $audit
        return $installer
    } finally { if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) } }
}

function New-TestPayloadMutation {
    [CmdletBinding()]
    param([string]$PayloadPath, [string]$OutputPath, [ValidateSet('missing','extra','duplicate','traversal','changed-hash')][string]$Mutation)
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @(Get-LanZipItems $PayloadPath)) { $items.Add($item) }
    switch ($Mutation) {
        'missing' { $victim = @($items | Where-Object { $_.Name -ne 'payload.inventory.json' })[0]; $items.Remove($victim) | Out-Null }
        'extra' { $items.Add([pscustomobject]@{Name='unexpected.txt';Bytes=[Text.Encoding]::UTF8.GetBytes('extra')}) }
        'traversal' {
            $items.Add([pscustomobject]@{Name='../escape.txt';Bytes=[Text.Encoding]::UTF8.GetBytes('escape')})
            if ([IO.File]::Exists($OutputPath)) { [IO.File]::Delete($OutputPath) }
            $stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try { $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true); try { foreach($item in $items.ToArray()){ $entry=$zip.CreateEntry($item.Name); $s=$entry.Open(); try{$s.Write($item.Bytes,0,$item.Bytes.Length)}finally{$s.Dispose()} } }finally{$zip.Dispose()} }finally{$stream.Dispose()}
            return $OutputPath
        }
        'changed-hash' { $victim = @($items | Where-Object { $_.Name -eq 'LanShare.ps1' })[0]; $victim.Bytes = [Text.Encoding]::UTF8.GetBytes('changed') }
        'duplicate' {
            $duplicate = @($items | Where-Object { $_.Name -ne 'payload.inventory.json' })[0]
            $duplicateItems = @($items.ToArray()) + @($duplicate)
            if ([IO.File]::Exists($OutputPath)) { [IO.File]::Delete($OutputPath) }
            $stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try { $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true); try { foreach($item in $duplicateItems){ $entry=$zip.CreateEntry($item.Name); $s=$entry.Open(); try{$s.Write($item.Bytes,0,$item.Bytes.Length)}finally{$s.Dispose()} } }finally{$zip.Dispose()} }finally{$stream.Dispose()}
            return $OutputPath
        }
    }
    Write-LanZipFromItems -Path $OutputPath -Items $items.ToArray()
    return $OutputPath
}

Export-ModuleMember -Function Assert-LanReleaseVersion, New-LanUnsignedPayload, Test-LanPayloadArchive, Expand-LanPayloadArchive, Test-LanSignedPayload, New-LanInstallerFromPayload, New-TestPayloadMutation
