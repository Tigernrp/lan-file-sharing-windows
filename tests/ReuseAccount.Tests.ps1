foreach ($module in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')) {
    . "$PSScriptRoot/../src/$module.ps1"
}

Describe 'Use existing host account button' {
    BeforeEach {
        $script:reuseStatePath=Join-Path $TestDrive 'host-state.json'
        $state=New-LanEmptyState
        $state.Shares=@([pscustomobject]@{Id='saved';AuthMode='Protected';CredentialInfo=@{
            UserName='ReuseFixture';Sid='S-1-5-21-111-222-333-1001';PasswordCipher=(Protect-LanSecret 'FixturePassword1!')
        }})
        Write-LanState $script:reuseStatePath $state
        # Only the OS account lookup is simulated; lookup, DPAPI and click callback stay real.
        Mock Get-LocalUser { [pscustomobject]@{Name='ReuseFixture';Enabled=$true;Description='LAN File Sharing app account';SID=@{Value='S-1-5-21-111-222-333-1001'}} }
    }
    It 'fills the saved account and masked password through the actual click' {
        $f=New-LanHostForm -WireEvents:$false
        try {
            $u=$f.Tag;$u.StatePath=$script:reuseStatePath;$f.Show()
            $u.AccountName.Text='Draft';$u.PasswordInput.Text='DraftPassword1!'
            $u.Path.Text='F:\Draft';$u.Name.Text='DraftShare'
            $u.ReuseAccount.PerformClick()
            $u.AccountName.Text|Should Be 'ReuseFixture'
            $u.PasswordInput.Text|Should Be 'FixturePassword1!'
            $u.PasswordInput.UseSystemPasswordChar|Should Be $true
            $u.Status.Text|Should Match 'ReuseFixture'
            $u.Status.Text|Should Not Match 'FixturePassword1!|not recognized'
            $u.Path.Text|Should Be 'F:\Draft';$u.Name.Text|Should Be 'DraftShare'
        } finally {$f.Dispose()}
    }
    It 'switches to Protected so the restored password is visible as a masked field' {
        $f=New-LanHostForm -WireEvents:$false
        try {
            $u=$f.Tag;$u.StatePath=$script:reuseStatePath;$f.Show();$u.Auth.SelectedItem='WindowsCurrent'
            $u.ReuseAccount.PerformClick()
            $u.Auth.Text|Should Be 'Protected Password'
            $u.PasswordInput.Visible|Should Be $true
            $u.PasswordInput.Text|Should Be 'FixturePassword1!'
        } finally {$f.Dispose()}
    }
    It 'explains absence and keeps the draft intact when no saved account exists' {
        Write-LanState $script:reuseStatePath (New-LanEmptyState)
        $f=New-LanHostForm -WireEvents:$false
        try {
            $u=$f.Tag;$u.StatePath=$script:reuseStatePath;$f.Show()
            $u.AccountName.Text='Draft';$u.PasswordInput.Text='DraftPassword1!'
            $u.ReuseAccount.PerformClick()
            $u.Status.Text|Should Match 'ยังไม่มีบัญชี'
            $u.AccountName.Text|Should Be 'Draft';$u.PasswordInput.Text|Should Be 'DraftPassword1!'
        } finally {$f.Dispose()}
    }
    It 'reports a read failure and allows a later retry after state is repaired' {
        $f=New-LanHostForm -WireEvents:$false
        try {
            $u=$f.Tag;$u.StatePath=$script:reuseStatePath;$f.Show()
            $saved=[IO.File]::ReadAllText($script:reuseStatePath)
            [IO.File]::WriteAllText($script:reuseStatePath,'bad json')
            $u.ReuseAccount.PerformClick()
            $u.Status.Text|Should Match 'Cannot read LAN share state'
            [IO.File]::WriteAllText($script:reuseStatePath,$saved)
            $u.ReuseAccount.PerformClick()
            $u.AccountName.Text|Should Be 'ReuseFixture'
        } finally {$f.Dispose()}
    }
}
