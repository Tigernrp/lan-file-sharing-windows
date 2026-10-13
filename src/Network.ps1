function Ensure-LanShareNetwork {
    param([hashtable]$Adapter,$Expected)
    $context=$Adapter.OnlineContext
    if ($context -and $context.Ready) {
        $s=$context.Status
        return [pscustomobject]@{Transport='NetBird';Name='Online';InterfaceAlias=$s.InterfaceAlias;InterfaceId=$s.InterfaceId;
            Binding=(Get-LanOnlineBinding $s);Changed=($Expected.Transport -ne 'NetBird' -or $Expected.InterfaceId -ne $s.InterfaceId)}
    }
    $copy=@{}; foreach($k in $Adapter.Keys){$copy[$k]=$Adapter[$k]}
    $getProfiles=$Adapter.GetNetworkProfiles
    if (-not $getProfiles) {
        if ((& $Adapter.GetProfile) -ne 'Private') { throw 'No trusted sharing network is ready.' }
        return [pscustomobject]@{Transport='Lan';Name=$null;InterfaceAlias=$null;Changed=$false}
    }
    $excluded=if($context.Status.InterfaceAlias){$context.Status.InterfaceAlias}else{$context.Settings.LastKnownInterface.InterfaceAlias}
    $onlineEnabled=[bool]$context.Settings.Enabled
    $copy.GetNetworkProfiles={ @(& $getProfiles | Where-Object {
        $_.InterfaceAlias -ne $excluded -and (-not $onlineEnabled -or $_.NetworkCategory -eq 'Private')
    }) }.GetNewClosure()
    if ($Expected.Transport -eq 'NetBird' -or -not $Expected.Name) { $Expected=$null }
    return Ensure-LanPrivateNetwork -Adapter $copy -Expected $Expected
}

function Ensure-LanPrivateNetwork {
    param([Parameter(Mandatory)][hashtable]$Adapter, $Expected)
    $profiles = @(& $Adapter.GetNetworkProfiles)
    if ($Expected) {
        $matches = @($profiles | Where-Object {
            [string]::Equals([string]$_.Name,[string]$Expected.Name,[StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$_.InterfaceAlias,[string]$Expected.InterfaceAlias,[StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1) {
            # A laptop moves between networks, and the one it was shared on is often not there any
            # more. Waiting for that exact network left the share unusable until the user recreated
            # it. Instead the share follows the machine: it may use exactly one other usable network,
            # which is then made Private before anything is exposed on it. Requiring exactly one keeps
            # the guarantee that a share is never published on several networks at once, and setting
            # it Private keeps it off a network Windows treats as untrusted.
            $alternatives = @($profiles | Where-Object { $_.NetworkCategory -in @('Public','Private') })
            if ($alternatives.Count -ne 1) { throw 'The previously shared LAN is not connected.' }
            $profile = $alternatives[0]
            if ($profile.NetworkCategory -eq 'Public') {
                & $Adapter.SetNetworkProfile $profile.InterfaceIndex | Out-Null
                for ($attempt=0; $attempt -lt 12; $attempt++) {
                    $again = @(& $Adapter.GetNetworkProfiles | Where-Object {
                        [string]::Equals([string]$_.Name,[string]$profile.Name,[StringComparison]::OrdinalIgnoreCase) -and
                        [string]::Equals([string]$_.InterfaceAlias,[string]$profile.InterfaceAlias,[StringComparison]::OrdinalIgnoreCase)
                    })
                    if ($again.Count -ne 1) { throw 'LAN network changed while setting it to Private.' }
                    $profile = $again[0]
                    if ($profile.NetworkCategory -eq 'Private') { break }
                    if ($attempt -lt 11) { Start-Sleep -Milliseconds 250 }
                }
            }
            if ($profile.NetworkCategory -ne 'Private') { throw 'The selected LAN could not be set to Private.' }
            # Returned so the caller can record the network the share actually ended up on, which is
            # what makes the next move automatic as well.
            return [pscustomobject]@{
                Name=[string]$profile.Name
                InterfaceAlias=[string]$profile.InterfaceAlias
                Changed=$true
            }
        }
    } else {
        $matches = @($profiles | Where-Object { $_.NetworkCategory -in @('Public','Private') })
        if ($matches.Count -ne 1) { throw 'Connect exactly one home or office network before starting a share.' }
    }
    $profile = $matches[0]
    if ($profile.NetworkCategory -eq 'Public') {
        & $Adapter.SetNetworkProfile $profile.InterfaceIndex | Out-Null
        for ($attempt=0; $attempt -lt 12; $attempt++) {
            $matches = @(& $Adapter.GetNetworkProfiles | Where-Object {
                [string]::Equals([string]$_.Name,[string]$profile.Name,[StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.InterfaceAlias,[string]$profile.InterfaceAlias,[StringComparison]::OrdinalIgnoreCase)
            })
            if ($matches.Count -ne 1) { throw 'LAN network changed while setting it to Private.' }
            $profile = $matches[0]
            if ($profile.NetworkCategory -eq 'Private') { break }
            if ($attempt -lt 11) { Start-Sleep -Milliseconds 250 }
        }
    }
    if ($profile.NetworkCategory -ne 'Private') { throw 'The selected LAN could not be set to Private.' }
    return [pscustomobject]@{Name=[string]$profile.Name;InterfaceAlias=[string]$profile.InterfaceAlias;Changed=$false}
}
