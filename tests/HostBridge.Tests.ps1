$modulePath = Join-Path $PSScriptRoot '../src/HostBridge.ps1'
if (Test-Path -LiteralPath $modulePath) { . $modulePath }

Describe 'elevated host request bridge' {
    It 'keeps the broker heartbeat alive while its pipe is waiting for a request' {
        function Start-LanWorkerHeartbeatWriter { param($HeartbeatPath,$WorkerProcessId) }
        Mock Start-LanWorkerHeartbeatWriter { param($HeartbeatPath,$WorkerProcessId) [pscustomobject]@{Path=$HeartbeatPath;Pid=$WorkerProcessId} }
        $writer=Start-LanHostBrokerHeartbeatWriter -HeartbeatPath 'C:\ProgramData\LanFileSharing\broker.heartbeat'
        $writer.Path | Should Be 'C:\ProgramData\LanFileSharing\broker.heartbeat'
        $writer.Pid | Should Be $PID
        Assert-MockCalled Start-LanWorkerHeartbeatWriter -Times 1 -Exactly -Scope It
        [IO.File]::ReadAllText($modulePath) | Should Match 'Start-LanHostBrokerHeartbeatWriter -HeartbeatPath'
    }
    It 'allows only the two specific blank-password policy actions through the broker' {
        { Assert-LanHostRequest -Action EnableBlankPassword -Payload @{} } | Should Not Throw
        { Assert-LanHostRequest -Action RestoreBlankPassword -Payload @{} } | Should Not Throw
        { Assert-LanHostRequest -Action SetRegistryValue -Payload @{} } | Should Throw
    }
    It 'uses the installed host broker without launching an elevated helper' {
        Mock Invoke-LanHostBrokerExchange { [pscustomobject]@{Available=$true;Result=[pscustomobject]@{Name='SL'}} }
        Mock Invoke-LanHostPipeExchange { throw 'UAC should not be requested.' }

        $result = Invoke-LanHostPreferredExchange -Action Stop -Payload @{Id='fixture'} -HelperPath 'C:\Program Files\LanFileSharing\HostHelper.ps1'

        $result.Name | Should Be 'SL'
        Assert-MockCalled Invoke-LanHostPipeExchange -Times 0 -Exactly -Scope It
    }
    It 'reports a stopped broker instead of prompting for UAC on every host action' {
        Mock Invoke-LanHostBrokerExchange { [pscustomobject]@{Available=$false;Result=$null} }
        Mock Invoke-LanHostPipeExchange { throw 'Unexpected elevation prompt.' }

        { Invoke-LanHostPreferredExchange -Action Stop -Payload @{Id='fixture'} -HelperPath 'C:\Program Files\LanFileSharing\HostHelper.ps1' } | Should Throw

        Assert-MockCalled Invoke-LanHostPipeExchange -Times 0 -Exactly -Scope It
    }
    It 'rejects a broker request from a different Windows user SID' {
        { Assert-LanHostBrokerCaller -AllowedSid 'S-1-5-21-100-200-300-400' -CallerSid 'S-1-5-21-100-200-300-401' } | Should Throw
        { Assert-LanHostBrokerCaller -AllowedSid 'S-1-5-21-100-200-300-400' -CallerSid 'S-1-5-21-100-200-300-400' } | Should Not Throw
    }
    It 'keeps listing shares a cheap read instead of repairing the worker every time' {
        Mock Get-LanPublicShares { @() }

        Invoke-LanHostActionCore -Action List -Payload @{} | Out-Null

        # Reading a scheduled task costs seconds on some machines, and a listing runs whenever
        # the sharer tab refreshes, so the worker's own reconcile loop owns that repair.
        Assert-MockCalled Get-LanPublicShares -Times 1 -Exactly -Scope It
    }
    It 'waits for a busy broker instead of reporting it missing' {
        Mock Invoke-LanHostBrokerExchange {
            [pscustomobject]@{ Available=$true; Result=[pscustomobject]@{Name='SL'} }
        }
        $result = Invoke-LanHostPreferredExchange -Action Stop -Payload @{Id='fixture'} -HelperPath 'C:\Program Files\LanFileSharing\HostHelper.ps1'
        $result.Name | Should Be 'SL'
    }
    It 'retries a busy broker pipe and then succeeds' {
        $pipeName='LanFileSharing-Busy-'+[guid]::NewGuid().ToString('N')
        # A short-lived first listener rejects this caller, then a real broker answers. The
        # caller must retry rather than reporting the broker as missing.
        $service=Start-Job -ArgumentList $modulePath,$pipeName -ScriptBlock {
            param($modulePath,$pipeName)
            . $modulePath
            $first=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,
                [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096,(New-LanHostPipeSecurity))
            $first.Dispose()
            Start-Sleep -Milliseconds 300
            $second=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,
                [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::None,4096,4096,(New-LanHostPipeSecurity))
            $pending=$second.BeginWaitForConnection($null,$null)
            if ($pending.AsyncWaitHandle.WaitOne(15000)) {
                $second.EndWaitForConnection($pending)
                $request=Read-LanHostPipeMessage -Stream $second
                Write-LanHostPipeMessage -Stream $second -Value @{Ok=$true;Result=@{Action=$request.Action}}
            }
            $second.Dispose()
        }
        try {
            Start-Sleep -Milliseconds 200
            # The retry is what matters here: a rejected first attempt must not be reported as
            # a missing broker.
            $reply=Invoke-LanHostBrokerExchange -Action List -Payload @{} -PipeName $pipeName -WaitMilliseconds 8000
            $reply.Available | Should Be $true
            Wait-Job $service -Timeout 20 | Out-Null
            $service.State | Should Be 'Completed'
        } finally { Remove-Job $service -Force -ErrorAction SilentlyContinue }
    }
    It 'returns a validated host response to the normal user UI' {
        $adapter = @{Exchange={ param($action,$payload) [pscustomobject]@{Name='Laptop';Action=$action} }}
        $result = Invoke-LanHostRequest -Action List -Payload @{} -Adapter $adapter
        $result.Name | Should Be 'Laptop'
        $result.Action | Should Be 'List'
    }

    It 'rejects an unknown privileged action before opening the pipe' {
        $script:exchanged=$false
        $adapter = @{Exchange={ $script:exchanged=$true }}
        { Invoke-LanHostRequest -Action RunScript -Payload @{Script='anything'} -Adapter $adapter } | Should Throw
        $script:exchanged | Should Be $false
    }

    It 'requires a share id for Stop and never serializes Protected password into launch arguments' {
        $adapter = @{Exchange={}}
        { Invoke-LanHostRequest -Action Stop -Payload @{} -Adapter $adapter } | Should Throw
        $arguments = Get-LanHostHelperArguments -HelperPath 'C:\Program Files\LanFileSharing\HostHelper.ps1' -PipeName 'abc123'
        $arguments | Should Match 'HostHelper.ps1'
        $arguments | Should Match 'abc123'
        $arguments | Should Not Match 'MySecretPassword'
        $arguments | Should Not Match 'ProtectedPassword'
    }

    It 'passes a Protected password only in the in-memory request body' {
        $script:received=$null
        $adapter = @{Exchange={ param($action,$payload) $script:received=$payload; return @{Ok=$true} }}
        $payload=@{Kind='Folder';Path='F:\Data';Name='Data';Mode='Read';AuthMode='Protected';Password='MySecretPassword'}
        Invoke-LanHostRequest -Action Create -Payload $payload -Adapter $adapter | Out-Null
        $script:received.Password | Should Be 'MySecretPassword'
    }

    It 'reports UAC cancellation without writing or changing host state' {
        $adapter = @{Exchange={ throw 'The operation was canceled by the user.' }}
        { Invoke-LanHostRequest -Action List -Payload @{} -Adapter $adapter } | Should Throw 'canceled'
    }

    It 'validates a helper request before dispatch and returns a structured error' {
        $script:reply=$null
        $script:dispatched=$false
        $adapter=@{
            ReadRequest={ @{Action='RunScript';Payload=@{Script='anything'}} }
            Dispatch={ $script:dispatched=$true }
            WriteResponse={ param($response) $script:reply=$response }
        }
        Start-LanHostHelper -PipeName 'abc123' -Adapter $adapter
        $script:dispatched | Should Be $false
        $script:reply.Ok | Should Be $false
        $script:reply.Error | Should Match 'Unknown'
    }
    It 'frames a Protected request in memory and reads it back without a file' {
        $stream = New-Object IO.MemoryStream
        try {
            Write-LanHostPipeMessage -Stream $stream -Value @{Action='Create';Payload=@{Password='MySecretPassword'}}
            $stream.Position=0
            $received=Read-LanHostPipeMessage -Stream $stream
            $received.Payload.Password | Should Be 'MySecretPassword'
        } finally { $stream.Dispose() }
    }
    It 'exchanges one request over a restricted local named pipe' {
        $pipeName='LanFileSharing-Test-'+[guid]::NewGuid().ToString('N')
        $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,
            [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096,(New-LanHostPipeSecurity))
        $job=$null
        try {
            $job=Start-Job -ArgumentList $modulePath,$pipeName -ScriptBlock {
                param($scriptPath,$name)
                . $scriptPath
                $client=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut)
                try {
                    $client.Connect(10000)
                    $request=Read-LanHostPipeMessage -Stream $client
                    Write-LanHostPipeMessage -Stream $client -Value @{Ok=$true;Result=@{Action=$request.Action}}
                } finally { $client.Dispose() }
            }
            $pending=$server.BeginWaitForConnection($null,$null)
            $pending.AsyncWaitHandle.WaitOne(10000) | Should Be $true
            $server.EndWaitForConnection($pending)
            Write-LanHostPipeMessage -Stream $server -Value @{Action='List';Payload=@{}}
            $reply=Read-LanHostPipeMessage -Stream $server
            $reply.Ok | Should Be $true
            $reply.Result.Action | Should Be 'List'
            Wait-Job -Job $job -Timeout 10 | Out-Null
            $job.State | Should Be 'Completed'
        } finally {
            $server.Dispose()
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'authorizes an installed user and replies through the host broker pipe' {
        $pipeName='LanFileSharing-BrokerTest-'+[guid]::NewGuid().ToString('N')
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,
            [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096,(New-LanHostBrokerPipeSecurity -AllowedSid $sid))
        $job=$null
        try {
            $job=Start-Job -ArgumentList $modulePath,$pipeName -ScriptBlock {
                param($scriptPath,$name)
                . $scriptPath
                Invoke-LanHostBrokerExchange -Action List -Payload @{} -PipeName $name
            }
            $pending=$server.BeginWaitForConnection($null,$null)
            $pending.AsyncWaitHandle.WaitOne(10000) | Should Be $true
            $server.EndWaitForConnection($pending)
            $result=Invoke-LanHostBrokerRequest -Pipe $server -AllowedSid $sid.Value -Dispatch { param($action,$payload) [pscustomobject]@{Action=$action} }
            $result.Ok | Should Be $true
            Wait-Job -Job $job -Timeout 10 | Out-Null
            $reply=Receive-Job -Job $job
            $reply.Available | Should Be $true
            $reply.Result.Action | Should Be 'List'
        } finally {
            $server.Dispose()
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'sends only display fields when listing host shares' {
        $entry=[pscustomobject]@{Id='one';Name='Laptop';Kind='Drive';SourcePath='F:\';Mode='Read';
            AuthMode='Protected';AutoStart=$true;Status='Running';LastError=$null;
            CredentialInfo=@{Password='secret'};InitialPassword='secret'}
        $public=ConvertTo-LanPublicShare -Entry $entry
        $public.Name | Should Be 'Laptop'
        ($public.PSObject.Properties.Name -contains 'CredentialInfo') | Should Be $false
        ($public.PSObject.Properties.Name -contains 'InitialPassword') | Should Be $false
    }
}
