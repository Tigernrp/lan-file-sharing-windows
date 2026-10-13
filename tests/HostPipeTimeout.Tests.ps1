. "$PSScriptRoot/../src/HostBridge.ps1"
Describe 'broker response deadlines' {
    It 'bounds pipe IO when the broker reads requests: <ReadRequest>' -TestCases @(@{ReadRequest=$false},@{ReadRequest=$true}) {
        param($ReadRequest)
        $name = 'LanFileSharing-Stalled-' + [guid]::NewGuid().ToString('N')
        $job = Start-Job -ArgumentList $name,$ReadRequest,(Join-Path $PSScriptRoot '../src/HostBridge.ps1') -ScriptBlock {
            param($name,$readRequest,$module)
            . $module
            $server = [IO.Pipes.NamedPipeServerStream]::new($name,[IO.Pipes.PipeDirection]::InOut)
            try {
                $server.WaitForConnection()
                if ($readRequest) { Read-LanHostPipeMessage -Stream $server | Out-Null }
                Start-Sleep -Seconds 4
            }
            finally { $server.Dispose() }
        }
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $failure = $null
            $payload = if ($ReadRequest) { @{} } else { @{Probe=('x' * 100000)} }
            try { Invoke-LanHostBrokerExchange -Action List -Payload $payload -PipeName $name -WaitMilliseconds 1500 | Out-Null }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Timed out'
            $watch.Elapsed.TotalSeconds | Should BeLessThan 3
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}
