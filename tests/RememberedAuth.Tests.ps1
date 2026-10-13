. "$PSScriptRoot/../src/Auth.ps1"

Describe 'remembered Protected account lifetime' {
    BeforeEach {
        # Exercise the real adapter. Only Windows account operations are replaced;
        # these tests must never create accounts or change the machine's policy.
        $script:accounts = @{}
        $script:accountChanges = @()
        $script:newAccount = $null
        Mock Get-LocalUser { param($Name) $script:accounts[$Name] }
        Mock New-LocalUser {
            param($Name,$Password,$Description,$PasswordNeverExpires)
            $script:newAccount = [pscustomobject]@{
                Name=$Name; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1002')
                Description=$Description; Enabled=$true; PasswordNeverExpires=[bool]$PasswordNeverExpires
                Password=$Password
            }
            $script:accounts[$Name] = $script:newAccount
            $script:newAccount
        }
        Mock Set-LocalUser {
            param($Name,$SID,$Password,$PasswordNeverExpires)
            $script:accountChanges += [pscustomobject]@{
                Name=$Name; Sid=[string]$SID; ChangesPassword=($null -ne $Password)
                PasswordNeverExpires=[bool]$PasswordNeverExpires
            }
            $account = if ($SID) {
                @($script:accounts.Values | Where-Object { [string]$_.SID -eq [string]$SID })[0]
            } else { $script:accounts[$Name] }
            if ($account) { $account.PasswordNeverExpires = [bool]$PasswordNeverExpires }
        }
        Mock Enable-LocalUser { throw 'Account activation is outside remembered credential repair.' }
    }

    It 'creates an app account with a strong random password that does not expire' {
        $adapter = New-LanAuthAdapter
        $credential = & $adapter.CreateProtected ''

        $credential.UserName | Should Match '^LFS_'
        $credential.Password.Length | Should BeGreaterThan 24
        $credential.Password | Should Match 'a1!$'
        $script:newAccount.Description | Should Be 'LAN File Sharing app account'
        $script:newAccount.PasswordNeverExpires | Should Be $true
        $script:newAccount.Password | Should BeOfType ([Security.SecureString])
    }

    It 'creates a new Protected account with the exact available name chosen by the owner' {
        $adapter = New-LanAuthAdapter
        $adapter.PreferredAccountName = 'LFS_Ks'

        $credential = & $adapter.CreateProtected 'Chosen#Pass123'

        $credential.UserName | Should Be 'LFS_Ks'
        $script:newAccount.Name | Should Be 'LFS_Ks'
        $credential.Password | Should Be 'Chosen#Pass123'
    }

    It 'upgrades a positively owned remembered account without changing its password or enabled state' {
        $script:accounts.LFS_saved = [pscustomobject]@{
            Name='LFS_saved'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1001')
            Description='LAN File Sharing app account'; Enabled=$false; PasswordNeverExpires=$false
        }
        $adapter = New-LanAuthAdapter
        $reuse = @{UserName='LFS_saved'; Sid='S-1-5-21-100-200-300-1001'; Password='Existing#Pass123'}

        $credential = & $adapter.CreateProtected '' $reuse

        $credential.Password | Should Be 'Existing#Pass123'
        $credential.Sid | Should Be 'S-1-5-21-100-200-300-1001'
        $script:accounts.LFS_saved.PasswordNeverExpires | Should Be $true
        $script:accounts.LFS_saved.Enabled | Should Be $false
        $script:accountChanges.Count | Should Be 1
        $script:accountChanges[0].Sid | Should Be 'S-1-5-21-100-200-300-1001'
        $script:accountChanges[0].ChangesPassword | Should Be $false
    }

    It 'rejects remembered credentials for an account without the app ownership marker' {
        $script:accounts.owner = [pscustomobject]@{
            Name='owner'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1001')
            Description='Personal Windows account'; Enabled=$false; PasswordNeverExpires=$false
        }
        $adapter = New-LanAuthAdapter
        $reuse = @{UserName='owner'; Sid='S-1-5-21-100-200-300-1001'; Password='Existing#Pass123'}

        { & $adapter.CreateProtected '' $reuse } | Should Throw

        $script:accounts.owner.PasswordNeverExpires | Should Be $false
        $script:accounts.owner.Enabled | Should Be $false
        $script:accountChanges.Count | Should Be 0
        $script:newAccount | Should BeNullOrEmpty
    }

    It 'rejects a remembered SID when the name now belongs to a different account' {
        $script:accounts.LFS_saved = [pscustomobject]@{
            Name='LFS_saved'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1009')
            Description='LAN File Sharing app account'; Enabled=$true; PasswordNeverExpires=$false
        }
        $adapter = New-LanAuthAdapter
        $reuse = @{UserName='LFS_saved'; Sid='S-1-5-21-100-200-300-1001'; Password='Existing#Pass123'}

        { & $adapter.CreateProtected '' $reuse } | Should Throw

        $script:accounts.LFS_saved.PasswordNeverExpires | Should Be $false
        $script:accountChanges.Count | Should Be 0
    }

    It 'rejects remembered credentials when the Windows account has been deleted' {
        $adapter = New-LanAuthAdapter
        $reuse = @{UserName='LFS_deleted'; Sid='S-1-5-21-100-200-300-1001'; Password='Existing#Pass123'}

        { & $adapter.CreateProtected '' $reuse } | Should Throw

        $script:accountChanges.Count | Should Be 0
        $script:newAccount | Should BeNullOrEmpty
    }

    It 'still rejects a different supplied password before changing a reused account' {
        $script:accounts.LFS_saved = [pscustomobject]@{
            Name='LFS_saved'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1001')
            Description='LAN File Sharing app account'; Enabled=$true; PasswordNeverExpires=$false
        }
        $adapter = New-LanAuthAdapter
        $reuse = @{UserName='LFS_saved'; Sid='S-1-5-21-100-200-300-1001'; Password='Existing#Pass123'}

        { & $adapter.CreateProtected 'Different#Pass123' $reuse } | Should Throw 'different password'

        $script:accounts.LFS_saved.PasswordNeverExpires | Should Be $false
        $script:accountChanges.Count | Should Be 0
    }

    It 'rejects a requested name that belongs to another Windows account instead of silently substituting one' {
        $script:accounts.owner = [pscustomobject]@{
            Name='owner'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1001')
            Description='Personal Windows account'; Enabled=$false; PasswordNeverExpires=$false
        }
        $Adapter = New-LanAuthAdapter
        $Adapter.PreferredAccountName = 'owner'

        { & $Adapter.CreateProtected 'Chosen#Pass123' } | Should Throw

        $script:newAccount | Should BeNullOrEmpty
        $script:accounts.owner.PasswordNeverExpires | Should Be $false
        $script:accounts.owner.Enabled | Should Be $false
        $script:accountChanges.Count | Should Be 0
    }

    It 'keeps explicit app-owned orphan recovery while making its password nonexpiring' {
        $script:accounts.selected = [pscustomobject]@{
            Name='selected'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1001')
            Description='LAN File Sharing app account'; Enabled=$false; PasswordNeverExpires=$false
        }
        $Adapter = New-LanAuthAdapter
        $Adapter.PreferredAccountName = 'selected'

        $credential = & $Adapter.CreateProtected 'Chosen#Pass123'

        $credential.UserName | Should Be 'selected'
        $credential.Password | Should Be 'Chosen#Pass123'
        $script:accounts.selected.PasswordNeverExpires | Should Be $true
        $script:accounts.selected.Enabled | Should Be $false
        $script:accountChanges.Count | Should Be 1
        $script:accountChanges[0].Sid | Should Be 'S-1-5-21-100-200-300-1001'
        $script:accountChanges[0].ChangesPassword | Should Be $true
        $script:newAccount | Should BeNullOrEmpty
    }

    It 'refuses a name collision that appears between account selection and creation' {
        $script:accounts.selected = [pscustomobject]@{
            Name='selected'; SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1001')
            Description='Personal Windows account'; Enabled=$false; PasswordNeverExpires=$false
        }
        $script:lookups = 0
        Mock Get-LocalUser {
            param($Name)
            $script:lookups++
            if ($script:lookups -gt 1) { $script:accounts[$Name] }
        }
        $Adapter = New-LanAuthAdapter
        $Adapter.PreferredAccountName = 'selected'

        { & $Adapter.CreateProtected 'Chosen#Pass123' } | Should Throw

        $script:accounts.selected.PasswordNeverExpires | Should Be $false
        $script:accounts.selected.Enabled | Should Be $false
        $script:accountChanges.Count | Should Be 0
        $script:newAccount | Should BeNullOrEmpty
    }
}
