. (Join-Path $PSScriptRoot 'Progress.ps1')

function Assert-LanHostRequest {
    param([Parameter(Mandatory)][string]$Action,$Payload)
    if ($Action -notin @('List','Create','Stop','Refresh','CheckShare','CheckGuest','ConfigureGuest','RestoreGuest','EnableBlankPassword','RestoreBlankPassword','OnlineStatus','OnlineEnroll','OnlineConfigure')) { throw "Unknown privileged host action: $Action" }
    if ($Action -like 'Online*') {
        $names=@($Payload.Keys); if ($Payload -isnot [System.Collections.IDictionary]) { $names=@($Payload.PSObject.Properties | ForEach-Object { $_.Name }) }
        $allowed= switch($Action){OnlineStatus{@()} OnlineEnroll{@('SetupKey')} OnlineConfigure{@('Enabled','PeerIdentities')}}
        if (@($names | Where-Object {$_ -notin $allowed}).Count) { throw 'Unexpected Online request field.' }
        if ($Action -eq 'OnlineEnroll' -and ($Payload.SetupKey -isnot [string] -or [string]::IsNullOrWhiteSpace($Payload.SetupKey) -or $Payload.SetupKey.Length -gt 4096 -or $Payload.SetupKey -match '[\x00-\x1f\x7f]')) { throw 'Invalid registration key.' }
        if ($Action -eq 'OnlineConfigure') {
            if ($Payload.Enabled -isnot [bool]) { throw 'Online Enabled must be a boolean.' }
            foreach ($identity in @($Payload.PeerIdentities)) { if ($identity -isnot [string] -or -not (Test-LanOnlinePublicKey $identity)) { throw 'Invalid peer identity.' } }
        }
    }
    if ($Action -eq 'Stop' -and -not [string]$Payload.Id) { throw 'Stop requires a share id.' }
    if ($Action -eq 'CheckShare' -and -not [string]$Payload.Id) { throw 'CheckShare requires a share id.' }
    if ($Action -eq 'Create') {
        if ([string]$Payload.Kind -notin @('Drive','Folder','File') -or
            [string]::IsNullOrWhiteSpace([string]$Payload.Path) -or
            [string]::IsNullOrWhiteSpace([string]$Payload.Name) -or
            [string]$Payload.Mode -notin @('Read','Modify') -or
            [string]$Payload.AuthMode -notin @('WindowsCurrent','Protected','Guest')) {
            throw 'Create request is missing a valid sharing choice.'
        }
        if ([string]$Payload.AuthMode -eq 'Protected' -and [string]::IsNullOrWhiteSpace([string]$Payload.Password)) {
            throw 'Protected Password requires a password.'
        }
    }
}

function Get-LanHostHelperArguments {
    param([Parameter(Mandatory)][string]$HelperPath,[Parameter(Mandatory)][string]$PipeName)
    if ($HelperPath.Contains('"') -or $PipeName -notmatch '^[A-Za-z0-9-]{6,80}$') { throw 'Invalid host helper path or pipe name.' }
    return '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $HelperPath + '" -PipeName ' + $PipeName
}

function Write-LanHostPipeMessage {
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)]$Value,[int]$TimeoutMilliseconds=-1)
    $json = ConvertTo-Json -InputObject $Value -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    if ($bytes.Length -gt 1048576) { throw 'Host request exceeds the maximum message size.' }
    try {
        if ($TimeoutMilliseconds -lt 0) {
            $writer = New-Object IO.BinaryWriter($Stream,[Text.Encoding]::UTF8,$true)
            $writer.Write([int]$bytes.Length)
            $writer.Write($bytes)
        } else {
            $frame = New-Object byte[] ($bytes.Length + 4)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([int]$bytes.Length),0,$frame,0,4)
            [Buffer]::BlockCopy($bytes,0,$frame,4,$bytes.Length)
            try {
                $pending = $Stream.BeginWrite($frame,0,$frame.Length,$null,$null)
                $waitHandle = $pending.AsyncWaitHandle
                try {
                    if (-not $waitHandle.WaitOne($TimeoutMilliseconds)) {
                        Stop-LanHostPipeIO -Stream $Stream
                        throw 'Timed out sending the host broker request.'
                    }
                    $Stream.EndWrite($pending)
                } finally { $waitHandle.Close() }
            } finally { [Array]::Clear($frame,0,$frame.Length) }
        }
        # BinaryWriter writes directly to the pipe. PipeStream.Flush waits for
        # the peer to consume data and can hang before any response deadline.
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

