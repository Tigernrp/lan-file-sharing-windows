. (Join-Path $PSScriptRoot 'InstallLocation.ps1')

function Remove-LanOwnedShortcut {
    param([Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)][string[]]$AllowedTargets)
    if (-not [IO.File]::Exists($Path)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $target = [string]$shell.CreateShortcut($Path).TargetPath
    # Only a shortcut this app created is removed; a foreign one is left alone.
    if (@($AllowedTargets | Where-Object { [string]::Equals($_,$target,[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { return }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function New-LanResetAdapter {
    return @{
        HostStatePath = (Join-Path (Join-Path $env:ProgramData 'LanFileSharing') 'state.json')
        ClientStatePath = (Join-Path (Join-Path $env:LOCALAPPDATA 'LanFileSharing') 'mappings.json')
        StateRoot = (Join-Path $env:ProgramData 'LanFileSharing')
        SourceRoot = (Split-Path -Parent $PSScriptRoot)
        LegacyClientRoot = (Join-Path $env:LOCALAPPDATA 'Programs\LanFileSharingClient')
        GetInstallRecord = { Get-LanInstallRecord }
        GetTask = { [bool](Get-LanScheduledTask -TaskName 'LanFileSharing-HostWorker') }
        HasInstallRoot = { param($root) [IO.Directory]::Exists($root) }
        HasInstallMarker = { param($root)
            [IO.File]::Exists((Join-Path $root 'LanShare.ps1')) -and
            [IO.File]::Exists((Join-Path $root 'HostWorker.ps1'))
        }
        HasLegacyClientCode = { param($root) [IO.Directory]::Exists($root) }
        ValidateInstallRoot = { param($root) Assert-LanSafeInstallRoot -Path $root | Out-Null }
        ReadHostState = { param($path) Read-LanState -Path $path }
        ReadMappings = { param($path) Read-LanClientMappings -Path $path }
        GetMapping = {
            param($letter)
            $client = New-LanClientAdapter
            & $client.GetMapping $letter
        }
        RemoveMap = {
            param($letter,$unc)
            Remove-LanClientMap -Letter $letter -ExpectedUnc $unc -Adapter (New-LanClientAdapter) -SkipGuestRestore | Out-Null
        }
        ForgetMap = {
            param($letter,$unc)
            $path = Join-Path (Join-Path $env:LOCALAPPDATA 'LanFileSharing') 'mappings.json'
            $entries = @(Read-LanClientMappings -Path $path)
            $entry = @($entries | Where-Object { $_.Letter -eq $letter }) | Select-Object -First 1
            if (-not $entry -or -not [string]::Equals([string]$entry.Unc,$unc,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Saved mapping changed during reset.'
            }
            Write-LanClientMappings -Path $path -Mappings @($entries | Where-Object { $_.Letter -ne $letter })
        }
        ClearMappingState = {
            $path = Join-Path (Join-Path $env:LOCALAPPDATA 'LanFileSharing') 'mappings.json'
            if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        }
        RemoveLegacyClientCode = { param($root) Remove-LanLegacyClientCode -Path $root }
        RemoveUserStartup = { Remove-LanUserStartupSettings }
        RemoveHost = {
            param($root,$stateRoot,$sourceRoot)
            $startup = New-LanStartupAdapter -SourceRoot $sourceRoot -InstallRoot $root -StateRoot $stateRoot
            Remove-LanHostWorker -Adapter $startup | Out-Null
        }
        RestoreClientGuest = {
            $guestPath = Get-LanClientGuestStatePath
            if (-not [IO.File]::Exists($guestPath)) { return }
            $result = Restore-LanGuestConfiguration -Role Client -Adapter (New-LanAuthAdapter) -StatePath $guestPath
            if (@($result.Skipped).Count -gt 0) { throw 'Client Guest policy changed outside this app; its recovery snapshot was retained.' }
        }
        ClearClientGuestState = {
            $path=Get-LanClientGuestStatePath
            $directory=[IO.Path]::GetDirectoryName($path)
            if (-not [IO.File]::Exists($path)) {
                if ([IO.Directory]::Exists($directory) -and @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0) {
                    Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
                }
                return
            }
            $state=Read-LanState -Path $path
            if (@($state.GuestSnapshots).Count -gt 0 -or @($state.Shares).Count -gt 0 -or
                @($state.Journal).Count -gt 0 -or @($state.FirewallSnapshots).Count -gt 0) {
                throw 'Client Guest recovery state is not empty; it was kept for retry.'
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            $lockPath=$path+'.lock'
            if ([IO.File]::Exists($lockPath)) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop }
            if (@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
            }
        }
        RemoveShortcut = { param($root)
            $allowed=@((Join-Path $root 'LanFileSharing.exe'),(Join-Path $root 'Start-LanShare.cmd'))
            foreach ($path in @(
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\LanFileSharing.lnk')
                (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'LanFileSharing.lnk')
            )) { Remove-LanOwnedShortcut -Path $path -AllowedTargets $allowed }
        }
        RemoveRecord = { param($root) Remove-LanInstallRecord -ExpectedPath $root }
        RemoveUninstallEntry = { param($root)
            $path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LanFileSharing'
            $entry=Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
            if (-not $entry) { return }
            if (-not [string]::Equals([string]$entry.InstallLocation,$root,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Windows uninstall entry points to another installation.'
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Get-LanResetPreview {
    param([hashtable]$Adapter=(New-LanResetAdapter))
    $record = & $Adapter.GetInstallRecord
    $root = if ($record) { [string]$record.InstallRoot } else { Join-Path $env:ProgramFiles 'LanFileSharing' }
    $root = ConvertTo-LanInstallRoot -Path $root
    $hostState = & $Adapter.ReadHostState $Adapter.HostStatePath
    $mappings = @(& $Adapter.ReadMappings $Adapter.ClientStatePath)
    return [pscustomobject]@{
        InstallRoot=$root
        StateRoot=[string]$Adapter.StateRoot
        HostStatePath=[string]$Adapter.HostStatePath
        ClientStatePath=[string]$Adapter.ClientStatePath
        HostTaskExists=[bool](& $Adapter.GetTask)
        HasCode=[bool](& $Adapter.HasInstallRoot $root)
        HasLegacyClientCode= if ($Adapter.HasLegacyClientCode) { [bool](& $Adapter.HasLegacyClientCode $Adapter.LegacyClientRoot) } else { $false }
        LegacyClientRoot=[string]$Adapter.LegacyClientRoot
        Shares=@($hostState.Shares)
        Mappings=$mappings
        HasInstallRecord=[bool]$record
    }
}

function Get-LanCurrentUserResetPreview {
    param([hashtable]$Adapter=(New-LanResetAdapter))
    return [pscustomobject]@{
        ClientStatePath=[string]$Adapter.ClientStatePath
        LegacyClientRoot=[string]$Adapter.LegacyClientRoot
        HasLegacyClientCode=if ($Adapter.HasLegacyClientCode) { [bool](& $Adapter.HasLegacyClientCode $Adapter.LegacyClientRoot) } else { $false }
        Mappings=@(& $Adapter.ReadMappings $Adapter.ClientStatePath)
    }
}

function Format-LanCurrentUserResetPreview {
    param([Parameter(Mandatory)]$Preview)
    $mappings=@($Preview.Mappings)
    if ($mappings.Count -eq 0) { return 'Current-user mapped drives to remove: (none)' }
    $lines=@('Current-user mapped drives to remove:')
    foreach($entry in $mappings) { $lines += ('  '+[string]$entry.Letter+': -> '+[string]$entry.Unc) }
    return ($lines -join [Environment]::NewLine)
}

function Get-LanResetMapSignature {
    param($Entries)
    return (@($Entries | ForEach-Object { ([string]$_.Letter).ToUpperInvariant() + '=' + ([string]$_.Unc).ToUpperInvariant() } | Sort-Object) -join '|')
}

function Get-LanResetShareSignature {
    param($Entries)
    return (@($Entries | ForEach-Object { [string]$_.Id } | Sort-Object) -join '|')
}

function Invoke-LanCurrentUserReset {
    param([Parameter(Mandatory)]$Preview,[hashtable]$Adapter=(New-LanResetAdapter))
    $current = @(& $Adapter.ReadMappings $Adapter.ClientStatePath)
    if ((Get-LanResetMapSignature $Preview.Mappings) -ne (Get-LanResetMapSignature $current)) {
        throw 'Saved mappings changed after the reset preview; refresh before continuing.'
    }
    foreach ($entry in $current) {
        $actual = & $Adapter.GetMapping ([string]$entry.Letter)
        if ($actual -and -not [string]::Equals([string]$actual,[string]$entry.Unc,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Drive $($entry.Letter): now points to another share; reset stopped."
        }
    }
    foreach ($entry in $current) {
        $actual = & $Adapter.GetMapping ([string]$entry.Letter)
        if ($actual) { & $Adapter.RemoveMap ([string]$entry.Letter) ([string]$entry.Unc) | Out-Null }
        else { & $Adapter.ForgetMap ([string]$entry.Letter) ([string]$entry.Unc) | Out-Null }
    }
    & $Adapter.ClearMappingState | Out-Null
    if ($Preview.HasLegacyClientCode -and $Adapter.RemoveLegacyClientCode) {
        & $Adapter.RemoveLegacyClientCode $Preview.LegacyClientRoot | Out-Null
    }
    if ($Adapter.RemoveUserStartup) { & $Adapter.RemoveUserStartup | Out-Null }
    return [pscustomobject]@{RemovedMappings=$current.Count}
}

function Remove-LanLegacyClientCode {
    param([Parameter(Mandatory)][string]$Path)
    $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\LanFileSharingClient')).TrimEnd('\')
    $actual = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The legacy client removal target is not the application directory.'
    }
    if (-not [IO.Directory]::Exists($actual)) { return }
    $rootItem = Get-Item -LiteralPath $actual -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Legacy client directory is a reparse point.' }
    $knownRoot = @('LanShare.ps1','Start-LanShare.cmd','Diagnose-LanClient.ps1','Diagnose-LanClient.cmd')
    $knownModules = @('Selection','State','Auth','SingleFile','Host','ClientMap','Startup','Ui','Network','InstallLocation','Reset') |
        ForEach-Object { "$_.ps1" }
    $src = Join-Path $actual 'src'
    if ([IO.Directory]::Exists($src)) {
        $srcItem = Get-Item -LiteralPath $src -Force -ErrorAction Stop
        if (($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Legacy client module directory is a reparse point.' }
    }
    foreach ($name in $knownRoot) {
        $file = Join-Path $actual $name
        if (-not [IO.File]::Exists($file)) { continue }
        $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Legacy client file is a reparse point: $name" }
        Remove-Item -LiteralPath $file -Force -ErrorAction Stop
    }
    if ([IO.Directory]::Exists($src)) {
        foreach ($name in $knownModules) {
            $file = Join-Path $src $name
            if (-not [IO.File]::Exists($file)) { continue }
            $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Legacy client module is a reparse point: $name" }
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
        }
        if (@(Get-ChildItem -LiteralPath $src -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $src -Force -ErrorAction Stop }
    }
    if (@(Get-ChildItem -LiteralPath $actual -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $actual -Force -ErrorAction Stop }
    else { throw 'Unknown files remain in the legacy client directory; they were left untouched.' }
}

function Invoke-LanMachineReset {
    param([Parameter(Mandatory)]$Preview,[hashtable]$Adapter=(New-LanResetAdapter))
    # A machine reset removes shares, tasks and shortcuts, and it is the step users report as a
    # frozen installer. Name every step as it is reached: when one of them blocks, the last name
    # printed says exactly which, instead of leaving setup sitting on a progress bar.
    $step = {
        param([string]$Text)
        try { Write-Output ("reset step: $Text") } catch { }
    }
    & $step 'preview'
    $current = Get-LanResetPreview -Adapter $Adapter
    & $step 'preview read'
    if (-not [string]::Equals([string]$Preview.InstallRoot,[string]$current.InstallRoot,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$Preview.StateRoot,[string]$current.StateRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (Get-LanResetShareSignature $Preview.Shares) -ne (Get-LanResetShareSignature $current.Shares)) {
        throw 'Host installation changed after the reset preview; refresh before continuing.'
    }
    if ($Adapter.ValidateInstallRoot) { & $Adapter.ValidateInstallRoot $current.InstallRoot | Out-Null }
    if ($current.HasCode -and -not $current.HasInstallRecord -and $Adapter.HasInstallMarker -and
        -not (& $Adapter.HasInstallMarker $current.InstallRoot)) {
        throw 'A directory at the legacy installation path has no application marker; it was left untouched.'
    }
    & $step 'remove host'
    & $Adapter.RemoveHost $current.InstallRoot $current.StateRoot $Adapter.SourceRoot | Out-Null
    & $step 'restore client guest'
    & $Adapter.RestoreClientGuest | Out-Null
    & $step 'clear client guest state'
    if ($Adapter.ClearClientGuestState) { & $Adapter.ClearClientGuestState | Out-Null }
    & $step 'remove shortcut'
    if ($Adapter.RemoveShortcut) { & $Adapter.RemoveShortcut $current.InstallRoot | Out-Null }
    & $step 'remove uninstall entry'
    if ($Adapter.RemoveUninstallEntry) { & $Adapter.RemoveUninstallEntry $current.InstallRoot | Out-Null }
    & $step 'remove record'
    if ($current.HasInstallRecord) { & $Adapter.RemoveRecord $current.InstallRoot | Out-Null }
    & $step 'done'
    return [pscustomobject]@{Removed=$true;InstallRoot=$current.InstallRoot}
}

function Invoke-LanClientGuestReset {
    param([hashtable]$Adapter=(New-LanResetAdapter))
    & $Adapter.RestoreClientGuest | Out-Null
    if ($Adapter.ClearClientGuestState) { & $Adapter.ClearClientGuestState | Out-Null }
    return [pscustomobject]@{Restored=$true}
}
