. "$PSScriptRoot/../src/State.ps1"
. "$PSScriptRoot/../src/Selection.ps1"
. "$PSScriptRoot/../src/Progress.ps1"
. "$PSScriptRoot/../src/Auth.ps1"
. "$PSScriptRoot/../src/Host.ps1"
. "$PSScriptRoot/../src/Online.ps1"
. "$PSScriptRoot/../src/Startup.ps1"
Describe 'Online cleanup' {
    It 'removes only the application rule and never calls the NetBird service' {
        $script:removed=$false
        $a=@{GetOnlineRule={@{Description='Created by LAN File Sharing (NetBird)'}};RemoveOnlineRule={$script:removed=$true}}
        Remove-LanOnlineFirewall -Adapter $a
        $script:removed | Should Be $true
        $a.GetOnlineRule={@{Description='foreign'}}
        {Remove-LanOnlineFirewall -Adapter $a} | Should Throw
    }
    It 'cleans Online before removing the app files' {
        $script:events=New-Object Collections.ArrayList
        $p=Join-Path $TestDrive 'state.json';Write-LanState $p (New-LanEmptyState)
        $a=@{StatePath=$p;StopTask={};StopBrokerTask={};GetShare={$null};UnregisterTask={};UnregisterBrokerTask={};
            RemoveOnlineFirewall={ [void]$script:events.Add('online') };RemoveInstalledFiles={ [void]$script:events.Add('files') }}
        Remove-LanHostWorker -Adapter $a | Out-Null
        ($script:events -join ',') | Should Be 'online,files'
    }
}
