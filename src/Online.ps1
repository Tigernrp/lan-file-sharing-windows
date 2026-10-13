function New-LanOnlineSettings {
    return [pscustomobject]@{Version=1;Enabled=$false;Binding=$null;AllowedPeers=@();LastKnownInterface=$null}
}

function New-LanOnlineStatusModel {
    param([string]$State='MissingClient',[string]$Error)
    return [pscustomobject]@{Installed=$false;OnlineEnabled=$false;ConnectionState=$State;LocalAddress=$null;LocalPeerIdentity=$null;
        ManagementUrl=$null;ProfileName=$null;InterfaceId=$null;InterfaceAlias=$null;Peers=@();Error=$Error}
}

function Test-LanOnlinePublicKey {
    param([string]$Key)
    try { return ($Key -and [Convert]::FromBase64String($Key).Length -eq 32) } catch { return $false }
}

function ConvertTo-LanOnlineAddress {
    param([string]$Address)
    $text=$Address.Split('/')[0]
    $ip=$null
    if (-not [Net.IPAddress]::TryParse($text,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ip.ToString() -cne $text -or [Net.IPAddress]::IsLoopback($ip) -or $ip.GetAddressBytes()[0] -eq 0 -or $ip.GetAddressBytes()[0] -ge 224) {
        throw 'Invalid Online IPv4 address.'
    }
    return $ip.ToString()
}

function ConvertFrom-LanNetBirdStatus {
    param([string]$Json)
    $s=New-LanOnlineStatusModel -State Unsupported
    $s.Installed=$true
    $decoded=$false
    try {
        $raw=ConvertFrom-Json -InputObject $Json -ErrorAction Stop
        $decoded=$true
        if ($raw.daemonStatus -in @('NeedsLogin','LoginFailed','SessionExpired')) { $s.ConnectionState='NotEnrolled'; return $s }
        if ($raw.daemonStatus -in @('Idle','Connecting')) { $s.ConnectionState=$(if($raw.daemonStatus -eq 'Idle'){'Disconnected'}else{'Connecting'}); return $s }
        if ($raw.management.connected -isnot [bool] -or $raw.signal.connected -isnot [bool]) { throw 'Unsupported NetBird status schema.' }
        if (-not (Test-LanOnlinePublicKey $raw.publicKey)) { throw 'NetBird status has no valid local identity. Update NetBird.' }
        $s.LocalAddress=ConvertTo-LanOnlineAddress ([string]$raw.netbirdIp)
        $s.LocalPeerIdentity=[string]$raw.publicKey
        $uri=$null
        if (-not [Uri]::TryCreate([string]$raw.management.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https') { throw 'Invalid management identity.' }
        $s.ManagementUrl=$uri.AbsoluteUri.TrimEnd('/')
        $s.ProfileName=[string]$raw.profileName
        $identities=@{}; $addresses=@{}; $peers=@()
        foreach ($p in @($raw.peers.details | Where-Object { $null -ne $_ })) {
            if (-not (Test-LanOnlinePublicKey ([string]$p.publicKey))) { throw 'Invalid peer identity.' }
            $address=ConvertTo-LanOnlineAddress ([string]$p.netbirdIp)
            if ($identities.ContainsKey([string]$p.publicKey) -or $addresses.ContainsKey($address)) { throw 'Ambiguous peer identity or address.' }
            $identities[[string]$p.publicKey]=$true; $addresses[$address]=$true
            $type=if ($p.status -eq 'Connected' -and $p.connectionType -eq 'P2P') { 'P2P' }
                elseif ($p.status -eq 'Connected' -and $p.connectionType -in @('Relayed','Relay')) { 'Relay' } else { 'Unknown' }
            $latency=$null
            if ($p.latency -is [ValueType] -and [double]$p.latency -ge 0) { $latency=[double]$p.latency/1000000 }
            $peers+= [pscustomobject]@{Identity=[string]$p.publicKey;Name=[string]$p.fqdn;Address=$address;ConnectionState=[string]$p.status;ConnectionType=$type;LatencyMilliseconds=$latency}
        }
        $s.Peers=$peers
        $s.ConnectionState=if ($raw.daemonStatus -eq 'Connected' -and $raw.management.connected -and $raw.signal.connected) { 'Connected' } else { 'Disconnected' }
    } catch {
        $s=New-LanOnlineStatusModel -State $(if ($decoded) {'Unsupported'}else{'Error'}) -Error $_.Exception.Message
        $s.Installed=$true
    }
    return $s
}

function Get-LanOnlineBinding {
    param($Status)
    return [pscustomobject]@{ManagementUrl=$Status.ManagementUrl;LocalPeerIdentity=$Status.LocalPeerIdentity;ProfileName=$Status.ProfileName}
}

function Test-LanOnlineBinding {
    param($Expected,$Actual)
    return ($Expected -and $Actual -and $Expected.LocalPeerIdentity -ceq $Actual.LocalPeerIdentity -and
        $Expected.ManagementUrl -ieq $Actual.ManagementUrl -and $Expected.ProfileName -ceq $Actual.ProfileName)
}

function Assert-LanNetBirdClient {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)} | Where-Object { $_ })
    $root=@($roots | Where-Object { [string]::Equals((Join-Path $_ 'NetBird\netbird.exe'),$full,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
    if (-not $root -or -not [IO.File]::Exists($full)) { throw 'NetBird must be installed in a trusted Program Files directory.' }
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $writeMask=278 # WriteData, AppendData, WriteEA, WriteAttributes
    $writeMask=$writeMask -bor 65536 -bor 262144 -bor 524288
    $current=$full
    while ($true) {
        $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NetBird path is not trusted: reparse point.' }
        $acl=Get-Acl -LiteralPath $current -ErrorAction Stop
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'NetBird path has an untrusted owner.' }
        foreach ($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin $trusted -and
                -not ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and ([int]$ace.FileSystemRights -band $writeMask)) {
                throw 'NetBird path permits untrusted writes.'
            }
        }
        if ([string]::Equals($current,$root,[StringComparison]::OrdinalIgnoreCase)) { break }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function Invoke-LanOnlineNativeProcess {
    param([string]$Path,[string]$Arguments,[hashtable]$Environment=@{},[int]$TimeoutMilliseconds=5000)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Path; $info.Arguments=$Arguments; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($k in $Environment.Keys) { $info.EnvironmentVariables[$k]=[string]$Environment[$k] }
    $p=New-Object Diagnostics.Process; $p.StartInfo=$info
    try {
        [void]$p.Start()
        $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMilliseconds)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ExitCode=-1;Stdout='';Stderr='NetBird command timed out.';TimedOut=$true}
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($out,$err),1000)) {
            return [pscustomobject]@{ExitCode=-1;Stdout='';Stderr='NetBird output did not close.';TimedOut=$true}
        }
        return [pscustomobject]@{ExitCode=$p.ExitCode;Stdout=$out.Result;Stderr=$err.Result;TimedOut=$false}
    } finally { $p.Dispose(); foreach ($k in $Environment.Keys) { $info.EnvironmentVariables.Remove($k) } }
}

