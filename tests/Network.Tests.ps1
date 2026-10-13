. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/Host.ps1"
. "$PSScriptRoot/../src/Startup.ps1"

Describe 'trusted LAN network preparation' {
    BeforeEach {
        $script:profiles = @([pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet';InterfaceIndex=7;NetworkCategory='Public'})
        $script:changed = @()
        $script:adapter = @{
            GetNetworkProfiles = { $script:profiles }
            SetNetworkProfile = {
                param($index)
                $script:changed += $index
                foreach ($profile in $script:profiles) {
                    if ($profile.InterfaceIndex -eq $index) { $profile.NetworkCategory='Private' }
                }
            }
        }
    }

    It 'changes the selected active network to Private and records its identity' {
        $network = Ensure-LanPrivateNetwork -Adapter $script:adapter
        $network.Name | Should Be 'Home LAN'
        $network.InterfaceAlias | Should Be 'Ethernet'
        $script:changed | Should Be @(7)
    }

    It 'follows the machine onto another network instead of waiting for the original one' {
        # A laptop moves between networks. Waiting for the exact network a share was created on left
        # the share unusable until the user recreated it, which is the report this behaviour answers.
        # The share may move, but only onto a single usable network, and that network is made Private
        # before anything is exposed on it.
        $expected = [pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'}
        Ensure-LanPrivateNetwork -Adapter $script:adapter -Expected $expected | Out-Null
        $script:changed | Should Be @(7)

        $script:changed = @()
        $script:profiles = @([pscustomobject]@{Name='Office LAN';InterfaceAlias='Wi-Fi';InterfaceIndex=9;NetworkCategory='Public'})
        $result = Ensure-LanPrivateNetwork -Adapter $script:adapter -Expected $expected
        $result.Changed | Should Be $true
        $result.Name | Should Be 'Office LAN'
        $script:changed | Should Be @(9)
        $script:profiles[0].NetworkCategory | Should Be 'Private'
    }

    It 'still refuses to move when the machine is on several usable networks' {
        # Moving is only safe when exactly one candidate exists: with two, choosing one would publish
        # the share on a network the user did not intend.
        $expected = [pscustomobject]@{Name='Home LAN';InterfaceAlias='Ethernet'}
        $script:changed = @()
        $script:profiles = @(
            [pscustomobject]@{Name='Office LAN';InterfaceAlias='Wi-Fi';InterfaceIndex=9;NetworkCategory='Private'}
            [pscustomobject]@{Name='Cafe Wi-Fi';InterfaceAlias='Wi-Fi 2';InterfaceIndex=11;NetworkCategory='Private'}
        )
        { Ensure-LanPrivateNetwork -Adapter $script:adapter -Expected $expected } | Should Throw
        $script:changed.Count | Should Be 0
    }

    It 'does not guess when multiple networks are active' {
        $script:profiles += [pscustomobject]@{Name='Guest Wi-Fi';InterfaceAlias='Wi-Fi';InterfaceIndex=9;NetworkCategory='Public'}
        { Ensure-LanPrivateNetwork -Adapter $script:adapter } | Should Throw
        $script:changed.Count | Should Be 0
    }

    It 'fails clearly if Windows keeps the network Public' {
        $script:adapter.SetNetworkProfile = { param($index) $script:changed += $index }
        { Ensure-LanPrivateNetwork -Adapter $script:adapter } | Should Throw
        $script:changed | Should Be @(7)
        $script:profiles[0].NetworkCategory | Should Be 'Public'
    }

    It 'waits briefly for Windows to report the category change' {
        $script:reads = 0
        $script:adapter.GetNetworkProfiles = {
            $script:reads++
            if ($script:reads -ge 3) { $script:profiles[0].NetworkCategory='Private' }
            $script:profiles
        }
        $script:adapter.SetNetworkProfile = { param($index) $script:changed += $index }
        (Ensure-LanPrivateNetwork -Adapter $script:adapter).Name | Should Be 'Home LAN'
        $script:reads | Should BeGreaterThan 2
    }
}
