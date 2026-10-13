foreach($m in @('State','Online','Auth','ClientMap')){. "$PSScriptRoot/../src/$m.ps1"}
Describe 'Remembered connection review gates' {
    It 'uses the actual server target and qualified account for Windows credential matching' {
        $script:emitted=$null
        Set-LanWindowsCredential 'HOST' 'HOST\share' 'SyntheticPassword1!' -Query {
            param($p)
            $c=[Runtime.InteropServices.Marshal]::PtrToStructure($p,[type][LanCredentialNative+Credential])
            $script:emitted=@{Target=[Runtime.InteropServices.Marshal]::PtrToStringUni($c.TargetName);User=[Runtime.InteropServices.Marshal]::PtrToStringUni($c.UserName)}
            $true
        }|Out-Null
        $script:emitted.Target|Should Be 'HOST';$script:emitted.User|Should Be 'HOST\share'
    }
    It 'reclaims only a stale saved letter after error 85 and retries it' {
        $script:mapping='\\HOST\Saved';$script:calls=0;$script:closed=@();$script:ready=$false
        $a=@{GetMapping={param($l)$script:mapping};ProbeAccess={param($p)if(-not $script:ready){throw 'offline'}};GetSession={'HOST\share'};GetRememberedCredential={param($h,$ctx)@{UserName='HOST\share';Password='SyntheticPassword1!'}};Connect={param($u,$l,$persistent,$prompt,$user,$pw)$script:calls++;if($script:calls -eq 1){85}else{$script:mapping=$u;$script:ready=$true;0}};Disconnect={param($l,$p,$force)$script:closed+=@($l);$script:mapping='';0}}
        $entry=[pscustomobject]@{Letter='P';Unc='\\HOST\Saved';AuthMode='Protected';WindowsAccount='HOST\share';Persistent=$true}
        Invoke-LanSavedConnection $entry $a|Should Be 'Connected'
        $script:closed|Should Be @('P');$script:calls|Should Be 2
    }
    It 'never releases a letter now assigned to another share' {
        $script:closed=@()
        $a=@{GetMapping={'\\OTHER\Data'};GetOccupiedLetters={@('P')};ProbeAccess={};GetSession={'HOST\share'};GetRememberedCredential={param($h,$ctx)@{UserName='HOST\share';Password='SyntheticPassword1!'}};Connect={85};Disconnect={param($l)$script:closed+=@($l);0}}
        Invoke-LanSavedConnection ([pscustomobject]@{Letter='P';Unc='\\HOST\Saved';AuthMode='Protected';WindowsAccount='HOST\share';Persistent=$true}) $a|Should Be 'Waiting'
        $script:closed.Count|Should Be 0
    }
}