# Compile before requests begin: compiling during a timeout delays cancellation
# beyond its deadline on the first blocked request.
if (-not ('LanFileSharing.PipeCancellation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LanFileSharing {
    public static class PipeCancellation {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool CancelIoEx(SafePipeHandle handle, IntPtr overlapped);
    }
}
'@
}

function Stop-LanHostPipeIO {
    param([IO.Stream]$Stream)
    if ($Stream -is [IO.Pipes.PipeStream]) {
        [void][LanFileSharing.PipeCancellation]::CancelIoEx($Stream.SafePipeHandle,[IntPtr]::Zero)
    }
    $Stream.Dispose()
}

function Read-LanHostPipeBytes {
    param([IO.Stream]$Stream,[byte[]]$Buffer,[int]$Count,[int]$TimeoutMilliseconds,$Watch)
    $offset = 0
    while ($offset -lt $Count) {
        if ($TimeoutMilliseconds -lt 0) {
            $read = $Stream.Read($Buffer,$offset,$Count-$offset)
        } else {
            $pending = $Stream.BeginRead($Buffer,$offset,$Count-$offset,$null,$null)
            $waitHandle = $pending.AsyncWaitHandle
            try {
                $remaining = [Math]::Max(0,$TimeoutMilliseconds-[int]$Watch.ElapsedMilliseconds)
                if (-not $waitHandle.WaitOne($remaining)) {
                    # .NET Framework keeps the pipe handle alive for pending IO.
                    # Cancel it before disposing, or disposal itself can wait for
                    # the peer indefinitely and defeat this deadline.
                    Stop-LanHostPipeIO -Stream $Stream
                    throw 'Timed out waiting for the host broker response.'
                }
                $read = $Stream.EndRead($pending)
            } finally { $waitHandle.Close() }
        }
        if ($read -eq 0) { throw 'Host pipe closed during a message.' }
        $offset += $read
    }
}