function Invoke-LanNetBirdProcess {
    param([ValidateSet('Status','Up','SignIn')][string]$Operation,[string]$SetupKey,[int]$TimeoutMilliseconds=5000,[hashtable]$Adapter)
    if ($SetupKey -and ($SetupKey.Length -gt 4096 -or $SetupKey -match '[\x00-\x1f\x7f]')) { throw 'Invalid registration key.' }
    $path=& $Adapter.FindClient
    if (-not $path) { throw 'NetBird is not installed.' }
    & $Adapter.AssertTrustedClient $path
    $args=switch($Operation){Status{'status --json'} Up{'up --no-browser'} SignIn{'up'}}
    $envMap=@{}
    if ($SetupKey) { $envMap.NB_SETUP_KEY=$SetupKey }
    try {
        $r=& $Adapter.RunProcess $path $args $envMap $TimeoutMilliseconds
        return [pscustomobject]@{ExitCode=[int]$r.ExitCode;TimedOut=[bool]$r.TimedOut;
            Stdout=$(if($SetupKey){([string]$r.Stdout).Replace($SetupKey,'[redacted]')}else{[string]$r.Stdout});
            Stderr=$(if($SetupKey){([string]$r.Stderr).Replace($SetupKey,'[redacted]')}else{[string]$r.Stderr})}
    } finally { $envMap.Clear() }
}

function New-LanOnlineAdapter {
    return @{
        FindClient={ foreach ($root in @($env:ProgramFiles,${env:ProgramFiles(x86)} | Where-Object { $_ })) {
            $p=Join-Path $root 'NetBird\netbird.exe'; if ([IO.File]::Exists($p)) { return $p }
        } }
        AssertTrustedClient={param($p) Assert-LanNetBirdClient $p}
        RunProcess={param($p,$a,$e,$t) Invoke-LanOnlineNativeProcess -Path $p -Arguments $a -Environment $e -TimeoutMilliseconds $t}
        GetClock={ [DateTime]::UtcNow }
        GetInterfaceAddresses={
            foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
                $nic=Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -IncludeHidden -ErrorAction SilentlyContinue
                if ($nic -and ($nic.InterfaceDescription -match 'WireGuard|NetBird' -or $nic.Name -eq 'wt0')) {
                    [pscustomobject]@{InterfaceAlias=[string]$nic.Name;InterfaceId=[string]$nic.InterfaceGuid;Address=[string]$ip.IPAddress}
                }
            }
        }
    }
}

