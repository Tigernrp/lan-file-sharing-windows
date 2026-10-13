. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/ClientMap.ps1"
$script:originalVault = ${function:Set-LanWindowsCredential}

Describe 'Remembered client connections' {
    BeforeEach {
        Mock Set-LanWindowsCredential { $true }
        $script:live = @{}
        $script:offline = $false
        $script:opened = 0
        $script:disconnected = 0
        $script:attempts = New-Object Collections.ArrayList
        $script:a = @{
            StatePath = (Join-Path $TestDrive 'remembered-maps.json')
            CredentialPath = (Join-Path $TestDrive 'remembered-secrets.json')
            GetOccupiedLetters = { @('C','D') }
            GetMapping = { param($letter) $script:live[$letter] }
            GetSession = { param($name) 'HOST\reader' }
            ProbeAccess = { param($path) if ($script:offline) { throw 'Offline' } }
            Connect = { param($unc,$local,$persistent,$prompt,$user,$password)
                [void]$script:attempts.Add([pscustomobject]@{Unc=$unc;Letter=$local;Prompt=$prompt;User=$user;HasPassword=[bool]$password})
                if ($script:offline) { return 53 }
                if ($local) { $script:live[$local]=$unc }; 0
            }
            Disconnect = { param($name,$update,$force) $script:disconnected++; $script:live.Remove($name); 0 }
            GetNetworkDriveLetters = { @() }
            GetRememberedCredential = { param($hostName,$context) Get-LanRememberedCredential -HostName $hostName -Adapter $context }
            SetWindowsCredential = { param($hostName,$user,$password) $true }
            LaunchExplorer = { param($path) $script:opened++ }
        }
        foreach ($path in @($script:a.StatePath,$script:a.CredentialPath)) {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path) }
        }
    }

    It 'remembers the full UNC path only after successful validated reading' {
        $result = Open-LanUnc -Path '\\HOST\Data\term' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a
        $result.Remembered | Should Be $true
        $result.PersistenceWarning | Should Be ''
        $saved = @(Read-LanClientMappings $script:a.StatePath)
        $saved.Count | Should Be 1
        $saved[0].Letter | Should Be ''
        $saved[0].ConnectionKind | Should Be 'Unc'
        $saved[0].Unc | Should Be '\\HOST\Data'
        $saved[0].Path | Should Be '\\HOST\Data\term'
        $saved[0].WindowsAccount | Should Be 'HOST\reader'
        $saved[0].Watching | Should Be $true
        $saved[0].SavedAt | Should Match 'Z$'
        ([IO.File]::ReadAllText($script:a.CredentialPath)) | Should Not Match 'remember-test'
        ($result | ConvertTo-Json) | Should Not Match 'remember-test|HasPassword'
        $script:opened | Should Be 1
    }
    It 'reuses a remembered UNC account and password with no fields entered' {
        Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -Adapter $script:a | Out-Null
        $script:attempts[1].User | Should Be 'HOST\reader'
        $script:attempts[1].HasPassword | Should Be $true
        @(Read-LanClientMappings $script:a.StatePath).Count | Should Be 1
    }
    It 'does not remember or open a UNC path denied by the share' {
        $script:a.ProbeAccess = { param($path) throw [UnauthorizedAccessException]::new('Denied') }
        { Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a } | Should Throw
        @(Read-LanClientMappings $script:a.StatePath).Count | Should Be 0
        [IO.File]::Exists($script:a.CredentialPath) | Should Be $false
        $script:opened | Should Be 0
    }
    It 'keeps a connected UNC session and reports credential persistence failure' {
        [IO.File]::WriteAllText($script:a.CredentialPath,'broken-json')
        $result = Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a
        $result.Remembered | Should Be $false
        $result.PersistenceWarning | Should Not BeNullOrEmpty
        $result.PersistenceWarning | Should Not Match 'remember-test'
        [IO.File]::ReadAllText($script:a.CredentialPath) | Should Be 'broken-json'
        $script:opened | Should Be 1
        $script:disconnected | Should Be 0
    }
    It 'keeps an unreadable encrypted credential without overwriting it' {
        [IO.File]::WriteAllText($script:a.CredentialPath,'{"OTHER":"dpapi-machine:invalid"}')
        { Write-LanClientCredential -Adapter $script:a -HostName HOST -UserName 'HOST\reader' -Password 'remember-test' } | Should Throw
        [IO.File]::ReadAllText($script:a.CredentialPath) | Should Be '{"OTHER":"dpapi-machine:invalid"}'
    }
    It 'preserves peer ciphertext while replacing another remembered host' {
        Write-LanClientCredential -Adapter $script:a -HostName OTHER -UserName 'OTHER\reader' -Password 'other-test' | Out-Null
        $before = (ConvertFrom-Json ([IO.File]::ReadAllText($script:a.CredentialPath))).OTHER
        Write-LanClientCredential -Adapter $script:a -HostName HOST -UserName 'HOST\reader' -Password 'remember-test' | Out-Null
        ((ConvertFrom-Json ([IO.File]::ReadAllText($script:a.CredentialPath))).OTHER -ceq $before) | Should Be $true
    }
    It 'writes Windows credentials through a native structure without command line secrets' {
        $script:vaultRecordCorrect = $false
        $query = {
            param($credential)
            $record = [Runtime.InteropServices.Marshal]::PtrToStructure($credential,[type][LanCredentialNative+Credential])
            $passwordBytes = New-Object byte[] ([int]$record.CredentialBlobSize)
            [Runtime.InteropServices.Marshal]::Copy($record.CredentialBlob,$passwordBytes,0,$passwordBytes.Length)
            $script:vaultRecordCorrect = ($record.Type -eq 2 -and $record.Persist -eq 2 -and
                [Runtime.InteropServices.Marshal]::PtrToStringUni($record.TargetName) -eq 'HOST' -and
                [Runtime.InteropServices.Marshal]::PtrToStringUni($record.UserName) -eq 'HOST\reader' -and
                [Text.Encoding]::Unicode.GetString($passwordBytes) -eq 'remember-test')
            [Array]::Clear($passwordBytes,0,$passwordBytes.Length)
            $true
        }
        # Call the original function: BeforeEach mocks the default vault path used by connection tests.
        & $script:originalVault -HostName HOST -UserName 'HOST\reader' -Password 'remember-test' -Query $query | Should Be $true
        $script:vaultRecordCorrect | Should Be $true
    }
    It 'retains the previous saved drive when reconnecting that letter fails' {
        Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        $script:offline = $true
        { Add-LanClientMap -Unc '\\HOST\Other' -Letter P -AuthMode Protected -Adapter $script:a } | Should Throw
        $saved = @(Read-LanClientMappings $script:a.StatePath)
        $saved.Count | Should Be 1
        $saved[0].Unc | Should Be '\\HOST\Data'
    }
    It 'reports a saved-drive write failure without disconnecting the successful session' {
        $script:a.Connect = { param($unc,$local,$persistent,$prompt,$user,$password)
            $script:live[$local] = $unc
            [IO.Directory]::CreateDirectory($script:a.StatePath) | Out-Null
            0
        }
        $result = Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a
        $result.Remembered | Should Be $false
        $result.PersistenceWarning | Should Not BeNullOrEmpty
        $script:live.P | Should Be '\\HOST\Data'
        $script:disconnected | Should Be 0
        [IO.Directory]::Delete($script:a.StatePath)
    }
    It 'reconnects a watched UNC profile after offline becomes ready without opening Explorer' {
        Open-LanUnc -Path '\\HOST\Data\term' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        $script:opened = 0; $script:offline = $true
        $waiting = Repair-LanMonitoredMappings -Adapter $script:a
        @($waiting.Waiting) | Should Be @('\\HOST\Data\term')
        $script:offline = $false
        $ready = Repair-LanMonitoredMappings -Adapter $script:a
        @($ready.Connected) | Should Be @('\\HOST\Data\term')
        $script:attempts[-1].Letter | Should BeNullOrEmpty
        $script:attempts[-1].User | Should Be 'HOST\reader'
        $script:attempts[-1].HasPassword | Should Be $true
        $script:attempts[-1].Prompt | Should Be $false
        $script:opened | Should Be 0
    }
    It 'persists UNC watch changes without altering a mapped drive at the same host' {
        Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -Adapter $script:a | Out-Null
        Set-LanMappingWatch -Unc '\\HOST\Data' -Watching $false -Adapter $script:a | Should Be $true
        $entries = @(Read-LanClientMappings $script:a.StatePath)
        ($entries | Where-Object { -not $_.Letter }).Watching | Should Be $false
        ($entries | Where-Object Letter -eq 'P').Watching | Should Be $true
        Remove-LanClientMap -Letter '' -ExpectedUnc '\\HOST\Data' -Adapter $script:a | Out-Null
        @(Read-LanClientMappings $script:a.StatePath).Count | Should Be 1
        $script:live.P | Should Be '\\HOST\Data'
        $script:disconnected | Should Be 0
        (Get-LanRememberedCredential -HostName HOST -Adapter $script:a).UserName | Should Be 'HOST\reader'
    }
    It 'does not claim error 1219 connected when the saved letter is absent' {
        Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        $script:live.Clear()
        $script:a.Connect = { param($unc,$local,$persistent,$prompt,$user,$password) 1219 }
        $report = Repair-LanMonitoredMappings -Adapter $script:a
        @($report.Connected).Count | Should Be 0
        @($report.Waiting) | Should Be @('P')
        $restore = Restore-LanClientMappings -Adapter $script:a
        @($restore.Connected).Count | Should Be 0
        $script:disconnected | Should Be 0
    }
    It 'assigns the missing letter by reusing the same account session without clearing it' {
        Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        $script:live.Clear(); $script:attempts.Clear()
        $script:a.Connect = { param($unc,$local,$persistent,$prompt,$user,$password)
            [void]$script:attempts.Add([pscustomobject]@{User=$user;HasPassword=[bool]$password;Prompt=$prompt})
            if ($user) { return 1219 }
            $script:live[$local] = $unc; 0
        }
        $report = Repair-LanMonitoredMappings -Adapter $script:a
        @($report.Connected) | Should Be @('P')
        $script:live.P | Should Be '\\HOST\Data'
        $script:attempts.Count | Should Be 2
        $script:attempts[1].HasPassword | Should Be $false
        $script:attempts[1].Prompt | Should Be $false
        $script:disconnected | Should Be 0
    }
    It 'maps another share by reusing the same account session without clearing its first drive' {
        Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        $script:a.Connect = { param($unc,$local,$persistent,$prompt,$user,$password)
            if ($user) { return 1219 }
            $script:live[$local] = $unc; 0
        }
        $result = Add-LanClientMap -Unc '\\HOST\Other' -Letter Q -AuthMode Protected -Adapter $script:a
        $result.Remembered | Should Be $true
        $script:live.P | Should Be '\\HOST\Data'
        $script:live.Q | Should Be '\\HOST\Other'
        $script:disconnected | Should Be 0
    }
    It 'adopts an existing same-account UNC session after 1219 without closing a mapped drive' {
        Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        $script:a.Connect = { param($unc,$local,$persistent,$prompt,$user,$password) 1219 }
        $result = Open-LanUnc -Path '\\HOST\Other' -AuthMode Protected -Adapter $script:a
        $result.Remembered | Should Be $true
        $script:live.P | Should Be '\\HOST\Data'
        $script:disconnected | Should Be 0
    }
    It 'restores remembered UNC profiles without prompting and honours stopped watching' {
        Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a | Out-Null
        Open-LanUnc -Path '\\HOST\Other' -AuthMode Protected -Adapter $script:a | Out-Null
        Set-LanMappingWatch -Unc '\\HOST\Other' -Watching $false -Adapter $script:a | Out-Null
        $script:attempts.Clear(); $script:opened = 0
        $report = Restore-LanClientMappings -Adapter $script:a
        @($report.Connected) | Should Be @('\\HOST\Data')
        @($report.Skipped) | Should Be @('\\HOST\Other')
        $script:attempts.Count | Should Be 1
        $script:attempts[0].Prompt | Should Be $false
        $script:opened | Should Be 0
    }
    It 'blocks a remembered Online UNC before secrets are read if its address changes owner' {
        $script:online = [pscustomobject]@{OnlineEnabled=$true;ConnectionState='Connected';InterfaceId='vpn';LocalAddress='100.80.0.1';LocalPeerIdentity='owner';ManagementUrl='https://api.netbird.io:443';ProfileName='default';Peers=@([pscustomobject]@{Identity='teacher';Name='Teacher';Address='100.80.0.2'})}
        Write-LanClientMappings -Path $script:a.StatePath -Mappings @([pscustomobject]@{Letter='';ConnectionKind='Unc';Unc='\\100.80.0.2\Data';Path='\\100.80.0.2\Data';AuthMode='Protected';WindowsAccount='TEACHER\reader';Watching=$true;Transport='NetBird';OnlinePeerIdentity='teacher';OnlineBinding=(Get-LanOnlineBinding $script:online)})
        $script:online.Peers[0].Identity = 'stranger'
        $script:a.GetOnlineStatus = { $script:online }
        $script:secretReads = 0
        $script:a.GetRememberedCredential = { param($hostName,$context) $script:secretReads++; throw 'Secrets must remain unread' }
        $report = Repair-LanMonitoredMappings -Adapter $script:a
        @($report.Waiting) | Should Be @('\\100.80.0.2\Data')
        { Open-LanUnc -Path '\\100.80.0.2\Other' -AuthMode Protected -Adapter $script:a } | Should Throw
        $script:secretReads | Should Be 0
        $script:attempts.Count | Should Be 0
    }
    It 'saves credentials beside an explicit state file when no credential path is supplied' {
        $script:a.Remove('CredentialPath')
        $expected = Join-Path $TestDrive 'credentials.json'
        # Validate the isolated boundary first, so a broken implementation cannot write a fixture to
        # the real user's default credential store during this regression test.
        Get-LanClientCredentialPath -Adapter $script:a | Should Be $expected
        $result = Open-LanUnc -Path '\\HOST\Data' -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a
        $result.Remembered | Should Be $true
        [IO.File]::Exists($expected) | Should Be $true
        (Get-LanRememberedCredential -HostName HOST -Adapter $script:a).UserName | Should Be 'HOST\reader'
    }
    It 'waits silently when an unattended Protected profile has no saved password' {
        Write-LanClientMappings -Path $script:a.StatePath -Mappings @([pscustomobject]@{Letter='P';Unc='\\HOST\Data';AuthMode='Protected';WindowsAccount='';Watching=$true})
        $report = Repair-LanMonitoredMappings -Adapter $script:a
        @($report.Waiting) | Should Be @('P')
        $script:attempts.Count | Should Be 0
    }
    It 'remembers the app profile when optional Windows vault saving fails and reports the warning' {
        $script:a.SetWindowsCredential = { param($hostName,$user,$password) $false }
        $result = Add-LanClientMap -Unc '\\HOST\Data' -Letter P -AuthMode Protected -WindowsAccount reader -Password 'remember-test' -Adapter $script:a
        $result.Remembered | Should Be $true
        $result.PersistenceWarning | Should Not BeNullOrEmpty
        $script:live.Clear()
        $restored = Restore-LanClientMappings -Adapter $script:a
        @($restored.Connected) | Should Be @('P')
        $script:attempts[-1].HasPassword | Should Be $true
        $script:attempts[-1].Prompt | Should Be $false
    }
}
