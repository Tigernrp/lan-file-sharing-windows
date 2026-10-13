. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/ClientMap.ps1"

Describe 'LAN client mapping' {
    BeforeEach {
        # Connection fixtures must never write or delete the real user's Windows vault.
        Mock Set-LanWindowsCredential { $true }
        Mock Remove-LanWindowsCredential { $true }
        $script:events = New-Object System.Collections.ArrayList
        $script:mapped = @{}
        $script:adapter = @{
            StatePath = (Join-Path $TestDrive 'client-maps.json')
            CredentialPath = (Join-Path $TestDrive 'client-secrets.json')
            GuestStatePath = (Join-Path $TestDrive 'guest-policy.json')
            GetOccupiedLetters = { @('C','D') }
            Connect = { param($unc,$local,$persistent,$prompt) [void]$script:events.Add("connect-$local-$persistent-$prompt"); if ($local) { $script:mapped[$local]=$unc }; 0 }
            Disconnect = { param($local,$update,$force) [void]$script:events.Add("disconnect-$local-$force"); $script:mapped.Remove($local); 0 }
            GetMapping = { param($local) $script:mapped[$local] }
            GetSession = { param($unc) 'SERVER\alice' }
            LaunchExplorer = { param($path) [void]$script:events.Add('explorer') }
            GetGuestPolicy = { param($role) @{ Managed=$false; RequireSigning=$false; RequireEncryption=$false; InsecureGuestAllowed=$true; UnrelatedSharesAtRisk=@() } }
        }
        if (Test-Path -LiteralPath $script:adapter.StatePath) { Remove-Item -LiteralPath $script:adapter.StatePath }
        if (Test-Path -LiteralPath $script:adapter.CredentialPath) { Remove-Item -LiteralPath $script:adapter.CredentialPath }
        if (Test-Path -LiteralPath $script:adapter.GuestStatePath) { Remove-Item -LiteralPath $script:adapter.GuestStatePath }
    }

    It 'accepts a UNC share and rejects traversal or a server-only path' {
        (Assert-LanUnc -Path '\\server\share') | Should Be '\\server\share'
        { Assert-LanUnc -Path '\\server' } | Should Throw
        { Assert-LanUnc -Path '\\server\share\..\secret' } | Should Throw
    }

    It 'chooses the lowest free drive letter and can list the rest' {
        # Lowest first, not highest: on this machine every letter from E to Y maps the share correctly
        # while Z fails with error 1202 even though Windows reports it free, so preferring the highest
        # letter walked straight into the one letter that does not work.
        (Get-LanFreeDriveLetter -Occupied @('C','F')) | Should Be 'E'
        (Get-LanFreeDriveLetter -Occupied @('C','E','F','G')) | Should Be 'H'
        # Z is only used when nothing else is left.
        $all = @('E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y')
        (Get-LanFreeDriveLetter -Occupied (@('C') + $all)) | Should Be 'Z'
        @(Get-LanFreeDriveLetterList -Occupied @('C','F'))[0..4] | Should Be @('E','G','H','I','J')
    }

    It 'maps persistently and prompts only for Protected' {
        $map = Add-LanClientMap -Unc '\\server\share' -Letter 'P' -Persistent $true -AuthMode Protected -Adapter $script:adapter
        $map.Letter | Should Be 'P'
        ($script:events -join ',') | Should Be 'connect-P-True-True'
        @(Read-LanClientMappings $script:adapter.StatePath).Count | Should Be 1
    }

    It 'uses no prompt for WindowsCurrent and rejects a Guest fallback' {
        $script:adapter.GetSession = { param($unc) 'SERVER\Guest' }
        { Add-LanClientMap -Unc '\\server\share' -Letter 'Q' -Persistent $false -AuthMode WindowsCurrent -Adapter $script:adapter } | Should Throw
        ($script:events -join ',') | Should Match 'connect-Q-False-False'
        @(Read-LanClientMappings $script:adapter.StatePath).Count | Should Be 0
    }

    It 'reports a blocked Guest policy without prompting' {
        $script:adapter.GetGuestPolicy = { param($role) @{ Managed=$false; RequireSigning=$true; RequireEncryption=$false; InsecureGuestAllowed=$false; UnrelatedSharesAtRisk=@() } }
        { Add-LanClientMap -Unc '\\server\share' -Letter 'R' -Persistent $false -AuthMode Guest -Adapter $script:adapter } | Should Throw
        $script:events.Count | Should Be 0
    }

    It 'unmaps only an app-owned mapping with the expected target' {
        Add-LanClientMap -Unc '\\server\share' -Letter 'S' -Persistent $false -AuthMode Protected -Adapter $script:adapter | Out-Null
        { Remove-LanClientMap -Letter 'S' -ExpectedUnc '\\other\share' -Adapter $script:adapter } | Should Throw
        Remove-LanClientMap -Letter 'S' -ExpectedUnc '\\server\share' -Adapter $script:adapter | Out-Null
        @(Read-LanClientMappings $script:adapter.StatePath).Count | Should Be 0
        ($script:events -join ',') | Should Match 'disconnect-S-False'
    }

    It 'translates Windows credential conflict 1219' {
        $script:adapter.Connect = { param($unc,$local,$persistent,$prompt) 1219 }
        try {
            Add-LanClientMap -Unc '\\server\share' -Letter 'T' -Persistent $false -AuthMode Protected -Adapter $script:adapter | Out-Null
            throw 'Expected 1219 was not raised.'
        } catch { $_.Exception.Message | Should Match '1219' }
    }

    It 'opens UNC in Explorer without a prompt for passwordless modes' {
        Open-LanUnc -Path '\\server\share\file.txt' -AuthMode WindowsCurrent -Adapter $script:adapter
        ($script:events -join ',') | Should Match 'connect--False-False,explorer'
    }

    It 'checks that the authenticated Windows user can read the share before opening Explorer' {
        $script:adapter.ProbeAccess = { param($path) [void]$script:events.Add("probe-$path") }
        Open-LanUnc -Path '\\server\share' -AuthMode WindowsCurrent -Adapter $script:adapter
        ($script:events -join ',') | Should Be 'connect--False-False,probe-\\server\share,explorer'
    }

    It 'reports a share permission failure instead of claiming that UNC opened' {
        $script:adapter.ProbeAccess = { param($path) throw [UnauthorizedAccessException]::new('Access denied') }
        { Open-LanUnc -Path '\\server\share' -AuthMode WindowsCurrent -Adapter $script:adapter } | Should Throw 'SERVER\alice'
        ($script:events -join ',') | Should Be 'connect--False-False'
    }

    It 'reports a missing host share distinctly from an NTFS permission failure' {
        $script:adapter.ProbeAccess = {
            param($path)
            throw [IO.IOException]::new('The network name cannot be found.', -2147024829)
        }
        { Open-LanUnc -Path '\\server\share' -AuthMode WindowsCurrent -Adapter $script:adapter } | Should Throw 'ไม่พบแชร์'
        ($script:events -join ',') | Should Be 'connect--False-False'
    }

    It 'reads an actual directory or file through the production access probe' {
        $folder = Join-Path $TestDrive 'probe-dir'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file = Join-Path $folder 'sample.txt'
        [IO.File]::WriteAllText($file, 'sample')
        $adapter = New-LanClientAdapter
        { & $adapter.ProbeAccess $folder } | Should Not Throw
        { & $adapter.ProbeAccess $file } | Should Not Throw
        { & $adapter.ProbeAccess (Join-Path $folder 'missing.txt') } | Should Throw
    }

    It 'removes a newly mapped drive when the mapped share cannot be read' {
        $script:adapter.ProbeAccess = { param($path) throw [UnauthorizedAccessException]::new('Access denied') }
        { Add-LanClientMap -Unc '\\server\share' -Letter 'P' -Persistent $false -AuthMode WindowsCurrent -Adapter $script:adapter } | Should Throw 'SERVER\alice'
        ($script:events -join ',') | Should Be 'connect-P-False-False,disconnect-P-False'
        @(Read-LanClientMappings $script:adapter.StatePath).Count | Should Be 0
    }

    It 'clears a persistent Windows mapping when the access probe fails' {
        $script:disconnectUpdate = $null
        $script:adapter.ProbeAccess = { param($path) throw [UnauthorizedAccessException]::new('Access denied') }
        $script:adapter.Disconnect = { param($local,$update,$force) $script:disconnectUpdate=$update; $script:mapped.Remove($local); 0 }
        { Add-LanClientMap -Unc '\\server\share' -Letter 'P' -Persistent $true -AuthMode WindowsCurrent -Adapter $script:adapter } | Should Throw
        $script:disconnectUpdate | Should Be $true
        @(Read-LanClientMappings $script:adapter.StatePath).Count | Should Be 0
    }

    It 'opens UNC with an explicit matching host account when the current local account has no password' {
        $script:connection = $null
        $script:adapter.GetBlankPasswordAccount = { 'krusuea' }
        $script:adapter.GetSession = { param($unc) 'SCHOOL-HOST\krusuea' }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connection = [pscustomobject]@{Unc=$unc;UserName=$userName;Password=$password;Prompt=$prompt}
            0
        }
        Open-LanUnc -Path '\\SCHOOL-HOST\Laptop' -AuthMode WindowsCurrent -Adapter $script:adapter
        $script:connection.Unc | Should Be '\\SCHOOL-HOST\Laptop'
        $script:connection.UserName | Should Be 'SCHOOL-HOST\krusuea'
        ($script:connection.Password -ceq '') | Should Be $true
        $script:connection.Prompt | Should Be $false
    }

    It 'maps a drive with the same explicit passwordless account used to open UNC' {
        $script:connection = $null
        $script:adapter.GetBlankPasswordAccount = { 'krusuea' }
        $script:adapter.GetSession = { param($unc) 'SCHOOL-HOST\krusuea' }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connection = [pscustomobject]@{Unc=$unc;Local=$local;UserName=$userName;Password=$password}
            0
        }
        $map = Add-LanClientMap -Unc '\\SCHOOL-HOST\Laptop' -Letter 'P' -Persistent $true -AuthMode WindowsCurrent -Adapter $script:adapter
        $map.Letter | Should Be 'P'
        $script:connection.UserName | Should Be 'SCHOOL-HOST\krusuea'
        ($script:connection.Password -ceq '') | Should Be $true
        $script:connection.Local | Should Be 'P'
    }

    It 'uses the named account on the remote host even when local Windows account differs' {
        $script:connectedAs = $null
        $script:adapter.GetBlankPasswordAccount = { 'Ks' }
        $script:adapter.GetSession = { param($unc) 'KRUSUEAPC\KruSuea' }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connectedAs = "$userName|$password"
            0
        }
        Open-LanUnc -Path '\\KRUSUEAPC\PC' -AuthMode WindowsCurrent -WindowsAccount 'KruSuea' -Adapter $script:adapter
        $script:connectedAs | Should Be 'KRUSUEAPC\KruSuea|'
    }

    It 'maps with a named passwordless host account' {
        $script:connectedAs = $null
        $script:adapter.GetSession = { param($unc) 'KRUSUEAPC\KruSuea' }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connectedAs = "$userName|$password"
            0
        }
        Add-LanClientMap -Unc '\\KRUSUEAPC\PC' -Letter 'P' -Persistent $true -AuthMode WindowsCurrent -WindowsAccount 'KRUSUEAPC\KruSuea' -Adapter $script:adapter | Out-Null
        $script:connectedAs | Should Be 'KRUSUEAPC\KruSuea|'
    }

    It 'explains blocked insecure Guest fallback instead of showing an opaque 1272 error' {
        { Throw-LanWNetError 1272 } | Should Throw 'Guest'
    }

    It 'stores the share account in the Windows vault and removes it with the last mapping' {
        # Windows restores a persistent mapped drive at logon before this program runs, and only a vault
        # entry lets it do that without the "Enter network credentials" dialog. The entry must also go
        # away when the user unmaps the last drive that used that host, or a password stays behind.
        $script:written = New-Object System.Collections.ArrayList
        $script:removed = New-Object System.Collections.ArrayList
        $path = Join-Path $TestDrive 'vault.json'
            $script:adapter = @{
                StatePath=$path
                CredentialPath=(Join-Path $TestDrive 'vault-secrets.json')
                GetOccupiedLetters = { @('C','D') }
                Connect = { param($unc,$local,$persistent,$prompt,$userName,$password) 0 }
                Disconnect = { param($local,$update,$force) 0 }
                GetMapping = { param($local) $null }
                GetSession = { param($unc) 'HOST\LFS_abc' }
                LaunchExplorer = { param($path) }
                SetWindowsCredential = {
                    param($HostName,$UserName,$Password)
                    [void]$script:written.Add("$HostName|$UserName|$Password")
                    return $true
                }
                RemoveWindowsCredential = {
                    param($HostName)
                    [void]$script:removed.Add($HostName)
                    return $true
                }
            }
            $script:adapter.GetRememberedCredential = { param($h) $null }
            Add-LanClientMap -Unc '\\HOST\share' -Letter 'P' -Persistent $true -AuthMode Protected `
                -WindowsAccount 'LFS_abc' -Password 'Pw1!' -Adapter $script:adapter | Out-Null
            (@($script:written) -join ';') | Should Be 'HOST|HOST\LFS_abc|Pw1!'

            Remove-LanClientMap -Letter 'P' -ExpectedUnc '\\HOST\share' -Adapter $script:adapter | Out-Null
            (@($script:removed) -join ';') | Should Be 'HOST'
    }
    It 'reconnects saved mappings and leaves an existing connection alone' {
        # Windows restores a persistent mapping only when the sharing machine is reachable at logon, so a
        # laptop that starts first keeps a missing drive until someone connects by hand. This is what
        # makes a reboot need no attention.
        $path = Join-Path $TestDrive 'restore.json'
        Write-LanClientMappings -Path $path -Mappings @(
            [pscustomobject]@{Letter='P';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true},
            [pscustomobject]@{Letter='Q';Unc='\\HOST\other';AuthMode='Protected';Persistent=$true}
        )
        $credPath = Join-Path $TestDrive 'restore-cred.json'
        $seed = @{ CredentialPath=$credPath }
        Write-LanClientCredential -Adapter $seed -HostName 'HOST' -UserName 'LFS_x' -Password 'Pw1!' | Out-Null

        $script:attempts = New-Object System.Collections.ArrayList
        $script:log = New-Object System.Collections.ArrayList
        $script:restoredLetters = @{ P='\\HOST\share' }
        $adapter = @{
            StatePath=$path; CredentialPath=$credPath
            # P is already connected by Windows; Q is not.
            GetMapping = { param($l) $script:restoredLetters[$l] }
            ProbeAccess = { param($path) }
            Connect = { param($u,$l,$p,$pr,$n,$pw) [void]$script:attempts.Add("$l|$pw"); $script:restoredLetters[$l]=$u; 0 }
            GetRememberedCredential = { param($h) Get-LanRememberedCredential -HostName $h -Adapter $script:seedAdapter }
        }
        $script:seedAdapter = $adapter
        $summary = Restore-LanClientMappings -Adapter $adapter -Log { param($t) [void]$script:log.Add($t) }
        $summary.Total | Should Be 2
        # Only the missing one is connected, and with the stored password.
        (@($script:attempts) -join ',') | Should Be 'Q|Pw1!'
        @($summary.Connected) | Should Be @('Q')
        @($summary.Skipped) | Should Be @('P')
    }
    It 'clears the host connections and retries when 1219 is reported' {
        # Windows will not open a second session to one host with different credentials. The account of the
        # existing session cannot be read — WNetGetUser returns nothing for a session that a mapped drive
        # holds — so this is not conditional on that: whatever this user holds against the host is closed,
        # and the connection is attempted again.
        $script:events = New-Object System.Collections.ArrayList
        $script:attempts = 0
        $script:session = 'HOST\someone-else'
        $adapter = @{
            GetSession = { param($name) $script:session }
            # An empty drive list keeps the test off this machine's real drives. Without it the cleanup falls
            # back to scanning what is actually mapped, which made the assertions depend on the developer's
            # machine rather than on the code under test.
            GetNetworkDriveLetters = { @() }
            # Closing the connection really does end the session. The mock has to reflect that, or the
            # follow-up check would still see the old account and refuse to retry.
            Disconnect = { param($target,$update,$force) [void]$script:events.Add("disconnect:$target"); $script:session = $null; 0 }
        }
        $result = Clear-LanConflictingSession -Root '\\HOST\share' -Adapter $adapter -Local 'P' `
            -Persistent $true -Prompt $true -UserName 'HOST\LFS_abc' -Password 'pw' -Retry {
                param($r,$l,$p,$prompt,$u,$pw)
                $script:attempts++
                0
            }
        $result | Should Be 0
        # The bare host connection is closed, and the attempt is made again.
        # The held drive letter is released first, then the bare host session, then the retry.
        # The drive letter is released when its host cannot be reached, then the bare host session is closed.
        # The share and the bare host are cancelled, and the pass runs twice so a session that a drive letter
        # was holding is caught after the letter is released.
        (@($script:events) -join '|') | Should Be 'disconnect:\\HOST\share|disconnect:\\HOST|disconnect:\\HOST\share|disconnect:\\HOST'
        $script:attempts | Should Be 1
    }

    It 'uses the account stored for the host for every share on it' {
        # Windows keeps one credential per machine, so two drives to the same machine with different accounts can
        # only take turns failing — one closes the other's session to try its own. That is what "several shares
        # on one machine cannot be mapped at once" was. The stored account for the host therefore wins for every
        # share on it, and all of them connect together.
        $dir = Join-Path $TestDrive 'one-account'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $mapPath = Join-Path $dir 'maps.json'
        $credPath = Join-Path $dir 'creds.json'
        Write-LanClientCredential -Adapter @{ CredentialPath = $credPath } -HostName 'HOST' `
            -UserName 'HOST\LFS_good' -Password 'PwGood!' | Out-Null
        $script:mapped = @{}
        $script:used = New-Object System.Collections.ArrayList
        $script:seed = $null
        $adapter = @{
            StatePath = $mapPath; CredentialPath = $credPath
            GetOccupiedLetters = { @('C','D') }
            GetSession = { param($u) 'HOST\LFS_good' }
            Connect = { param($unc,$local,$p,$pr,$u,$pw) [void]$script:used.Add($u); $script:mapped[$local]=$unc; 0 }
            Disconnect = { param($t,$up,$f) $script:mapped.Remove($t); 0 }
            GetMapping = { param($l) $script:mapped[$l] }
            GetRememberedCredential = { param($h) Get-LanRememberedCredential -HostName $h -Adapter $script:seed }
        }
        $script:seed = $adapter
        Add-LanClientMap -Unc '\\HOST\Student2551J' -Letter 'Y' -Persistent $true -AuthMode Protected -WindowsAccount 'LFS_good' -Adapter $adapter | Out-Null
        # A different name typed with no password must not break the machine's account.
        Add-LanClientMap -Unc '\\HOST\BasicEducation' -Letter 'Z' -Persistent $true -AuthMode Protected -WindowsAccount 'LFS_other' -Adapter $adapter | Out-Null
        # And no name at all must work the same way.
        Add-LanClientMap -Unc '\\HOST\Third' -Letter 'W' -Persistent $true -AuthMode Protected -Adapter $adapter | Out-Null
        @($script:used | Select-Object -Unique) | Should Be @('HOST\LFS_good')
        $saved = @(Read-LanClientMappings -Path $mapPath)
        $saved.Count | Should Be 3
        @($saved | ForEach-Object { $_.WindowsAccount } | Select-Object -Unique) | Should Be @('HOST\LFS_good')
    }
    It 'keeps a working drive when asking to connect again answers 1219' {
        # 1219 means a session to that machine already exists. When it exists with the account this drive needs,
        # the drive is reachable already, and clearing it would drop a working connection and open it again —
        # which is what "the drive keeps dropping" looked like: a good share torn down every twenty seconds
        # because the automatic pass asked to connect and was told 1219.
        $dir = Join-Path $TestDrive 'keep-1219'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $mapPath = Join-Path $dir 'maps.json'
        $credPath = Join-Path $dir 'creds.json'
        Write-LanClientCredential -Adapter @{ CredentialPath = $credPath } -HostName 'HOST' `
            -UserName 'HOST\LFS_good' -Password 'Pw!' | Out-Null
        Write-LanClientMappings -Path $mapPath -Mappings @([pscustomobject]@{
            Letter='Z'; Unc='\\HOST\share'; Persistent=$true; AuthMode='Protected'
            WindowsAccount='HOST\LFS_good'; HostName='HOST'; Watched=$true })
        $script:cleared = 0
        $script:connected = 0
        $script:seed = $null
        $adapter = @{
            StatePath = $mapPath; CredentialPath = $credPath
            # The redirector finishes restoring the letter during Connect. A host session alone cannot
            # prove this letter exists, so the fake must model the mapped letter as well as readability.
            GetMapping = { param($l) if ($script:connected -gt 0) { '\\HOST\share' } else { '' } }
            GetSession = { param($u) 'HOST\LFS_good' }
            ProbeAccess = { param($p) [pscustomobject]@{ Ok = $true } }
            Connect = { param($unc,$local,$p,$pr,$u,$pw) $script:connected++; 1219 }
            Disconnect = { param($t,$up,$f) $script:cleared++; 0 }
            GetRememberedCredential = { param($h) Get-LanRememberedCredential -HostName $h -Adapter $script:seed }
        }
        $script:seed = $adapter
        # The drive is readable on this machine, so the pass must adopt the existing session.
        $summary = Repair-LanMonitoredMappings -Adapter $adapter -Log { param($t) }
        $script:cleared | Should Be 0
        @($summary.Waiting).Count | Should Be 0
    }
    It 'never removes a drive because its share could not be reached' {
        # The owner's rule: keep trying until it works, in any combination of states — one machine not ready,
        # neither ready, the network not ready, a different SSID or VLAN on each side. Removing the drive works
        # against that, and it is what told the user "the share was stopped" while both machines were simply
        # still starting. Only the owner stops watching a drive, with the button for it.
        $path = Join-Path $TestDrive 'keep.json'
        Write-LanClientMappings -Path $path -Mappings @([pscustomobject]@{Letter='E';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true})
        $script:disconnected = New-Object System.Collections.ArrayList
        $adapter = @{
            StatePath = $path
            GetNetworkDriveLetters = { @('E') }
            GetMapping = { param($l) '\\HOST\share' }
            Disconnect = { param($t,$u,$f) [void]$script:disconnected.Add($t); 0 }
        }
        # Windows still holds the drive, so nothing may be removed even though the share never answers.
        @(Remove-LanStaleMappings -Adapter $adapter).Count | Should Be 0
        @($script:disconnected).Count | Should Be 0
        @(Read-LanClientMappings -Path $path).Count | Should Be 1
    }

    It 'records that a drive is watched, and treats an unmarked drive as watched' {
        # The flag has to survive a restart, and a record saved by an older build has no flag at all — that
        # must mean "watched", or upgrading would silently stop watching every existing drive.
        $path = Join-Path $TestDrive 'watch.json'
        $adapter = @{ StatePath = $path }
        Write-LanClientMappings -Path $path -Mappings @(
            [pscustomobject]@{Letter='E';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true},
            [pscustomobject]@{Letter='G';Unc='\\HOST\other';AuthMode='Protected';Persistent=$true})
        # An unmarked record counts as watched.
        (Test-LanMappingWatched -Entry @(Read-LanClientMappings -Path $path)[0]) | Should Be $true
        (Set-LanMappingWatch -Letter 'E' -Watching $false -Adapter $adapter) | Should Be $true
        $saved = @(Read-LanClientMappings -Path $path)
        (Test-LanMappingWatched -Entry ($saved | Where-Object { $_.Letter -eq 'E' })) | Should Be $false
        (Test-LanMappingWatched -Entry ($saved | Where-Object { $_.Letter -eq 'G' })) | Should Be $true
        (Set-LanMappingWatch -Letter 'E' -Watching $true -Adapter $adapter) | Should Be $true
        (Test-LanMappingWatched -Entry (@(Read-LanClientMappings -Path $path) | Where-Object { $_.Letter -eq 'E' })) | Should Be $true
    }

    It 'tries a watched drive again on every pass and leaves an unwatched one alone' {
        # The connection check runs on a timer for the life of the window. A drive that is not connected is
        # attempted again; a drive the owner stopped watching is not touched at all.
        $path = Join-Path $TestDrive 'monitor.json'
        Write-LanClientMappings -Path $path -Mappings @(
            [pscustomobject]@{Letter='E';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true;Watching=$true},
            [pscustomobject]@{Letter='G';Unc='\\HOST\other';AuthMode='Protected';Persistent=$true;Watching=$false})
        $script:attempts = New-Object System.Collections.ArrayList
        $adapter = @{
            StatePath = $path
            GetRememberedCredential = { param($hostName,$context) [pscustomobject]@{UserName='HOST\reader';Password='fixture-only'} }
            GetMapping = { param($l) $null }
            # 1326 is "logon failure"; the saved password lets this unattended attempt run without a prompt.
            Connect = { param($unc,$local,$p,$pr,$u,$pw) [void]$script:attempts.Add($local); 1326 }
        }
        $report = Repair-LanMonitoredMappings -Adapter $adapter
        # E is watched and was attempted; G was not.
        (@($script:attempts) -join ',') | Should Be 'E'
        @($report.Waiting) | Should Be @('E')
        @($report.Connected).Count | Should Be 0
    }
    It 'keeps a drive whose state cannot be established, and removes only a proven dead one' {
        # Deleting a working drive is far worse than leaving a dead one. An earlier version answered true or
        # false and an ordinary failed read — a redirector that had not finished reconnecting, a share list
        # that could not be read — removed a drive that had been mapped successfully a minute earlier, which
        # is exactly what the owner reported. Three states make that impossible: only 'Dead' removes.
        (Get-Command Get-LanMappingState) | Should Not BeNullOrEmpty
        (Get-Command Test-LanShareAbsent) | Should Not BeNullOrEmpty
        # A letter Windows has no mapping for is definitely dead.
        (Get-LanMappingState -Letter 'Q' -ExpectedUnc '\\HOST\share' -Adapter @{}) | Should Be 'Dead'
        (Get-LanMappingState -Letter 'R' -ExpectedUnc '\\HOST\share' -Adapter @{}) | Should Be 'Dead'
    }

    It 'stops the cleanup from touching a caller that brings its own mappings' {
        # Update-LanClientMapList runs on every refresh, and a window built by a test describes mappings this
        # machine does not have. Without the flag the fixture's records would be deleted as "not held by
        # Windows" — true of the machine, and wrong for the caller's world.
        $path = Join-Path $TestDrive 'skip.json'
        Write-LanClientMappings -Path $path -Mappings @([pscustomobject]@{Letter='P';Unc='\\server\share';AuthMode='Protected';Persistent=$true})
        $adapter = @{ StatePath = $path; SkipLivenessCheck = $true }
        @(Remove-LanStaleMappings -Adapter $adapter).Count | Should Be 0
        @(Read-LanClientMappings -Path $path).Count | Should Be 1
    }
    It 'records everything needed to rebuild a mapping and can reuse it' {
        # The client form used to lose the path, the access mode, the host account and the password on every
        # restart, so the automatic reconnect had nothing to work from. The record must carry the account and
        # the password must be stored at the same moment, because this object is only built after the
        # connection has actually succeeded.
        $path = Join-Path $TestDrive 'record.json'
        $credPath = Join-Path $TestDrive 'record-cred.json'
        $script:mapped = @{}
        $adapter = @{
            StatePath = $path; CredentialPath = $credPath
            GetOccupiedLetters = { @('C','D') }
            Connect = { param($unc,$local,$persistent,$prompt,$userName,$password) $script:mapped[$local]=$unc; 0 }
            Disconnect = { param($local,$update,$force) $script:mapped.Remove($local); 0 }
            GetMapping = { param($local) $script:mapped[$local] }
            GetSession = { param($unc) 'HOST\LFS_abc' }
            ProbeAccess = { param($p)
                if ($p -in @('E:','E:\','\\HOST\share') -and $script:mapped['E'] -eq '\\HOST\share') { return }
                throw 'Fixture mapping is not readable.'
            }
        }
        $entry = Add-LanClientMap -Unc '\\HOST\share' -Letter 'E' -Persistent $true `
            -AuthMode Protected -WindowsAccount 'LFS_abc' -Password 'Pw1!' -Adapter $adapter
        $entry.WindowsAccount | Should Be 'HOST\LFS_abc'
        $entry.HostName | Should Be 'HOST'
        # Read back the way a restart would.
        $saved = @(Read-LanClientMappings -Path $path)[0]
        $saved.WindowsAccount | Should Be 'HOST\LFS_abc'
        $saved.AuthMode | Should Be 'Protected'
        $saved.HostName | Should Be 'HOST'
        $remembered = Get-LanRememberedCredential -HostName $saved.HostName -Adapter $adapter
        $remembered.Password | Should Be 'Pw1!'
        # And the automatic reconnect must succeed from the record alone.
        $script:mapped.Remove('E') | Out-Null
        $summary = Restore-LanClientMappings -Adapter $adapter
        @($summary.Connected) | Should Be @('E')
    }

    It 'reconnects a saved drive when Map Drive is pressed again on the same letter' {
        # After a repair has removed the connection the user presses Map Drive on the saved letter. Reporting
        # "this app already owns that drive letter" left them with no way forward exactly when they needed one.
        $path = Join-Path $TestDrive 'again.json'
        $credPath = Join-Path $TestDrive 'again-cred.json'
        $script:mapped = @{}
        $script:connects = 0
        $adapter = @{
            StatePath = $path; CredentialPath = $credPath
            GetOccupiedLetters = { @('C','D') }
            Connect = { param($unc,$local,$persistent,$prompt,$userName,$password) $script:connects++; $script:mapped[$local]=$unc; 0 }
            Disconnect = { param($local,$update,$force) $script:mapped.Remove($local); 0 }
            GetMapping = { param($local) $script:mapped[$local] }
            # Mapping checks the session identity after connecting, so the stub has to answer it.
            GetSession = { param($unc) 'HOST\LFS_abc' }
        }
        Add-LanClientMap -Unc '\\HOST\share' -Letter 'E' -Persistent $true `
            -AuthMode Protected -WindowsAccount 'LFS_abc' -Password 'Pw1!' -Adapter $adapter | Out-Null
        $script:mapped.Remove('E') | Out-Null
        $again = Add-LanClientMap -Unc '\\HOST\share' -Letter 'E' -Persistent $true `
            -AuthMode Protected -WindowsAccount 'LFS_abc' -Password 'Pw1!' -Adapter $adapter
        $again.Letter | Should Be 'E'
        $script:connects | Should Be 2
    }
    It 'releases a drive letter held by a mapping that no longer resolves' {
        # After a router or VLAN change a mapped drive can keep its letter while its target is unreachable.
        # GetMapping then answers nothing, so the reconnect believes the letter is free, tries to use it, and
        # Windows refuses with error 85 — the letter is never released and every later attempt fails the same
        # way. That is the failure the log showed with no error code at all.
        $path = Join-Path $TestDrive 'stale.json'
        Write-LanClientMappings -Path $path -Mappings @([pscustomobject]@{Letter='E';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true})
        $script:disconnected = New-Object System.Collections.ArrayList
        $adapter = @{
            StatePath = $path
            GetNetworkDriveLetters = { @('E') }   # this machine's own drives stay out of the test
            GetMapping = { param($l) $null }      # unreachable, so the redirector reports nothing
            Disconnect = { param($target,$update,$force) [void]$script:disconnected.Add($target); 0 }
        }
        $released = @(Clear-LanStaleNetworkMappings -Adapter $adapter)
        $released | Should Be @('E')
        (@($script:disconnected) -join ',') | Should Be 'E'
        # The record is kept, not deleted. Deleting on an unreachable host is what made a restart or a
        # network change lose the drive for good: the letter was freed but nothing was left to reconnect,
        # so the user had to map it again by hand every time.
        @(Read-LanClientMappings -Path $path).Count | Should Be 1
    }

    It 'keeps a mapping that still resolves' {
        $path = Join-Path $TestDrive 'healthy.json'
        Write-LanClientMappings -Path $path -Mappings @([pscustomobject]@{Letter='E';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true})
        $script:disconnected = New-Object System.Collections.ArrayList
        $adapter = @{
            StatePath = $path
            GetMapping = { param($l) '\\HOST\share' }
            Disconnect = { param($target,$update,$force) [void]$script:disconnected.Add($target); 0 }
        }
        @(Clear-LanStaleNetworkMappings -Adapter $adapter).Count | Should Be 0
        @($script:disconnected).Count | Should Be 0
        @(Read-LanClientMappings -Path $path).Count | Should Be 1
    }

    It 'tells a network move apart from stale credentials' {
        # The two need different repairs, and the error code alone does not say which, so reachability is
        # measured. An unreachable host reports that instead of silently closing connections.
        $path = Join-Path $TestDrive 'reach.json'
        Write-LanClientMappings -Path $path -Mappings @([pscustomobject]@{Letter='E';Unc='\\HOST-NOT-THERE\share';AuthMode='Protected';Persistent=$true})
        $adapter = @{
            StatePath = $path
            GetMapping = { param($l) '\\HOST-NOT-THERE\share' }
            Disconnect = { param($target,$update,$force) 0 }
        }
        $report = Repair-LanClientConnection -Adapter $adapter -Unc '\\HOST-NOT-THERE\share' -SkipConnect
        $report.HostReachable | Should Be $false
        $report.Message | Should Match 'HOST-NOT-THERE'
    }
    It 'cancels the connection entry as well as the drive letter' {
        # This is the failure the user hit: a share reached as \\HOST\Name without mapping a drive keeps its
        # session, WNetCancelConnection2 reports success and removes nothing, and every later attempt with
        # another account fails with 1219 for good. The repair therefore cancels each name through both the
        # Win32 call and Remove-SmbMapping, which is the one that works from a remote path.
        $script:events = New-Object System.Collections.ArrayList
        $adapter = @{
            StatePath = (Join-Path $TestDrive 'both.json')
            GetNetworkDriveLetters = { @() }
            GetMapping = { param($l) $null }
            Disconnect = { param($target,$update,$force) [void]$script:events.Add("wnet:$target"); 0 }
        }
        Write-LanClientMappings -Path $adapter.StatePath -Mappings @([pscustomobject]@{Letter='E';Unc='\\HOST\share';AuthMode='Protected';Persistent=$true})
        [void](Clear-LanHostConnections -HostName 'HOST' -Share 'share' -Adapter $adapter)
        $calls = @($script:events)
        # The share and the bare host are both cancelled, and each through the Win32 call.
        ($calls -contains 'wnet:\\HOST\share') | Should Be $true
        ($calls -contains 'wnet:\\HOST') | Should Be $true
    }

    It 'removes a connection entry by remote path' {
        # The helper is exercised against the real SMB client so a change in how Windows exposes the entry is
        # caught here rather than on a user's machine.
        (Get-Command Remove-LanConnectionEntry) | Should Not BeNullOrEmpty
        # Nothing is connected under this name, so the call reports that there was nothing to remove rather
        # than throwing.
        { Remove-LanConnectionEntry -Target '\\HOST-NOT-THERE\share' } | Should Not Throw
    }
    It 'treats an already-absent connection as closed rather than an error' {
        # Error 2250 means Windows holds nothing under that name. Repairing a conflicting session closes
        # connections that a later un-map may try to close again, and the user must not be shown a failure
        # for something that is already gone.
        $adapter = @{ Disconnect = { param($target,$update,$force) 2250 } }
        (Disconnect-LanQuietly -Adapter $adapter -Target 'E') | Should Be 0
        $adapter2 = @{ Disconnect = { param($target,$update,$force) 5 } }
        (Disconnect-LanQuietly -Adapter $adapter2 -Target 'E') | Should Be 5
    }
    It 'reaches its own remembered-credential helper through a real adapter' {
        # GetNewClosure captures values at creation time, so an adapter that referenced itself through
        # a variable assigned later ended up with $null and every button on the client tab failed with
        # "Cannot bind argument to parameter 'Adapter' because it is null". The adapter now reaches
        # itself through a script-scoped variable, and this test proves the closure can call it.
        $adapter = New-LanClientAdapter
        ($adapter.ContainsKey('GetRememberedCredential')) | Should Be $true
        # Must not throw, and must answer (null when nothing was saved for that host).
        $result = & $adapter.GetRememberedCredential 'NOSUCHHOST'
        ($null -eq $result) | Should Be $true
    }

    It 'reuses a saved password when the account is typed without the host prefix' {
        # The saved record is stored as HOST\name but the user may type just name. Comparing the whole
        # string made those look different and the saved password went unused, which produced
        # "Protected Password needs the password created on the sharing machine" on a return visit.
        $path = Join-Path $TestDrive 'prefix.json'
        $adapter = @{
            CredentialPath = $path
            GetRememberedCredential = { param($h) Get-LanRememberedCredential -HostName $h -Adapter $script:prefixAdapter }
        }
        $script:prefixAdapter = $adapter
        Write-LanClientCredential -Adapter $adapter -HostName 'HOST' -UserName 'HOST\LFS_abc' -Password 'Pw12345!' | Out-Null
        $resolved = Resolve-LanClientCredentials -Root '\\HOST\share' -AuthMode Protected -WindowsAccount 'LFS_abc' -Adapter $adapter
        $resolved.UserName | Should Be 'HOST\LFS_abc'
        $resolved.Password | Should Be 'Pw12345!'
    }
    It 'connects to a host whose Windows account names differ by using the share account' {
        # This is the case that used to be impossible: the two machines have no account in common, so
        # no WindowsCurrent arrangement can work. The sharing machine created its own account for the
        # share, and the user types that name and password here.
        $script:connectedAs = $null
        $script:adapter.CredentialPath = Join-Path $TestDrive 'credentials.json'
        $script:adapter.GetRememberedCredential = { param($hostName) $null }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connectedAs = "$userName|$password|$prompt"
            0
        }
        $script:adapter.GetSession = { param($unc) 'DESKTOP-FD84EJ1\LFS_abc123' }
        Add-LanClientMap -Unc '\\DESKTOP-FD84EJ1\BasicEducation' -Letter 'P' -Persistent $true `
            -AuthMode Protected -WindowsAccount 'LFS_abc123' -Password 'Secret123!' -Adapter $script:adapter | Out-Null
        $script:connectedAs | Should Be 'DESKTOP-FD84EJ1\LFS_abc123|Secret123!|True'
    }

    It 'remembers the share account so the next connection needs no typing' {
        $script:connectedAs = $null
        $path = Join-Path $TestDrive 'remembered.json'
        $script:adapter.CredentialPath = $path
        $script:adapter.GetRememberedCredential = { param($hostName) $null }
        $script:adapter.GetSession = { param($unc) 'DESKTOP-FD84EJ1\LFS_abc123' }
        $script:adapter.Connect = { param($unc,$local,$persistent,$prompt,$userName,$password) 0 }
        Add-LanClientMap -Unc '\\DESKTOP-FD84EJ1\BasicEducation' -Letter 'P' -Persistent $true `
            -AuthMode Protected -WindowsAccount 'LFS_abc123' -Password 'Secret123!' -Adapter $script:adapter | Out-Null
        (Test-Path -LiteralPath $path) | Should Be $true

        # A second connection with both fields empty must reuse what was stored, and the stored value
        # must not be the plain password.
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should Not Match 'Secret123!'
        $script:adapter.GetRememberedCredential = {
            param($hostName) Get-LanRememberedCredential -HostName $hostName -Adapter $script:adapter
        }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connectedAs = "$userName|$password"
            0
        }
        Add-LanClientMap -Unc '\\DESKTOP-FD84EJ1\BasicEducation' -Letter 'Q' -Persistent $true `
            -AuthMode Protected -Adapter $script:adapter | Out-Null
        $script:connectedAs | Should Be 'DESKTOP-FD84EJ1\LFS_abc123|Secret123!'
    }

    It 'asks for the password when a Protected share account is typed without one' {
        # A name with no password and nothing saved cannot connect, and the message must say which
        # one is missing rather than sending the user back to Windows.
        $script:adapter.CredentialPath = Join-Path $TestDrive 'no-credentials.json'
        $script:adapter.GetRememberedCredential = { param($hostName) $null }
        { Add-LanClientMap -Unc '\\host\share' -Letter 'P' -Persistent $true -AuthMode Protected `
            -WindowsAccount 'LFS_abc123' -Adapter $script:adapter } |
            Should Throw 'password'
        # With neither field filled the normal prompted logon must still be offered, exactly as it
        # was before the share account existed.
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $script:connectedAs = "$userName|$password|$prompt"
            0
        }
        $script:adapter.GetSession = { param($unc) 'HOST\alice' }
        Add-LanClientMap -Unc '\\host\share' -Letter 'P' -Persistent $true -AuthMode Protected -Adapter $script:adapter | Out-Null
        $script:connectedAs | Should Be '||True'
    }

    It 'names the host account and Protected Password in the Guest-fallback explanation' {
        # The advice has to match the situation, because the wrong advice is what made this error look
        # unfixable. With no account given and a password on the signed-in account, both real options
        # must be spelled out.
        $hint = Get-LanWindowsCurrentHint -Root '\\DESKTOP-FD84EJ1\BasicEducation' -HostAccountGiven $false `
            -Adapter @{ GetBlankPasswordAccount = { $null } }
        $hint | Should Match 'Protected Password'
        $hint | Should Match 'DESKTOP-FD84EJ1'
        $hint | Should Match 'ไม่มีรหัสผ่าน'
    }

    It 'reads the authenticated user from a deviceless UNC connection' {
        $query = {
            param($name,$buffer,[ref]$length)
            if ($name -ne '\\SCHOOL-HOST\Laptop') { throw 'Wrong connection name.' }
            [void]$buffer.Append('SCHOOL-HOST\krusuea')
            0
        }
        (Get-LanWNetUser -Name '\\SCHOOL-HOST\Laptop' -Query $query) | Should Be 'SCHOOL-HOST\krusuea'
    }

    It 'verifies a mapped drive by its drive letter' {
        $script:verifiedConnection = $null
        $script:adapter.GetSession = {
            param($connectionName)
            $script:verifiedConnection = $connectionName
            'SERVER\alice'
        }
        Add-LanClientMap -Unc '\\server\share' -Letter 'P' -Persistent $false -AuthMode WindowsCurrent -Adapter $script:adapter | Out-Null
        $script:verifiedConnection | Should Be 'P:'
    }

    It 'opens an existing WindowsCurrent session when error 1219 names the same user' {
        $script:adapter.GetBlankPasswordAccount = { $null }
        $script:adapter.GetCurrentIdentityName = { 'KRUSUEAPC\krusuea' }
        $script:adapter.GetLocalComputerName = { 'KRUSUEAPC' }
        $script:adapter.GetSession = { param($name) 'SCHOOL-HOST\krusuea' }
        $script:adapter.Connect = { param($unc,$local,$persistent,$prompt,$userName,$password) 1219 }
        Open-LanUnc -Path '\\SCHOOL-HOST\Laptop' -AuthMode WindowsCurrent -Adapter $script:adapter
        ($script:events -join ',') | Should Be 'explorer'
    }

    It 'opens a renamed share after 1219 when the old share owns the host session' {
        $script:attempts = New-Object System.Collections.ArrayList
        $script:connected = $false
        $script:adapter.GetBlankPasswordAccount = { $null }
        $script:adapter.GetCurrentIdentityName = { 'KRUSUEAPC\krusuea' }
        $script:adapter.GetLocalComputerName = { 'KRUSUEAPC' }
        $script:adapter.GetSession = {
            param($name)
            if ($script:connected -and $name -eq '\\SCHOOL-HOST\StudentJ2551') { return 'SCHOOL-HOST\krusuea' }
            return $null
        }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            [void]$script:attempts.Add([pscustomobject]@{Unc=$unc;UserName=$userName;Password=$password})
            if ($userName -eq 'SCHOOL-HOST\krusuea' -and $password -ceq '') {
                $script:connected = $true
                return 0
            }
            return 1219
        }
        Open-LanUnc -Path '\\SCHOOL-HOST\StudentJ2551' -AuthMode WindowsCurrent -Adapter $script:adapter
        $script:attempts.Count | Should Be 2
        $script:attempts[1].Unc | Should Be '\\SCHOOL-HOST\StudentJ2551'
        ($script:events -join ',') | Should Be 'explorer'
    }

    It 'maps a renamed share after 1219 without disconnecting the old share' {
        $script:attempts = New-Object System.Collections.ArrayList
        $script:adapter.GetBlankPasswordAccount = { $null }
        $script:adapter.GetCurrentIdentityName = { 'KRUSUEAPC\krusuea' }
        $script:adapter.GetLocalComputerName = { 'KRUSUEAPC' }
        $script:adapter.GetSession = { param($name) if ($name -eq 'P:') { 'SCHOOL-HOST\krusuea' } else { $null } }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            [void]$script:attempts.Add([pscustomobject]@{Unc=$unc;UserName=$userName;Password=$password})
            if ($userName -eq 'SCHOOL-HOST\krusuea' -and $password -ceq '') {
                $script:mapped[$local] = $unc
                return 0
            }
            return 1219
        }
        $map = Add-LanClientMap -Unc '\\SCHOOL-HOST\StudentJ2551' -Letter 'P' -Persistent $false -AuthMode WindowsCurrent -Adapter $script:adapter
        $map.Unc | Should Be '\\SCHOOL-HOST\StudentJ2551'
        $script:attempts.Count | Should Be 2
        @($script:events | Where-Object { $_ -like 'disconnect-*' }).Count | Should Be 0
    }

    It 'retries WindowsCurrent access denied with the same named account and an empty password' {
        $script:attempts = New-Object System.Collections.ArrayList
        $script:adapter.GetBlankPasswordAccount = { $null }
        $script:adapter.GetCurrentIdentityName = { 'KRUSUEAPC\krusuea' }
        $script:adapter.GetLocalComputerName = { 'KRUSUEAPC' }
        $script:adapter.GetSession = { param($name) 'SCHOOL-HOST\krusuea' }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            [void]$script:attempts.Add([pscustomobject]@{UserName=$userName;Password=$password})
            if ($userName) { return 0 }
            return 5
        }
        Open-LanUnc -Path '\\SCHOOL-HOST\Laptop' -AuthMode WindowsCurrent -Adapter $script:adapter
        $script:attempts.Count | Should Be 2
        $script:attempts[1].UserName | Should Be 'SCHOOL-HOST\krusuea'
        ($script:attempts[1].Password -ceq '') | Should Be $true
        ($script:events -join ',') | Should Be 'explorer'
    }

    It 'maps a drive after error 1219 when an existing session belongs to the same Windows user' {
        $script:attempts = New-Object System.Collections.ArrayList
        $script:adapter.GetBlankPasswordAccount = { $null }
        $script:adapter.GetCurrentIdentityName = { 'KRUSUEAPC\krusuea' }
        $script:adapter.GetLocalComputerName = { 'KRUSUEAPC' }
        $script:adapter.GetSession = { param($name) 'SCHOOL-HOST\krusuea' }
        $script:adapter.Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            [void]$script:attempts.Add([pscustomobject]@{UserName=$userName;Password=$password})
            if ($userName) { return 0 }
            return 1219
        }
        $map = Add-LanClientMap -Unc '\\SCHOOL-HOST\Laptop' -Letter 'P' -Persistent $false -AuthMode WindowsCurrent -Adapter $script:adapter
        $map.Letter | Should Be 'P'
        $script:attempts.Count | Should Be 2
        $script:attempts[1].UserName | Should Be 'SCHOOL-HOST\krusuea'
        ($script:attempts[1].Password -ceq '') | Should Be $true
    }

    It 'does not reuse an existing session belonging to another Windows user' {
        $script:adapter.GetBlankPasswordAccount = { $null }
        $script:adapter.GetCurrentIdentityName = { 'KRUSUEAPC\krusuea' }
        $script:adapter.GetLocalComputerName = { 'KRUSUEAPC' }
        $script:adapter.GetSession = { param($name) 'SCHOOL-HOST\someoneelse' }
        $script:adapter.Connect = { param($unc,$local,$persistent,$prompt,$userName,$password) 1219 }
        { Open-LanUnc -Path '\\SCHOOL-HOST\Laptop' -AuthMode WindowsCurrent -Adapter $script:adapter } | Should Throw
        $script:events.Count | Should Be 0
    }

    It 'restores app-changed client Guest policy after its last Guest mapping' {
        $script:guestAllowed = $false
        $script:adapter.GetGuestPolicy = { param($role) @{Managed=$false;RequireSigning=$false;RequireEncryption=$false;InsecureGuestAllowed=$script:guestAllowed;UnrelatedSharesAtRisk=@()} }
        $script:adapter.ApplyGuestChange = { param($role,$key,$value) $script:guestAllowed=$value }
        $script:adapter.GetSession = { param($unc) 'SERVER\Guest' }
        Enable-LanGuestConfiguration -Role Client -Adapter $script:adapter -StatePath $script:adapter.GuestStatePath | Out-Null
        Add-LanClientMap -Unc '\\server\share' -Letter 'U' -Persistent $false -AuthMode Guest -Adapter $script:adapter | Out-Null
        Remove-LanClientMap -Letter 'U' -ExpectedUnc '\\server\share' -Adapter $script:adapter | Out-Null
        $script:guestAllowed | Should Be $false
    }
    It 'defers Guest policy restoration until the elevated reset phase' {
        $script:guestAllowed = $false
        $script:adapter.GetGuestPolicy = { param($role) @{Managed=$false;RequireSigning=$false;RequireEncryption=$false;InsecureGuestAllowed=$script:guestAllowed;UnrelatedSharesAtRisk=@()} }
        $script:adapter.ApplyGuestChange = { param($role,$key,$value) $script:guestAllowed=$value }
        $script:adapter.GetSession = { param($unc) 'SERVER\Guest' }
        Enable-LanGuestConfiguration -Role Client -Adapter $script:adapter -StatePath $script:adapter.GuestStatePath | Out-Null
        Add-LanClientMap -Unc '\\server\share' -Letter 'V' -Persistent $false -AuthMode Guest -Adapter $script:adapter | Out-Null
        { Remove-LanClientMap -Letter 'V' -ExpectedUnc '\\server\share' -Adapter $script:adapter -SkipGuestRestore } | Should Not Throw
        $script:guestAllowed | Should Be $true
        Test-Path -LiteralPath $script:adapter.GuestStatePath | Should Be $true
    }
}