function Get-LanOnlineStatus {
    param([hashtable]$Adapter,[switch]$Force)
    if (-not $Adapter) { $Adapter=New-LanOnlineAdapter }
    $now=& $Adapter.GetClock
    if (-not $Force -and $Adapter.Cache -and ($now-$Adapter.CacheTime).TotalMilliseconds -lt 5000) { return $Adapter.Cache }
    $s=New-LanOnlineStatusModel
    try {
        if (& $Adapter.FindClient) {
            $r=Invoke-LanNetBirdProcess -Operation Status -Adapter $Adapter
            if ($r.ExitCode -ne 0 -or $r.TimedOut) { throw $(if($r.Stderr){$r.Stderr}else{'NetBird status unavailable.'}) }
            $s=ConvertFrom-LanNetBirdStatus $r.Stdout
            if ($s.LocalAddress) {
                $matches=@(& $Adapter.GetInterfaceAddresses | Where-Object { $_.Address -eq $s.LocalAddress -and $_.InterfaceId -and $_.InterfaceAlias })
                if ($matches.Count -ne 1) { throw 'Cannot verify the NetBird interface and address.' }
                $s.InterfaceId=[string]$matches[0].InterfaceId; $s.InterfaceAlias=[string]$matches[0].InterfaceAlias
            }
        }
    } catch { $s=New-LanOnlineStatusModel -State Error -Error $_.Exception.Message; $s.Installed=$true }
    $Adapter.Cache=$s; $Adapter.CacheTime=$now
    return $s
}

function Register-LanOnlineMachine {
    param([string]$SetupKey,[hashtable]$Adapter)
    if ([string]::IsNullOrWhiteSpace($SetupKey)) { throw 'Registration key is required.' }
    if (-not $Adapter) { $Adapter=New-LanOnlineAdapter }
    $r=Invoke-LanNetBirdProcess -Operation Up -SetupKey $SetupKey -TimeoutMilliseconds 60000 -Adapter $Adapter
    if ($r.ExitCode -ne 0 -or $r.TimedOut) { throw $(if($r.Stderr){$r.Stderr}else{'NetBird registration failed.'}) }
    return Get-LanOnlineStatus -Adapter $Adapter -Force
}

