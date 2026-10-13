$modulePath = Join-Path $PSScriptRoot '../src/Reset.ps1'
if (Test-Path -LiteralPath $modulePath) { . $modulePath }

Describe 'clean reset of LAN File Sharing' {
    BeforeEach {
        $script:events = New-Object System.Collections.ArrayList
        $script:source = Join-Path $TestDrive 'original.txt'
        [IO.File]::WriteAllText($script:source,'keep my data')
        $script:record = [pscustomobject]@{InstallRoot='C:\Program Files\LanFileSharing'}
        $script:state = [pscustomobject]@{Shares=@([pscustomobject]@{Id='owned-share';Name='Laptop';SourcePath=$script:source})}
        $script:maps = @([pscustomobject]@{Letter='Z';Unc='\\HOST\Laptop';AuthMode='WindowsCurrent'})
        $script:actualMap = '\\HOST\Laptop'
        $script:hasCode = $true
        $script:hasTask = $true
        $script:installMarker = $true
        $script:adapter = @{
            HostStatePath = 'C:\ProgramData\LanFileSharing\state.json'
            ClientStatePath = 'C:\Users\Test\AppData\Local\LanFileSharing\mappings.json'
            StateRoot = 'C:\ProgramData\LanFileSharing'
            LegacyClientRoot = 'C:\Users\Test\AppData\Local\Programs\LanFileSharingClient'
            GetInstallRecord = { $script:record }
            GetTask = { $script:hasTask }
            HasInstallRoot = { param($root) $script:hasCode }
            HasInstallMarker = { param($root) $script:installMarker }
            HasLegacyClientCode = { param($root) $true }
            ReadHostState = { param($path) $script:state }
            ReadMappings = { param($path) $script:maps }
            GetMapping = { param($letter) $script:actualMap }
            RemoveMap = { param($letter,$unc) [void]$script:events.Add("unmap-$letter"); $script:maps=@() }
            ForgetMap = { param($letter,$unc) [void]$script:events.Add("forget-$letter"); $script:maps=@() }
            ClearMappingState = { [void]$script:events.Add('clear-client-state') }
            RemoveLegacyClientCode = { param($root) [void]$script:events.Add('remove-legacy-client') }
            RemoveUserStartup = { [void]$script:events.Add('remove-user-startup') }
            RemoveHost = { param($root,$stateRoot) [void]$script:events.Add('remove-host'); $script:state.Shares=@() }
            RemoveShortcut = { param($root) [void]$script:events.Add('remove-shortcut') }
            RemoveUninstallEntry = { param($root) [void]$script:events.Add('remove-uninstall-entry') }
            RemoveRecord = { param($root) [void]$script:events.Add('remove-record'); $script:record=$null }
            RestoreClientGuest = { [void]$script:events.Add('restore-client-guest') }
            ClearClientGuestState = { [void]$script:events.Add('clear-client-guest-state') }
        }
    }

    It 'removes this Windows user startup preference during current-user reset' {
        $preview=Get-LanResetPreview -Adapter $script:adapter
        Invoke-LanCurrentUserReset -Preview $preview -Adapter $script:adapter | Out-Null
        $script:events.Contains('remove-user-startup') | Should Be $true
    }

    It "previews the current user's mappings without reading protected host state" {
        $script:adapter.ReadHostState={ throw 'Host state requires elevation' }
        $preview=Get-LanCurrentUserResetPreview -Adapter $script:adapter
        @($preview.Mappings).Count | Should Be 1
        $preview.HasLegacyClientCode | Should Be $true
        (Format-LanCurrentUserResetPreview -Preview $preview) | Should Match 'Z: -> \\\\HOST\\Laptop'
    }

    It 'previews app-owned shares and maps even when old code is missing' {
        $script:hasCode=$false
        $preview = Get-LanResetPreview -Adapter $script:adapter
        $preview.InstallRoot | Should Be 'C:\Program Files\LanFileSharing'
        $preview.HostTaskExists | Should Be $true
        $preview.HasCode | Should Be $false
        @($preview.Shares).Count | Should Be 1
        @($preview.Mappings).Count | Should Be 1
        $preview.HasLegacyClientCode | Should Be $true
        [IO.File]::ReadAllText($script:source) | Should Be 'keep my data'
    }

    It 'refuses to touch a drive letter now mapped to another share' {
        $preview = Get-LanResetPreview -Adapter $script:adapter
        $script:actualMap = '\\OTHER\Documents'
        { Invoke-LanCurrentUserReset -Preview $preview -Adapter $script:adapter } | Should Throw
        $script:events.Count | Should Be 0
        @($script:maps).Count | Should Be 1
    }

    It 'removes only recorded current-user mappings and retains original files' {
        $preview = Get-LanResetPreview -Adapter $script:adapter
        Invoke-LanCurrentUserReset -Preview $preview -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Be 'unmap-Z,clear-client-state,remove-legacy-client,remove-user-startup'
        [IO.File]::ReadAllText($script:source) | Should Be 'keep my data'
    }

    It 'removes machine state using bundled code when installed code is missing' {
        $script:hasCode=$false
        $preview = Get-LanResetPreview -Adapter $script:adapter
        Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Be 'remove-host,restore-client-guest,clear-client-guest-state,remove-shortcut,remove-uninstall-entry,remove-record'
        [IO.File]::ReadAllText($script:source) | Should Be 'keep my data'
    }

    It 'restores client Guest policy on a client-only installation' {
        Invoke-LanClientGuestReset -Adapter $script:adapter | Out-Null
        ($script:events -join ',') | Should Be 'restore-client-guest,clear-client-guest-state'
    }

    It 'keeps the install record if the Windows uninstall entry points elsewhere' {
        $script:adapter.RemoveUninstallEntry = { param($root) throw 'entry points to another installation' }
        $preview=Get-LanResetPreview -Adapter $script:adapter
        { Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter } | Should Throw
        $script:record.InstallRoot | Should Be 'C:\Program Files\LanFileSharing'
    }

    It 'preserves recovery state when app-owned Guest cleanup is blocked' {
        $script:adapter.RestoreClientGuest = { throw 'Guest snapshot changed outside this app' }
        $preview = Get-LanResetPreview -Adapter $script:adapter
        { Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter } | Should Throw
        $script:record.InstallRoot | Should Be 'C:\Program Files\LanFileSharing'
        ($script:events -join ',') | Should Not Match 'remove-record'
    }

    It 'keeps the recorded state when host cleanup stops partway through' {
        $script:adapter.RemoveHost = { throw 'share marker changed' }
        $preview = Get-LanResetPreview -Adapter $script:adapter
        { Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter } | Should Throw
        @($script:state.Shares).Count | Should Be 1
        $script:record.InstallRoot | Should Be 'C:\Program Files\LanFileSharing'
    }

    It 'rejects a recorded location that fails the trusted-path check' {
        $script:adapter.ValidateInstallRoot = { param($root) throw 'user-writable parent' }
        $preview = Get-LanResetPreview -Adapter $script:adapter
        { Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter } | Should Throw
        $script:events.Count | Should Be 0
    }

    It 'rejects a forged preview path rather than deleting it' {
        $preview = Get-LanResetPreview -Adapter $script:adapter
        $preview.InstallRoot = 'C:\Other\LanFileSharing'
        { Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter } | Should Throw
        $script:events.Count | Should Be 0
    }

    It 'keeps an unrelated directory at the legacy install path' {
        $script:record=$null
        $script:installMarker=$false
        $preview=Get-LanResetPreview -Adapter $script:adapter
        { Invoke-LanMachineReset -Preview $preview -Adapter $script:adapter } | Should Throw
        $script:events.Count | Should Be 0
    }

    It 'leaves unexpected files in the old client directory untouched' {
        $previousLocalAppData=$env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA=$TestDrive
            $legacy=Join-Path $TestDrive 'Programs\LanFileSharingClient'
            [IO.Directory]::CreateDirectory($legacy) | Out-Null
            [IO.File]::WriteAllText((Join-Path $legacy 'LanShare.ps1'),'old app')
            [IO.File]::WriteAllText((Join-Path $legacy 'notes.txt'),'keep this')
            { Remove-LanLegacyClientCode -Path $legacy } | Should Throw
            [IO.File]::ReadAllText((Join-Path $legacy 'notes.txt')) | Should Be 'keep this'
        } finally { $env:LOCALAPPDATA=$previousLocalAppData }
    }

    It 'removes a desktop shortcut this app created and leaves a foreign one' {
        $installRoot = Join-Path $TestDrive 'LanFileSharing'
        [IO.Directory]::CreateDirectory($installRoot) | Out-Null
        $launcher = Join-Path $installRoot 'LanFileSharing.exe'
        [IO.File]::WriteAllText($launcher,'stub')
        $allowed = @($launcher,(Join-Path $installRoot 'Start-LanShare.cmd'))
        $shell = New-Object -ComObject WScript.Shell

        $owned = Join-Path $TestDrive 'LanFileSharing.lnk'
        $ownShortcut = $shell.CreateShortcut($owned)
        $ownShortcut.TargetPath = $launcher
        $ownShortcut.Save()

        $foreign = Join-Path $TestDrive 'OtherApp.lnk'
        [IO.File]::WriteAllText($foreign,'not a shortcut we own')

        Remove-LanOwnedShortcut -Path $owned -AllowedTargets $allowed
        [IO.File]::Exists($owned) | Should Be $false
        # An unreadable or foreign file must never be deleted by the reset.
        Remove-LanOwnedShortcut -Path $foreign -AllowedTargets $allowed
        [IO.File]::Exists($foreign) | Should Be $true
    }

    It 'ignores a missing shortcut file without throwing' {
        $missing = Join-Path $TestDrive 'nothing-here.lnk'
        { Remove-LanOwnedShortcut -Path $missing -AllowedTargets @('C:\x\LanFileSharing.exe') } | Should Not Throw
    }
}
