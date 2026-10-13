param([switch]$VerifyOnly)
$ErrorActionPreference='Stop'
$version='3.81'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$release=Join-Path $root 'release'
$setup=Join-Path $release "LanFileSharing-Setup-v$version.exe"
$icon=Join-Path $root 'icon/Tiger_Tech_Share_File.ico'
$logo=Join-Path $root 'icon/Tiger_Tech_Share_File.png'
foreach($asset in @($icon,$logo)) {
    if (-not [IO.File]::Exists($asset)) { throw "Brand asset is missing: $asset" }
}
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'The .NET Framework C# compiler was not found on this build machine.' }
[IO.Directory]::CreateDirectory($release) | Out-Null
if ($VerifyOnly) {
    if (-not [IO.File]::Exists($setup)) { throw 'Release setup EXE is missing.' }
    $report=Join-Path $release ('verify-'+[guid]::NewGuid().ToString('N')+'.txt')
    try {
        $process=Start-Process -FilePath $setup -ArgumentList ('--verify "'+$report+'"') -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($report) -or
            -not ([IO.File]::ReadAllText($report) -match '^OK files=\d+')) { throw 'Embedded release verification failed.' }
        Write-Output ([IO.File]::ReadAllText($report))
    } finally { if ([IO.File]::Exists($report)) { [IO.File]::Delete($report) } }
    exit 0
}
$stage=Join-Path $release ('build-temp-'+[guid]::NewGuid().ToString('N'))
if ([IO.Directory]::Exists($stage)) { throw 'Build staging path already exists.' }
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    $launcher=Join-Path $stage 'LanFileSharing.exe'
    $launcherSource=Join-Path $PSScriptRoot 'Launcher.cs'
    & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 "/out:$launcher" "/win32icon:$icon" /reference:System.Windows.Forms.dll $launcherSource
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($launcher)) { throw 'Compiling the installed launcher failed.' }

    Add-Type -AssemblyName System.IO.Compression
    $payload=Join-Path $stage 'payload.zip'
    $files=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in @('.ps1','.cmd') })) {
        $files.Add([pscustomobject]@{Source=$file.FullName;Name=$file.Name})
    }
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File -Filter '*.ps1')) {
        $files.Add([pscustomobject]@{Source=$file.FullName;Name=('src/'+$file.Name)})
    }
    $files.Add([pscustomobject]@{Source=$launcher;Name='LanFileSharing.exe'})
    $files.Add([pscustomobject]@{Source=$icon;Name='icon/Tiger_Tech_Share_File.ico'})
    $files.Add([pscustomobject]@{Source=$logo;Name='icon/Tiger_Tech_Share_File.png'})
    # The version the window shows in its title bar. Written from the same $version the setup window and the
    # release file name use, so all three always agree — which is the point of showing it at all.
    $versionFile=Join-Path $stage 'version.txt'
    [IO.File]::WriteAllText($versionFile,$version,(New-Object Text.UTF8Encoding($false)))
    $files.Add([pscustomobject]@{Source=$versionFile;Name='version.txt'})
    $manifestLines=New-Object 'System.Collections.Generic.List[string]'
    $stream=[IO.File]::Open($payload,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            foreach($item in @($files | Sort-Object Name)) {
                $bytes=[IO.File]::ReadAllBytes([string]$item.Source)
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
                finally { $sha.Dispose() }
                $manifestLines.Add($hash+'  '+[string]$item.Name)
                $entry=$zip.CreateEntry([string]$item.Name,[IO.Compression.CompressionLevel]::Optimal)
                $entryStream=$entry.Open()
                try { $entryStream.Write($bytes,0,$bytes.Length) } finally { $entryStream.Dispose() }
            }
            $manifest=[Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n")+"`n")
            $entry=$zip.CreateEntry('manifest.sha256',[IO.Compression.CompressionLevel]::Optimal)
            $entryStream=$entry.Open()
            try { $entryStream.Write($manifest,0,$manifest.Length) } finally { $entryStream.Dispose() }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }

    $setupTemp=Join-Path $stage "LanFileSharing-Setup-v$version.exe"
    $setupSource=Join-Path $PSScriptRoot 'SetupForm.cs'
    $engineSource=Join-Path $PSScriptRoot 'InstallEngine.cs'
    # The version is stamped into the compiled engine so the setup window, the Installed Apps
    # entry and the release file name can never disagree.
    $engineStamped=Join-Path $stage 'InstallEngine.cs'
    $engineText=[IO.File]::ReadAllText($engineSource)
    $placeholder='"@VERSION@"'
    if ($engineText.IndexOf($placeholder,[StringComparison]::Ordinal) -lt 0) { throw 'InstallEngine.cs no longer has the version placeholder.' }
    $engineText=$engineText.Replace($placeholder,'"'+$version+'"')
    [IO.File]::WriteAllText($engineStamped,$engineText,(New-Object Text.UTF8Encoding($false)))
    & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 "/out:$setupTemp" "/win32icon:$icon" "/resource:$payload,LanFileSharing.Payload.zip" "/resource:$logo,LanFileSharing.Brand.png" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll /reference:System.Core.dll $setupSource $engineStamped
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($setupTemp)) { throw 'Compiling the one-file setup EXE failed.' }
    if ([IO.File]::ReadAllText($engineStamped).IndexOf($placeholder,[StringComparison]::Ordinal) -ge 0) { throw 'The compiled engine kept the version placeholder.' }
    $report=Join-Path $stage 'verified.txt'
    $process=Start-Process -FilePath $setupTemp -ArgumentList ('--verify "'+$report+'"') -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($report) -or
        -not ([IO.File]::ReadAllText($report) -match '^OK files=\d+')) { throw 'The compiled EXE did not verify its embedded payload.' }
    Copy-Item -LiteralPath $setupTemp -Destination $setup -Force -ErrorAction Stop
    $hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $release 'SHA256.txt'),$hash+"  LanFileSharing-Setup-v$version.exe`r`n",(New-Object Text.UTF8Encoding($false)))
    Write-Output "Built $setup"
    Write-Output "SHA256 $hash"
} finally {
    $full=[IO.Path]::GetFullPath($stage).TrimEnd('\')
    $expected=[IO.Path]::GetFullPath($release).TrimEnd('\')
    if ([string]::Equals([IO.Path]::GetDirectoryName($full),$expected,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('build-temp-') -and [IO.Directory]::Exists($full)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}