function Read-LanHostPipeMessage {
    param([Parameter(Mandatory)][IO.Stream]$Stream,[int]$TimeoutMilliseconds=-1)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $header = New-Object byte[] 4
    Read-LanHostPipeBytes -Stream $Stream -Buffer $header -Count 4 -TimeoutMilliseconds $TimeoutMilliseconds -Watch $watch
    $length = [BitConverter]::ToInt32($header,0)
    if ($length -lt 1 -or $length -gt 1048576) { throw 'Invalid host message length.' }
    $bytes = New-Object byte[] $length
    try {
        Read-LanHostPipeBytes -Stream $Stream -Buffer $bytes -Count $length -TimeoutMilliseconds $TimeoutMilliseconds -Watch $watch
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop)
    }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function New-LanHostPipeSecurity {
    $security = New-Object IO.Pipes.PipeSecurity
    $security.SetAccessRuleProtection($true,$false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        $rule = New-Object IO.Pipes.PipeAccessRule($sid,[IO.Pipes.PipeAccessRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function Invoke-LanHostPipeExchange {
    param([Parameter(Mandatory)][string]$Action,[Parameter(Mandatory)]$Payload,[Parameter(Mandatory)][string]$HelperPath)
    $pipeName = 'LanFileSharing-Host-' + [guid]::NewGuid().ToString('N')
    $pipe = [IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,
        [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096,(New-LanHostPipeSecurity))
    try {
        $arguments = Get-LanHostHelperArguments -HelperPath $HelperPath -PipeName $pipeName
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $pending = $pipe.BeginWaitForConnection($null,$null)
        if (-not $pending.AsyncWaitHandle.WaitOne(120000)) { throw 'Timed out waiting for the elevated host helper.' }
        $pipe.EndWaitForConnection($pending)
        Write-LanHostPipeMessage -Stream $pipe -Value @{Action=$Action;Payload=$Payload}
        $response = Read-LanHostPipeMessage -Stream $pipe
        if (-not $response.Ok) { throw [string]$response.Error }
        return $response.Result
    } finally { $pipe.Dispose() }
}

function Assert-LanHostBrokerCaller {
    param([Parameter(Mandatory)][string]$AllowedSid,[Parameter(Mandatory)][string]$CallerSid)
    if (-not [string]::Equals($AllowedSid,$CallerSid,[StringComparison]::Ordinal)) {
        throw 'This Windows account is not authorized to control the installed host broker.'
    }
}

function Get-LanHostBrokerAllowedSid {
    param([Parameter(Mandatory)][string]$StateRoot)
    $path = Join-Path $StateRoot 'broker-user.sid'
    if (-not [IO.File]::Exists($path)) { throw 'The installed host broker has no authorized Windows account.' }
    $value = [IO.File]::ReadAllText($path,[Text.Encoding]::ASCII).Trim()
    $sid = [Security.Principal.SecurityIdentifier]::new($value)
    if ($sid.Value -ne $value) { throw 'Invalid host broker account SID.' }
    return $sid
}

function New-LanHostBrokerPipeSecurity {
    param([Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$AllowedSid)
    $security = New-Object IO.Pipes.PipeSecurity
    $security.SetAccessRuleProtection($true,$false)
    foreach ($sid in @((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),$AllowedSid)) {
        $rights = if ($sid.Value -eq 'S-1-5-18') { [IO.Pipes.PipeAccessRights]::FullControl }
                  else { [IO.Pipes.PipeAccessRights]::ReadWrite }
        $rule = New-Object IO.Pipes.PipeAccessRule($sid,$rights,[Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function Invoke-LanHostBrokerExchange {
    param([Parameter(Mandatory)][string]$Action,$Payload,
          [string]$PipeName='LanFileSharing-HostBroker',
          # The broker serves one caller at a time and a single share action can hold it for more
          # than a minute while it walks a large folder. The old 20 second budget made an ordinary
          # action look like a broken install or a frozen window.
          [int]$WaitMilliseconds=180000,
          [int]$CompletionTimeoutMilliseconds=3600000,
          [switch]$HasHeartbeatPath)
    # The broker serves one caller at a time, so the worker's periodic reconcile can hold the
    # pipe while a user action arrives. Waiting for a busy broker is not the same as the broker
    # being uninstalled, so the caller retries until the wait budget is spent.
    $heartbeat = if ($HasHeartbeatPath) { Join-Path (Join-Path $env:ProgramData 'LanFileSharing') 'broker.heartbeat' } else { $null }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastNote = -10
    while ($true) {
        # Waiting in silence is what made users think the program had frozen: the window showed no
        # new line for as long as the broker was busy. Record the wait in the same log the window
        # displays, at most once every ten seconds, and name the operation being waited for.
        $elapsed = [int]$watch.Elapsed.TotalSeconds
        if ($elapsed -ge 3 -and $elapsed - $lastNote -ge 10) {
            $lastNote = $elapsed
            try {
                Add-LanProgressLog -Message ("กำลังรอโปรแกรมส่วนบริการ (broker) ตอบกลับคำสั่ง $Action — รอมา $elapsed วินาที")
            } catch { }
        }
        $client = [IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
        try {
            try { $client.Connect(500) }
            catch [TimeoutException] {
                # No listener at all: report at once when the broker never started.
                if ($watch.ElapsedMilliseconds -ge $WaitMilliseconds -or
                    ($heartbeat -and -not [IO.File]::Exists($heartbeat))) {
                    return [pscustomobject]@{Available=$false;Result=$null}
                }
                continue
            }
            catch [UnauthorizedAccessException] { return [pscustomobject]@{Available=$false;Result=$null} }
            catch [IO.IOException] {
                # The listener exists but is busy with another caller; retry within the budget.
                if ($watch.ElapsedMilliseconds -ge $WaitMilliseconds) { return [pscustomobject]@{Available=$false;Result=$null} }
                continue
            }
            try { Add-LanProgressLog -Message ("โปรแกรมส่วนบริการรับคำสั่ง $Action แล้ว") } catch { }
            $remaining = [Math]::Max(1,$WaitMilliseconds-[int]$watch.ElapsedMilliseconds)
            Write-LanHostPipeMessage -Stream $client -Value @{Action=$Action;Payload=$Payload} -TimeoutMilliseconds $remaining
            # Connection/queue time is separate from accepted work. Whole-drive
            # ACL verification can exceed three minutes; never resend a mutation.
            $remaining = if ($Action -in @('Create','Stop')) { $CompletionTimeoutMilliseconds }
                         else { [Math]::Max(1,$WaitMilliseconds-[int]$watch.ElapsedMilliseconds) }
            $response = Read-LanHostPipeMessage -Stream $client -TimeoutMilliseconds $remaining
            if (-not $response.Ok) { throw [string]$response.Error }
            return [pscustomobject]@{Available=$true;Result=$response.Result}
        } finally {
            # Closing on every path tells a stalled broker its peer is gone instead of letting
            # it block on a response nobody is reading.
            $client.Dispose()
        }
    }
}

function Invoke-LanHostPreferredExchange {
    param([Parameter(Mandatory)][string]$Action,$Payload,[Parameter(Mandatory)][string]$HelperPath)
    # These reads require no elevation and must remain available while the
    # privileged broker is verifying a large share.
    if ($Action -in @('List','Refresh')) { return Invoke-LanHostReadAction -Action $Action }
    # List/Refresh run on the UI thread. Never let an unavailable or busy
    # broker freeze opening the tab; create/stop already run in a helper.
    $wait = if ($Action -in @('List','Refresh')) { 500 } elseif($Action -eq 'OnlineStatus'){10000} else { 180000 }
    $broker = Invoke-LanHostBrokerExchange -Action $Action -Payload $Payload -WaitMilliseconds $wait -HasHeartbeatPath
    if ($broker.Available) { return $broker.Result }
    throw 'ยังติดต่อบริการแชร์ไม่ได้: บริการอาจกำลังทำงานอื่นอยู่หรือยังไม่พร้อม กรุณาตรวจบันทึกและสถานะแชร์ก่อนสั่งซ้ำ หากบริการหยุดจริงให้ซ่อมการติดตั้ง'
}

function Invoke-LanHostReadAction {
    param([Parameter(Mandatory)][ValidateSet('List','Refresh','OnlineStatus')][string]$Action)
    $statePath = Join-Path $env:ProgramData 'LanFileSharing\state.json'
    if ($Action -ne 'OnlineStatus') { return @(Get-LanPublicShares -StatePath $statePath) }
    $status=Get-LanOnlineStatus -Adapter (Get-LanDefaultOnlineAdapter)
    $state=Read-LanState -Path $statePath
    $status | Add-Member -NotePropertyName OnlineEnabled -NotePropertyValue ([bool]$state.OnlineSettings.Enabled) -Force
    $status | Add-Member -NotePropertyName AllowedPeerIdentities -NotePropertyValue @($state.OnlineSettings.AllowedPeers | ForEach-Object {$_.Identity}) -Force
    return $status
}

function Invoke-LanHostBrokerRequest {
    param([Parameter(Mandatory)][IO.Pipes.NamedPipeServerStream]$Pipe,
          [Parameter(Mandatory)][string]$AllowedSid,
          [scriptblock]$Dispatch)
    try {
        $request = Read-LanHostPipeMessage -Stream $Pipe -TimeoutMilliseconds 5000
        $script:LanHostBrokerCallerSid = $null
        $Pipe.RunAsClient([IO.Pipes.PipeStreamImpersonationWorker]{
            $script:LanHostBrokerCallerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        })
        Assert-LanHostBrokerCaller -AllowedSid $AllowedSid -CallerSid ([string]$script:LanHostBrokerCallerSid)
        Assert-LanHostRequest -Action ([string]$request.Action) -Payload $request.Payload
        $result = if ($Dispatch) { & $Dispatch ([string]$request.Action) $request.Payload }
                  else { Invoke-LanHostActionCore -Action ([string]$request.Action) -Payload $request.Payload }
        $response = @{Ok=$true;Result=$result}
    } catch { $response = @{Ok=$false;Error=$_.Exception.Message} }
    Write-LanHostPipeMessage -Stream $Pipe -Value $response -TimeoutMilliseconds 5000
    return $response
}

function Start-LanHostBrokerHeartbeatWriter {
    param([Parameter(Mandatory)][string]$HeartbeatPath)
    if(Get-Command Start-LanWorkerHeartbeatWriter -ErrorAction SilentlyContinue){
        return Start-LanWorkerHeartbeatWriter -HeartbeatPath $HeartbeatPath -WorkerProcessId $PID
    }
    return $null
}

function Start-LanHostBroker {
    param([Parameter(Mandatory)][string]$StateRoot,
          [string]$PipeName='LanFileSharing-HostBroker')
    # Bring an installation made by an earlier version up to date. The state folder used to be
    # restricted to SYSTEM and Administrators, so the window — which runs unelevated — could not read
    # the share credentials out of state.json and reported "Access denied", while the share list still
    # looked correct because that list comes from this broker. Idempotent, and the broker runs as
    # SYSTEM, which is the only context allowed to change these permissions.
    try { if (Get-Command Repair-LanStateDirectoryAccess -ErrorAction SilentlyContinue) { Repair-LanStateDirectoryAccess -Path $StateRoot -StateRoot $StateRoot | Out-Null } } catch { }
    $allowedSid = Get-LanHostBrokerAllowedSid -StateRoot $StateRoot
    $pipeSecurity = New-LanHostBrokerPipeSecurity -AllowedSid $allowedSid
    $logPath = Join-Path $StateRoot 'broker.log'
    $heartbeatPath=Join-Path $StateRoot 'broker.heartbeat'
    $heartbeatWriter=$null
    try {
        Write-LanWorkerHeartbeat -Path $heartbeatPath
        $heartbeatWriter=Start-LanHostBrokerHeartbeatWriter -HeartbeatPath $heartbeatPath
        while ($true) {
            $pipe = [IO.Pipes.NamedPipeServerStream]::new($PipeName,[IO.Pipes.PipeDirection]::InOut,1,
                [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096,$pipeSecurity)
            try {
                Write-LanWorkerHeartbeat -Path $heartbeatPath
                $pipe.WaitForConnection()
                Invoke-LanHostBrokerRequest -Pipe $pipe -AllowedSid $allowedSid.Value | Out-Null
            } catch {
                Add-Content -LiteralPath $logPath -Value ((Get-Date -Format o) + ' ' + $_.Exception.Message) -ErrorAction SilentlyContinue
            } finally { $pipe.Dispose() }
        }
    } finally {
        if($heartbeatWriter){
            try{if(-not $heartbeatWriter.HasExited){Stop-Process -Id $heartbeatWriter.Id -Force -ErrorAction SilentlyContinue}}catch{}
            try{$heartbeatWriter.Dispose()}catch{}
        }
    }
}

function New-LanHostBridgeAdapter {
    param([string]$HelperPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'HostHelper.ps1'))
    return @{
        HelperPath=$HelperPath
        Exchange={ param($action,$payload,$helperPath) Invoke-LanHostPreferredExchange -Action $action -Payload $payload -HelperPath $helperPath }
    }
}

function Invoke-LanHostRequest {
    param([Parameter(Mandatory)][string]$Action,$Payload=@{},[hashtable]$Adapter=(New-LanHostBridgeAdapter))
    Assert-LanHostRequest -Action $Action -Payload $Payload
    return (& $Adapter.Exchange $Action $Payload $Adapter.HelperPath)
}

function ConvertTo-LanPublicShare {
    param([Parameter(Mandatory)]$Entry)
    return [pscustomobject]@{
        Id=$Entry.Id; Name=$Entry.Name; Kind=$Entry.Kind; SourcePath=$Entry.SourcePath
        Mode=$Entry.Mode; AuthMode=$Entry.AuthMode; AutoStart=$Entry.AutoStart; NtfsPolicy=$Entry.NtfsPolicy
        Status=$Entry.Status; LastError=$Entry.LastError
    }
}

function Get-LanPublicShares {
    param([Parameter(Mandatory)][string]$StatePath)
    $state = Read-LanState -Path $StatePath
    return @($state.Shares | ForEach-Object { ConvertTo-LanPublicShare -Entry $_ })
}

function Invoke-LanHostActionCore {
    param([Parameter(Mandatory)][string]$Action,$Payload)
    Assert-LanHostRequest -Action $Action -Payload $Payload
    $statePath = Join-Path (Join-Path $env:ProgramData 'LanFileSharing') 'state.json'
    switch ($Action) {
        'OnlineStatus' {
            $s=Get-LanOnlineStatus -Adapter (Get-LanDefaultOnlineAdapter)
            $s.OnlineEnabled=[bool](Read-LanState $statePath).OnlineSettings.Enabled
            $s | Add-Member -NotePropertyName AllowedPeerIdentities -NotePropertyValue @((Read-LanState $statePath).OnlineSettings.AllowedPeers | ForEach-Object {$_.Identity}) -Force
            return $s
        }
        'OnlineEnroll' { return Register-LanOnlineMachine -SetupKey ([string]$Payload.SetupKey) -Adapter (Get-LanDefaultOnlineAdapter) }
        'OnlineConfigure' { return Set-LanOnlineConfiguration -StatePath $statePath -Enabled ([bool]$Payload.Enabled) -PeerIdentities @($Payload.PeerIdentities) }
        { $_ -in @('List','Refresh') } {
            # The worker repairs its own state every five seconds, so a listing must stay a
            # cheap read. Each scheduled-task lookup costs seconds on some machines.
            return @(Get-LanPublicShares -StatePath $statePath)
        }
        'Stop' {
            # Append to the existing log instead of starting a fresh one. Start-LanProgress rewrites
            # the file down to a single header line, so the pane showed one line and then nothing
            # for the whole stop — and the stop's own progress lines had to be written into a file
            # that was being replaced underneath them.
            if (Get-Command Set-LanProgress -ErrorAction SilentlyContinue) {
                Set-LanProgress -Message 'กำลังหยุดแชร์และคืนสิทธิ์ NTFS เดิม' -Percent 0
            }
            Write-LanProgress -Message 'กำลังหยุดแชร์และคืนสิทธิ์ NTFS เดิม'
            $entry = @((Read-LanState -Path $statePath).Shares | Where-Object { $_.Id -eq ([string]$Payload.Id) }) | Select-Object -First 1
            if ($entry) {
                Write-LanProgress -Message ("เริ่มคืนสิทธิ์ NTFS สำหรับ '{0}' ({1} รายการ)" -f $entry.Name, @($entry.AclRecords).Count)
            }
            $stopped=Stop-LanHostShare -Id ([string]$Payload.Id) -StatePath $statePath -Adapter (New-LanHostAdapter) -LockTimeoutMilliseconds 180000
            $summary=if(@($stopped.CleanupErrors).Count){'หยุดแชร์แล้ว แต่คืนค่าไม่ครบ: '+($stopped.CleanupErrors -join '; ')}else{'หยุดแชร์แล้ว และคืนสิทธิ์เดิมเรียบร้อย'}
            Write-LanProgress -Message $summary
            return [pscustomobject]@{Stopped=$true;Summary=$summary;CleanupErrors=@($stopped.CleanupErrors);Shares=@(Get-LanPublicShares -StatePath $statePath)}
        }
        'CheckShare' { return Test-LanHostShareHealth -Id ([string]$Payload.Id) -StatePath $statePath }
        'CheckGuest' {
            $check=Get-LanGuestCompatibility -Role Host -Adapter (New-LanAuthAdapter)
            $summary=if(-not $check.Supported){'Guest ใช้ไม่ได้: '+($check.BlockedReasons -join '; ')}
                     elseif(@($check.RequiredChanges).Count){'Guest ต้องตั้งค่าก่อน: '+($check.RequiredChanges -join ', ')}else{'Guest พร้อมตามนโยบาย Windows'}
            return [pscustomobject]@{Supported=$check.Supported;Summary=$summary}
        }
        'RestoreGuest' {
            if (@((Read-LanState $statePath).Shares | Where-Object {$_.AuthMode -eq 'Guest'}).Count) { throw 'กรุณาหยุดแชร์ Guest ก่อนคืนค่านโยบาย' }
            $restored=Restore-LanGuestConfiguration -Role Host -Adapter (New-LanAuthAdapter) -StatePath $statePath
            if (@($restored.Skipped).Count) { throw 'นโยบาย Guest ถูกเปลี่ยนจากภายนอก โปรแกรมเก็บข้อมูลคืนค่าไว้และไม่เขียนทับ' }
            return [pscustomobject]@{Summary=$(if(@($restored.Restored).Count){'คืนค่า Guest เดิมแล้ว'}else{'ไม่มีการตั้งค่า Guest ของโปรแกรมที่ต้องคืนค่า'})}
        }
        'ConfigureGuest' {
            $adapter = New-LanAuthAdapter
            $check = Get-LanGuestCompatibility -Role Host -Adapter $adapter
            if (-not $check.Supported) { throw ($check.BlockedReasons -join '; ') }
            Enable-LanGuestConfiguration -Role Host -Adapter $adapter -StatePath $statePath | Out-Null
            return [pscustomobject]@{Configured=$true;Summary='ตั้งค่า Guest แล้ว กรุณาตรวจจากเครื่องผู้ใช้ไฟล์ด้วย'}
        }
        'EnableBlankPassword' {
            Enable-LanBlankPasswordNetworkLogon -StatePath $statePath -Adapter (New-LanHostAdapter) | Out-Null
            return [pscustomobject]@{Summary='อนุญาตบัญชี Windows ไม่มีรหัสผ่านเข้าแชร์ LAN แล้ว'}
        }
        'RestoreBlankPassword' {
            Restore-LanBlankPasswordNetworkLogon -StatePath $statePath -Adapter (New-LanHostAdapter) | Out-Null
            return [pscustomobject]@{Summary='คืนค่านโยบายบัญชีไม่มีรหัสผ่านแล้ว'}
        }
        'Create' {
            Start-LanProgress -Message "เตรียมแชร์ '$([string]$Payload.Name)' จาก $([string]$Payload.Path)"
            try {
                Write-LanProgress -Message 'ตรวจสอบพาธที่เลือกและสิทธิ์การเข้าถึง'
                $selection = Resolve-LanSelection -Kind ([string]$Payload.Kind) -Path ([string]$Payload.Path)
                $principals = if ([string]$Payload.Principals) { @(([string]$Payload.Principals).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
                $passwordMode = if ([string]$Payload.PasswordMethod -eq 'Manual') { 'Manual' } else { 'Random' }
                Write-LanProgress -Message 'เตรียมบัญชีและวิธีเข้าใช้'
                # The adapter carries the lookup so the account this machine already uses for its shares is
                # reused rather than a new one being invented for every share.
                $authAdapter = New-LanAuthAdapter
                # This lookup is invoked immediately within this request. Retain
                # the caller's script scope rather than hiding helpers in a module.
                $authAdapter.FindHostAccount = { Find-LanHostShareAccount -StatePath $statePath }
                # The name the owner typed on the sharing machine. It becomes the account this machine uses for
                # its shares, so every share created here from now on is reached with the same account — which is
                # what Windows requires for more than one share on a machine to be usable at the same time.
                $authAdapter.PreferredAccountName = [string]$Payload.AccountName
                $access = Resolve-LanAccess -AuthMode ([string]$Payload.AuthMode) -WindowsPrincipals $principals -ProtectedPasswordMode $passwordMode -ProtectedPassword ([string]$Payload.Password) -Adapter $authAdapter
                $created = Start-LanHostShare -Selection $selection -Name ([string]$Payload.Name) -Mode ([string]$Payload.Mode) -Access $access -AutoStart ([bool]$Payload.AutoStart) -StatePath $statePath -Adapter (New-LanHostAdapter) -LockTimeoutMilliseconds 180000
            } catch {
                Write-LanProgress -Message "แชร์ไม่สำเร็จ: $($_.Exception.Message)"
                throw
            }
            Write-LanProgress -Message "พร้อมใช้งาน: \\$env:COMPUTERNAME\$($created.Name)" -Percent 100
            return [pscustomobject]@{
                Name=$created.Name
                UserName=$created.CredentialInfo.UserName
                InitialPassword=$created.InitialPassword
                NtfsPolicy=$created.NtfsPolicy
                Shares=@(Get-LanPublicShares -StatePath $statePath)
            }
        }
    }
}

function Find-LanHostShareAccount {
    # The share account this machine already uses, if it has one.
    #
    # Windows keeps one credential per server, so every share on a machine has to be reached with the same
    # account. Returning the account of an existing share lets the next share reuse it instead of creating a
    # new LFS_ name — which is what made two shares on one machine unusable at the same time, even when the
    # user typed the same password for both.
    param([Parameter(Mandatory)][string]$StatePath,
          [string]$ExcludeShareId)
    $state = Read-LanState -Path $StatePath
    foreach ($entry in @($state.Shares)) {
        if ($ExcludeShareId -and [string]$entry.Id -eq $ExcludeShareId) { continue }
        if ([string]$entry.AuthMode -ne 'Protected') { continue }
        $info = $entry.CredentialInfo
        if (-not $info -or -not $info.UserName -or -not $info.PasswordCipher) { continue }
        try {
            $password = Unprotect-LanSecret -CipherText ([string]$info.PasswordCipher)
            if (-not $password) { continue }
            $user = Get-LocalUser -Name ([string]$info.UserName) -ErrorAction Stop
            if (-not $user -or -not $user.Enabled) { continue }
            return [pscustomobject]@{
                UserName = [string]$user.Name
                Sid      = [string]$user.SID.Value
                Password = $password
            }
        } catch { }
    }
    return $null
}

function Start-LanHostHelper {
    param([Parameter(Mandatory)][string]$PipeName,[hashtable]$Adapter)
    if ($PipeName -notmatch '^[A-Za-z0-9-]{6,80}$') { throw 'Invalid host pipe name.' }
    $client = $null
    if (-not $Adapter) {
        $client = [IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
        $client.Connect(30000)
        $Adapter = @{
            ReadRequest={ param($stream) Read-LanHostPipeMessage -Stream $stream }
            Dispatch={ param($action,$payload) Invoke-LanHostActionCore -Action $action -Payload $payload }
            WriteResponse={ param($response,$stream) Write-LanHostPipeMessage -Stream $stream -Value $response }
        }
    }
    try {
        $request = & $Adapter.ReadRequest $client
        try {
            Assert-LanHostRequest -Action ([string]$request.Action) -Payload $request.Payload
            $result = & $Adapter.Dispatch ([string]$request.Action) $request.Payload
            $response = @{Ok=$true;Result=$result}
        } catch { $response = @{Ok=$false;Error=$_.Exception.Message} }
        & $Adapter.WriteResponse $response $client | Out-Null
    } finally { if ($client) { $client.Dispose() } }
}
