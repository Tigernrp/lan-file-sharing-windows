Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
# Loaded in the same order the window loads them. Ui.ps1 calls into the layers below it — Get-LanVersionSuffix
# lives in Selection.ps1 and the mapping helpers live in ClientMap.ps1 — so sourcing Ui.ps1 first left those
# undefined and two tests failed for a reason that had nothing to do with icons.
. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/ClientMap.ps1"
. "$PSScriptRoot/../src/InstallLocation.ps1"
. "$PSScriptRoot/../src/Startup.ps1"
. "$PSScriptRoot/../src/HostBridge.ps1"
. "$PSScriptRoot/../src/UserStartup.ps1"
. "$PSScriptRoot/../src/Ui.ps1"

function Test-IconPixelsEqual {
    param([Parameter(Mandatory)][Drawing.Icon]$Actual,[Parameter(Mandatory)][Drawing.Icon]$Expected)
    $actualBitmap=$Actual.ToBitmap()
    $expectedBitmap=$Expected.ToBitmap()
    try {
        if ($actualBitmap.Width -ne $expectedBitmap.Width -or $actualBitmap.Height -ne $expectedBitmap.Height) { return $false }
        $compared=0
        $different=0
        for($y=0;$y -lt $actualBitmap.Height;$y++) {
            for($x=0;$x -lt $actualBitmap.Width;$x++) {
                $actualPixel=$actualBitmap.GetPixel($x,$y)
                $expectedPixel=$expectedBitmap.GetPixel($x,$y)
                if ($actualPixel.A -lt 200 -or $expectedPixel.A -lt 200) { continue }
                $compared++
                if ($actualPixel.R -ne $expectedPixel.R -or $actualPixel.G -ne $expectedPixel.G -or $actualPixel.B -ne $expectedPixel.B) { $different++ }
            }
        }
        return ($compared -ge 100 -and $different -le [math]::Ceiling($compared*0.02))
    } finally { $actualBitmap.Dispose(); $expectedBitmap.Dispose() }
}

function Get-TestTigerOrangePixels {
    param([Parameter(Mandatory)][Drawing.Icon]$Icon)
    $bitmap=$Icon.ToBitmap()
    try {
        $count=0
        for($y=0;$y -lt $bitmap.Height;$y++) {
            for($x=0;$x -lt $bitmap.Width;$x++) {
                $pixel=$bitmap.GetPixel($x,$y)
                if ($pixel.A -ge 180 -and $pixel.R -ge 150 -and $pixel.R -gt ($pixel.G*1.5) -and $pixel.B -lt 100) { $count++ }
            }
        }
        return $count
    } finally { $bitmap.Dispose() }
}

Describe 'Tiger Tech application icon' {
    It 'uses an application taskbar identity and Tiger Tech relaunch icon' {
        $form=New-LanMainForm -WireEvents:$false
        try {
            $properties=Get-LanTaskbarWindowProperties -Form $form
            [LanTaskbarIdentityNative]::ReadProcess() | Should Be 'TigerTech.LanFileSharing'
            $properties.AppId | Should Be 'TigerTech.LanFileSharing'
            $properties.IconResource | Should Match 'Tiger_Tech_Share_File\.ico,0$'
        } finally { $form.Dispose() }
    }

    It 'uses the supplied ICO in setup and installed launcher executables' {
        $root=Split-Path -Parent $PSScriptRoot
        $source=Join-Path $root 'icon/Tiger_Tech_Share_File.ico'
        $setup=Join-Path $root 'release/LanFileSharing-Setup-v3.81.exe'
        [IO.File]::Exists($source) | Should Be $true
        [IO.File]::Exists($setup) | Should Be $true
        if (-not [IO.File]::Exists($setup)) { return }
        $assembly=[Reflection.Assembly]::LoadFrom($setup)
        $payload=$assembly.GetManifestResourceStream('LanFileSharing.Payload.zip')
        try {
            $zip=New-Object IO.Compression.ZipArchive($payload,[IO.Compression.ZipArchiveMode]::Read)
            try {
                $launcherEntry=$zip.GetEntry('LanFileSharing.exe')
                $launcherEntry | Should Not BeNullOrEmpty
                $launcher=Join-Path $TestDrive 'LanFileSharing.exe'
                $entryStream=$launcherEntry.Open()
                $destination=[IO.File]::Create($launcher)
                try { $entryStream.CopyTo($destination) }
                finally { $destination.Dispose(); $entryStream.Dispose() }
                foreach($exe in @($setup,$launcher)) {
                    $actual=[Drawing.Icon]::ExtractAssociatedIcon($exe)
                    try { (Get-TestTigerOrangePixels $actual) -gt 50 | Should Be $true }
                    finally { $actual.Dispose() }
                }
                foreach($name in @('icon/Tiger_Tech_Share_File.ico','icon/Tiger_Tech_Share_File.png')) {
                    $entry=$zip.GetEntry($name)
                    $entry | Should Not BeNullOrEmpty
                    $stream=$entry.Open()
                    $copied=New-Object IO.MemoryStream
                    try {
                        $stream.CopyTo($copied)
                        $sha=[Security.Cryptography.SHA256]::Create()
                        try {
                            [BitConverter]::ToString($sha.ComputeHash($copied.ToArray())) |
                                Should Be ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $root $name)))))
                        } finally { $sha.Dispose() }
                    } finally { $copied.Dispose(); $stream.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $payload.Dispose() }
    }

    It 'shows the supplied ICO in the program window and System tray' {
        $source=Join-Path (Split-Path -Parent $PSScriptRoot) 'icon/Tiger_Tech_Share_File.ico'
        $form=New-LanMainForm -WireEvents:$false
        try {
            foreach($actual in @($form.Icon,$form.Tag.Tray.Icon)) {
                $expected=[Drawing.Icon]::new($source,[Drawing.Size]::new($actual.Width,$actual.Height))
                try { (Test-IconPixelsEqual $actual $expected) | Should Be $true }
                finally { $expected.Dispose() }
            }
        } finally { $form.Tag.Tray.Dispose(); $form.Dispose() }
    }

    It 'embeds the supplied PNG for the setup window logo' {
        $root=Split-Path -Parent $PSScriptRoot
        $setup=Join-Path $root 'release/LanFileSharing-Setup-v3.81.exe'
        [IO.File]::Exists($setup) | Should Be $true
        if (-not [IO.File]::Exists($setup)) { return }
        $assembly=[Reflection.Assembly]::LoadFrom($setup)
        $stream=$assembly.GetManifestResourceStream('LanFileSharing.Brand.png')
        $stream | Should Not BeNullOrEmpty
        if (-not $stream) { return }
        try {
            $copied=New-Object IO.MemoryStream
            try {
                $stream.CopyTo($copied)
                $expected=[IO.File]::ReadAllBytes((Join-Path $root 'icon/Tiger_Tech_Share_File.png'))
                $sha=[Security.Cryptography.SHA256]::Create()
                try {
                    [BitConverter]::ToString($sha.ComputeHash($copied.ToArray())) |
                        Should Be ([BitConverter]::ToString($sha.ComputeHash($expected)))
                } finally { $sha.Dispose() }
            } finally { $copied.Dispose() }
        } finally { $stream.Dispose() }
    }
}