function Connect-LanOnlineMachineInteractive {
    param([hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=New-LanOnlineAdapter }
    $r=Invoke-LanNetBirdProcess -Operation SignIn -TimeoutMilliseconds 300000 -Adapter $Adapter
    if ($r.ExitCode -ne 0 -or $r.TimedOut) { throw $(if($r.Stderr){$r.Stderr}else{'NetBird sign in did not complete.'}) }
    return Get-LanOnlineStatus -Adapter $Adapter -Force
}

function Assert-LanOnlineSetupPlatform {
    param([hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=New-LanOnlineSetupAdapter }
    if (-not (& $Adapter.IsWindows)) { throw 'Automatic Online setup supports Windows only.' }
    if (-not (& $Adapter.Is64Bit)) { throw 'Automatic Online setup requires 64-bit Windows.' }
    $version=[version](& $Adapter.OsVersion)
    if ($version.Major -lt 10) { throw 'Automatic Online setup requires Windows 10 or Windows 11.' }
}

function Get-LanNetBirdStableInstallerUri {
    return [uri]'https://pkgs.netbird.io/windows/msi/x64'
}

function Assert-LanNetBirdInstallerUri {
    param([Parameter(Mandatory)][string]$Uri)
    $parsed=$null
    if (-not [uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$parsed) -or $parsed.Scheme -cne 'https' -or $parsed.UserInfo) {
        throw 'NetBird installer URL is not trusted.'
    }
    $dnsHost=$parsed.DnsSafeHost.ToLowerInvariant()
    $path=$parsed.AbsolutePath
    $allowed=($dnsHost -eq 'pkgs.netbird.io' -and $path -eq '/windows/msi/x64') -or
        ($dnsHost -eq 'github.com' -and $path -match '^/netbirdio/netbird/releases/download/[^/]+/[^/]+_windows_amd64\.msi$') -or
        ($dnsHost -eq 'release-assets.githubusercontent.com')
    if (-not $allowed) { throw 'NetBird installer URL is not an approved official x64 package.' }
    return $parsed
}

function Assert-LanNetBirdInstallerSignature {
    param([Parameter(Mandatory)][string]$Path,[hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=New-LanOnlineSetupAdapter }
    $signature=& $Adapter.GetSignature $Path
    $subject=if($signature.SignerCertificate){[string]$signature.SignerCertificate.Subject}else{''}
    if ([string]$signature.Status -ne 'Valid' -or $subject -notmatch '(?i)NetBird|Wiretrustee') {
        throw 'NetBird installer signature is missing, invalid, or has an unexpected publisher.'
    }
    return $signature
}

function Install-LanNetBirdMsi {
    param([Parameter(Mandatory)][string]$Path,[hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=New-LanOnlineSetupAdapter }
    Assert-LanNetBirdInstallerSignature -Path $Path -Adapter $Adapter | Out-Null
    $full=[IO.Path]::GetFullPath($Path)
    $arguments='/i "'+$full+'" /qn /norestart'
    $result=& $Adapter.RunInstaller $env:SystemRoot\System32\msiexec.exe $arguments
    if ([int]$result.ExitCode -notin @(0,3010)) {
        $detail=@([string]$result.Stderr,[string]$result.Stdout | Where-Object { $_ }) -join ' '
        throw ('NetBird silent installation failed with code '+[int]$result.ExitCode+'. '+$detail).Trim()
    }
    return $result
}

function Repair-LanNetBirdService {
    param([Parameter(Mandatory)][string]$ClientPath,[hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=New-LanOnlineSetupAdapter }
    if (& $Adapter.ProbeDaemon) { return [pscustomobject]@{RepairMode='AlreadyHealthy';DaemonAnswered=$true} }
    $mode='InstalledService'
    if (& $Adapter.ServiceExists) {
        $mode='RecreatedService'
        [void](& $Adapter.RunClient $ClientPath 'service stop')
        $remove=& $Adapter.RunClient $ClientPath 'service uninstall'
        $missing=[bool](& $Adapter.WaitServiceMissing)
        if ([int]$remove.ExitCode -ne 0 -or -not $missing) {
            if (-not $Adapter.ForceDeleteService) { throw 'The stale NetBird service could not be removed.' }
            & $Adapter.ForceDeleteService | Out-Null
            if (-not (& $Adapter.WaitServiceMissing)) { throw 'The stale NetBird service could not be removed.' }
        }
    }
    [void](& $Adapter.RunClient $ClientPath 'service reset-params')
    $install=& $Adapter.RunClient $ClientPath 'service install'
    if ([int]$install.ExitCode -ne 0) { throw ('NetBird service installation failed. '+[string]$install.Stderr).Trim() }
    $start=& $Adapter.RunClient $ClientPath 'service start'
    if ([int]$start.ExitCode -ne 0 -and ([string]$start.Stderr+[string]$start.Stdout) -notmatch '(?i)already running') {
        throw ('NetBird service could not start. '+[string]$start.Stderr).Trim()
    }
    foreach($attempt in 1..20) {
        if (& $Adapter.ProbeDaemon) { return [pscustomobject]@{RepairMode=$mode;DaemonAnswered=$true} }
        & $Adapter.Sleep 500
    }
    throw 'NetBird service started but its daemon did not answer.'
}

function New-LanOnlineSetupAdapter {
    return @{
        IsWindows={ $env:OS -eq 'Windows_NT' }
        Is64Bit={ [Environment]::Is64BitOperatingSystem }
        OsVersion={ [Environment]::OSVersion.Version }
        DownloadInstaller={param($uri,$path)
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            Add-Type -AssemblyName System.Net.Http | Out-Null
            $handler=New-Object Net.Http.HttpClientHandler
            $handler.AllowAutoRedirect=$true;$handler.MaxAutomaticRedirections=5;$handler.UseDefaultCredentials=$false
            $client=New-Object Net.Http.HttpClient($handler)
            $stream=$null;$response=$null
            try {
                $response=$client.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                if(-not $response.IsSuccessStatusCode){throw ('NetBird download failed with HTTP '+[int]$response.StatusCode+'.')}
                $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                [void]$response.Content.CopyToAsync($stream).GetAwaiter().GetResult()
                return [string]$response.RequestMessage.RequestUri.AbsoluteUri
            } finally {
                if($stream){$stream.Dispose()};if($response){$response.Dispose()};$client.Dispose();$handler.Dispose()
            }
        }
        GetSignature={param($path) Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop}
        RunInstaller={param($path,$arguments) Invoke-LanOnlineNativeProcess -Path $path -Arguments $arguments -TimeoutMilliseconds 600000}
        FindClient={ $p=Join-Path $env:ProgramFiles 'NetBird\netbird.exe'; if([IO.File]::Exists($p)){return $p} }
        AssertTrustedClient={param($path) Assert-LanNetBirdClient $path}
        RunClient={param($path,$arguments) Invoke-LanOnlineNativeProcess -Path $path -Arguments $arguments -TimeoutMilliseconds 60000}
        ProbeDaemon={
            $p=Join-Path $env:ProgramFiles 'NetBird\netbird.exe'
            if(-not [IO.File]::Exists($p)){return $false}
            $r=Invoke-LanOnlineNativeProcess -Path $p -Arguments 'status --json' -TimeoutMilliseconds 10000
            if($r.ExitCode -ne 0 -or $r.TimedOut){return $false}
            try{$null=$r.Stdout|ConvertFrom-Json -ErrorAction Stop;return $true}catch{return $false}
        }
        ServiceExists={ [bool](Get-Service -Name NetBird -ErrorAction SilentlyContinue) }
        WaitServiceMissing={
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            do { if(-not (Get-Service -Name NetBird -ErrorAction SilentlyContinue)){return $true};Start-Sleep -Milliseconds 250 } while([DateTime]::UtcNow -lt $deadline)
            return $false
        }
        ForceDeleteService={ Invoke-LanOnlineNativeProcess -Path (Join-Path $env:SystemRoot 'System32\sc.exe') -Arguments 'delete NetBird' -TimeoutMilliseconds 15000 }
        Sleep={param($milliseconds) Start-Sleep -Milliseconds $milliseconds}
        CreateTempDirectory={
            $path=Join-Path $env:TEMP ('LanFileSharing-NetBird-'+[guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($path)|Out-Null
            return $path
        }
        RemoveTempDirectory={param($path) if([IO.Directory]::Exists($path)){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}}
    }
}

function Invoke-LanOnlineInstallRepair {
    param([hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=New-LanOnlineSetupAdapter }
    Assert-LanOnlineSetupPlatform -Adapter $Adapter
    $existing=& $Adapter.FindClient
    if($existing){
        & $Adapter.AssertTrustedClient $existing
        Assert-LanNetBirdInstallerSignature -Path $existing -Adapter $Adapter|Out-Null
        $repair=Repair-LanNetBirdService -ClientPath $existing -Adapter $Adapter
        return [pscustomobject]@{Passed=$true;InstallerExitCode=$null;PackageAction='UsedExistingClient';RepairMode=$repair.RepairMode;DaemonAnswered=[bool]$repair.DaemonAnswered}
    }
    $temp=& $Adapter.CreateTempDirectory
    try {
        $msi=Join-Path $temp 'netbird-windows-amd64.msi'
        $source=Get-LanNetBirdStableInstallerUri
        Assert-LanNetBirdInstallerUri $source.AbsoluteUri | Out-Null
        $final=[string](& $Adapter.DownloadInstaller $source.AbsoluteUri $msi)
        Assert-LanNetBirdInstallerUri $final | Out-Null
        if(-not [IO.File]::Exists($msi) -or ([IO.FileInfo]$msi).Length -lt 1){throw 'The NetBird installer download is empty.'}
        $installed=Install-LanNetBirdMsi -Path $msi -Adapter $Adapter
        $client=& $Adapter.FindClient
        if(-not $client){throw 'NetBird was installed but netbird.exe was not found.'}
        & $Adapter.AssertTrustedClient $client
        $repair=Repair-LanNetBirdService -ClientPath $client -Adapter $Adapter
        return [pscustomobject]@{Passed=$true;InstallerExitCode=[int]$installed.ExitCode;PackageAction='InstalledStablePackage';RepairMode=$repair.RepairMode;DaemonAnswered=[bool]$repair.DaemonAnswered}
    } finally { & $Adapter.RemoveTempDirectory $temp }
}

function Get-LanDefaultOnlineAdapter {
    if (-not $script:LanDefaultOnlineAdapter) { $script:LanDefaultOnlineAdapter=New-LanOnlineAdapter }
    return $script:LanDefaultOnlineAdapter
}

function Assert-LanOnlineRuleOwned {
    param($Rule)
    if ($Rule -and $Rule.Description -ne 'Created by LAN File Sharing (NetBird)') { throw 'Online firewall name belongs to another rule.' }
}

function Get-LanOnlineAllowedPeerAddresses {
    param($Settings,$Status)
    $result=@()
    foreach ($p in @($Settings.AllowedPeers)) {
        $matches=@($Status.Peers | Where-Object { $_.Identity -ceq $p.Identity })
        if ($matches.Count -ne 1 -or $matches[0].Address -cne $p.Address) { throw 'An approved peer identity/address changed. Select the peer again.' }
        $result+= (ConvertTo-LanOnlineAddress $matches[0].Address) + '/32'
    }
    return $result
}

function Add-LanOnlineFirewallOperations {
    param([hashtable]$Adapter)
    $Adapter.GetOnlineRule={ Get-NetFirewallRule -Name 'LFS-NetBird-SMB' -ErrorAction SilentlyContinue }
    $Adapter.ApplyOnlineRule={param($o)
        $existing=Get-NetFirewallRule -Name $o.Name -ErrorAction SilentlyContinue
        Assert-LanOnlineRuleOwned $existing
        if ($existing) {
            Set-NetFirewallRule -Name $o.Name -Enabled True -Profile Any -Direction Inbound -Action Allow -InterfaceAlias $o.InterfaceAlias -LocalAddress $o.LocalAddress -RemoteAddress $o.RemoteAddress -Protocol TCP -LocalPort 445 -ErrorAction Stop | Out-Null
        } else { New-NetFirewallRule @o -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop | Out-Null }
    }
    $Adapter.DisableOnlineRule={
        $r=Get-NetFirewallRule -Name 'LFS-NetBird-SMB' -ErrorAction SilentlyContinue
        Assert-LanOnlineRuleOwned $r
        if ($r) { Disable-NetFirewallRule -Name $r.Name -ErrorAction Stop | Out-Null }
    }
    $Adapter.RemoveOnlineRule={
        $r=Get-NetFirewallRule -Name 'LFS-NetBird-SMB' -ErrorAction SilentlyContinue
        Assert-LanOnlineRuleOwned $r
        if ($r) { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop | Out-Null }
    }
    $Adapter.RestrictLanRule={param($interface)
        $r=Get-NetFirewallRule -Name 'LFS-Private-SMB' -ErrorAction SilentlyContinue
        if (-not $r) { return }
        if ($r.Description -ne 'Created by LAN File Sharing') { throw 'LAN firewall name belongs to another rule.' }
        $aliases=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and $_.HardwareInterface -and [string]$_.InterfaceGuid -ine [string]$interface.InterfaceId
        } | ForEach-Object { [string]$_.Name })
        if ($aliases.Count -gt 0) {
            Set-NetFirewallRule -Name $r.Name -InterfaceAlias $aliases -Profile Private -Enabled True -ErrorAction Stop | Out-Null
        } else { Disable-NetFirewallRule -Name $r.Name -ErrorAction Stop | Out-Null }
    }
    $Adapter.GetStatus={ Get-LanOnlineStatus -Adapter (Get-LanDefaultOnlineAdapter) }
    return $Adapter
}

function Get-LanOnlinePolicyAdapter {
    $a=Get-LanDefaultOnlineAdapter
    if (-not $a.GetOnlineRule) { Add-LanOnlineFirewallOperations -Adapter $a | Out-Null }
    return $a
}

function Sync-LanOnlineFirewall {
    param([string]$StatePath,[hashtable]$Adapter,$Settings,$Status)
    if (-not $Adapter) { $Adapter=Get-LanOnlinePolicyAdapter }
    if (-not $Settings) {
        $ctx=Get-LanShareOnlineContext -StatePath $StatePath -Adapter $Adapter
        return [pscustomobject]@{Ready=$ctx.Ready;Changed=$true;Reason=$ctx.Reason}
    }
    if (-not $Status) { $Status=& $Adapter.GetStatus }
    Assert-LanOnlineRuleOwned (& $Adapter.GetOnlineRule)
    $interface=if ($Status.InterfaceId -and $Status.LocalAddress) {
        [pscustomobject]@{InterfaceId=$Status.InterfaceId;InterfaceAlias=$Status.InterfaceAlias;Address=$Status.LocalAddress}
    } else { $Settings.LastKnownInterface }
    if ($interface) {
        try { & $Adapter.RestrictLanRule $interface }
        catch { try { & $Adapter.DisableOnlineRule } catch { }; throw }
    }
    $reason=$null; $addresses=@()
    if (-not $Settings.Enabled) { $reason='Online disabled.' }
    elseif ($Status.ConnectionState -ne 'Connected' -or -not $Status.InterfaceId) { $reason='NetBird is not connected on a verified interface.' }
    elseif (-not (Test-LanOnlineBinding $Settings.Binding (Get-LanOnlineBinding $Status))) { $reason='NetBird network identity changed.' }
    else { try { $addresses=@(Get-LanOnlineAllowedPeerAddresses $Settings $Status); if ($addresses.Count -eq 0) { $reason='No approved peers.' } } catch { $reason=$_.Exception.Message } }
    if ($reason) { & $Adapter.DisableOnlineRule; return [pscustomobject]@{Ready=$false;Changed=$true;Reason=$reason} }
    $options=@{Name='LFS-NetBird-SMB';DisplayName='LAN File Sharing Online';Description='Created by LAN File Sharing (NetBird)';
        Protocol='TCP';LocalPort=445;Profile='Any';InterfaceAlias=$Status.InterfaceAlias;LocalAddress=$Status.LocalAddress;RemoteAddress=$addresses}
    try { & $Adapter.ApplyOnlineRule $options }
    catch { try { & $Adapter.DisableOnlineRule } catch { }; throw }
    return [pscustomobject]@{Ready=$true;Changed=$true;Reason=$null}
}

function Set-LanOnlineConfiguration {
    param([string]$StatePath,[bool]$Enabled,[string[]]$PeerIdentities=@(),[hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=Get-LanOnlinePolicyAdapter }
    $status=& $Adapter.GetStatus
    Assert-LanOnlineRuleOwned (& $Adapter.GetOnlineRule)
    $peers=@()
    if ($Enabled) {
        if ($status.ConnectionState -ne 'Connected' -or -not $status.InterfaceId) { throw 'NetBird must be connected on a verified interface.' }
        foreach ($identity in @($PeerIdentities | Select-Object -Unique)) {
            $matches=@($status.Peers | Where-Object { $_.Identity -ceq $identity })
            if ($matches.Count -ne 1) { throw 'Unknown or ambiguous peer.' }
            $p=$matches[0]; $peers+= [pscustomobject]@{Identity=$p.Identity;Name=$p.Name;Address=$p.Address}
        }
        if ($peers.Count -eq 0) { throw 'Select at least one peer.' }
    }
    $lock=Enter-LanStateLock -StatePath $StatePath
    try {
        $state=Read-LanState $StatePath
        if ($Enabled -and @($state.Shares | Where-Object AuthMode -eq Guest).Count -gt 0) { throw 'Stop or replace app Guest shares before enabling Online.' }
        $settings=New-LanOnlineSettings
        $settings.Enabled=$Enabled; $settings.AllowedPeers=$peers
        $settings.LastKnownInterface=$state.OnlineSettings.LastKnownInterface
        if ($Enabled) {
            $settings.Binding=Get-LanOnlineBinding $status
            $settings.LastKnownInterface=[pscustomobject]@{InterfaceId=$status.InterfaceId;InterfaceAlias=$status.InterfaceAlias;Address=$status.LocalAddress}
        }
        $old=$state.OnlineSettings
        try {
            Sync-LanOnlineFirewall -StatePath $StatePath -Adapter $Adapter -Settings $settings -Status $status | Out-Null
            $state.OnlineSettings=$settings
            Write-LanState -Path $StatePath -State $state
        } catch { try { & $Adapter.DisableOnlineRule } catch { }; $state.OnlineSettings=$old; throw }
        $status.OnlineEnabled=$Enabled
        return $status
    } finally { $lock.Dispose() }
}

function Remove-LanOnlineFirewall {
    param([hashtable]$Adapter)
    if (-not $Adapter) { $Adapter=Get-LanOnlinePolicyAdapter }
    Assert-LanOnlineRuleOwned (& $Adapter.GetOnlineRule)
    & $Adapter.RemoveOnlineRule
}

function Get-LanShareOnlineContext {
    param([string]$StatePath,[hashtable]$Adapter)
    $a=if($Adapter){$Adapter}else{Get-LanOnlinePolicyAdapter}
    $s=& $a.GetStatus
    $lock=Enter-LanStateLock -StatePath $StatePath
    try {
        $state=Read-LanState $StatePath
        $s.OnlineEnabled=[bool]$state.OnlineSettings.Enabled
        if($state.OnlineSettings.Enabled -and @($state.Shares|Where-Object AuthMode -eq Guest).Count){
            & $a.DisableOnlineRule
            $policy=@{Ready=$false;Reason='Guest shares must be stopped before Online sharing.'}
        }else{$policy=Sync-LanOnlineFirewall -StatePath $StatePath -Adapter $a -Settings $state.OnlineSettings -Status $s}
        return [pscustomobject]@{Ready=$policy.Ready;Status=$s;Settings=$state.OnlineSettings;Reason=$policy.Reason}
    }finally{$lock.Dispose()}
}

function Resolve-LanOnlineMappingTarget {
    param($Entry,[hashtable]$OnlineAdapter)
    $result=[pscustomobject]@{Ready=$true;Reason=$null;Unc=[string]$Entry.Unc;Peer=$null}
    if ($Entry.Transport -ne 'NetBird') { return $result }
    $result.Ready=$false
    try {
        if (-not $OnlineAdapter -or -not $OnlineAdapter.GetStatus) { throw 'Online status is unavailable.' }
        $s=& $OnlineAdapter.GetStatus
        if (-not $s.OnlineEnabled -or $s.ConnectionState -ne 'Connected' -or -not $s.InterfaceId) { throw 'Online is disabled or disconnected.' }
        if (-not (Test-LanOnlineBinding $Entry.OnlineBinding (Get-LanOnlineBinding $s))) { throw 'Online network identity changed.' }
        $peer=@($s.Peers | Where-Object { $_.Identity -ceq $Entry.OnlinePeerIdentity })
        $server=([string]$Entry.Unc).TrimStart('\').Split('\')[0]
        if ($peer.Count -ne 1 -or $peer[0].Address -cne $server) { throw 'Online peer identity/address changed; select the machine again.' }
        $result.Ready=$true; $result.Peer=$peer[0]
    } catch { $result.Reason=$_.Exception.Message }
    return $result
}

function Get-LanOnlineMappingIdentity {
    param([string]$Unc,$OnlineStatus,[string]$ExpectedIdentity)
    $server=$Unc.TrimStart('\').Split('\')[0]
    $peers=@($OnlineStatus.Peers | Where-Object { $_.Address -ceq $server })
    if ($ExpectedIdentity -and ($peers.Count -ne 1 -or $peers[0].Identity -cne $ExpectedIdentity)) { throw 'Online destination does not match the copied machine identity.' }
    if ($peers.Count -eq 1) { return $peers[0].Identity }
    return $null
}

function Get-LanClientOnlineStatus {
    if (& (Get-LanDefaultOnlineAdapter).FindClient) {
        if (Get-Command Invoke-LanHostRequest -ErrorAction SilentlyContinue) { return Invoke-LanHostRequest -Action OnlineStatus -Payload @{} }
    }
    $s=Get-LanOnlineStatus -Adapter (Get-LanDefaultOnlineAdapter)
    try { $s.OnlineEnabled=[bool](Read-LanState -Path (Join-Path $env:ProgramData 'LanFileSharing\state.json')).OnlineSettings.Enabled }
    catch { $s.OnlineEnabled=$false }
    return $s
}

function Test-LanClientOnlineTarget {
    param($Entry,[hashtable]$Adapter)
    $a=@{GetStatus=$Adapter.GetOnlineStatus}
    return Resolve-LanOnlineMappingTarget -Entry $Entry -OnlineAdapter $a
}

function Get-LanNewOnlineTarget {
    param([string]$Unc,[hashtable]$Adapter)
    $ip=$null; $server=$Unc.TrimStart('\').Split('\')[0]
    if (-not $Adapter.ExpectedOnlinePeerIdentity -and (-not $Adapter.GetOnlineStatus -or -not [Net.IPAddress]::TryParse($server,[ref]$ip))) { return $null }
    if (-not $Adapter.GetOnlineStatus) { throw 'Online module is not ready.' }
    $s=& $Adapter.GetOnlineStatus
    $identity=Get-LanOnlineMappingIdentity -Unc $Unc -OnlineStatus $s -ExpectedIdentity $Adapter.ExpectedOnlinePeerIdentity
    if (-not $identity) { return $null }
    $entry=[pscustomobject]@{Unc=$Unc;Transport='NetBird';OnlinePeerIdentity=$identity;OnlineBinding=(Get-LanOnlineBinding $s)}
    $guard=Test-LanClientOnlineTarget -Entry $entry -Adapter $Adapter
    if (-not $guard.Ready) { throw $guard.Reason }
    return $entry
}

function Assert-LanSavedOnlineTarget {
    param([string]$Unc,[hashtable]$Adapter)
    foreach($entry in @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter))){
        if($entry.Transport -eq 'NetBird' -and $entry.Unc.TrimStart('\').Split('\')[0] -ieq $Unc.TrimStart('\').Split('\')[0]){
            $guard=Test-LanClientOnlineTarget -Entry $entry -Adapter $Adapter
            if(-not $guard.Ready){throw $guard.Reason}
        }
    }
}

function Update-LanShareOnlineSnapshot {
    param($State,[hashtable]$Adapter)
    if(-not $Adapter.OnlineContext){return}
    $ctx=$Adapter.OnlineContext
    $ctx.Ready=([bool]$ctx.Ready -and [bool]$State.OnlineSettings.Enabled -and
        (Test-LanOnlineBinding $State.OnlineSettings.Binding (Get-LanOnlineBinding $ctx.Status)))
    $ctx.Settings=$State.OnlineSettings
}
