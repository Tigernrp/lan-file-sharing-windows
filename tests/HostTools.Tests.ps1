foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
$script:nativeStopWrapper=${function:Stop-LanHostShare}
Describe 'Separate host diagnostics and configuration tools' {
 It 'checks Guest compatibility without changing Windows policy' {
  Mock New-LanAuthAdapter { @{GetGuestPolicy={@{Managed=$false;RequireSigning=$true;GuestEnabled=$false;PasswordProtectedSharing=$true}}} }
  Mock Enable-LanGuestConfiguration {throw 'Read-only check changed policy'}
  $r=Invoke-LanHostActionCore -Action CheckGuest -Payload @{}
  $r.Summary|Should Match 'Guest'
  $r.Supported|Should Be $false
 }
 It 'reports incomplete Stop cleanup instead of claiming all permissions were restored' {
  Mock Read-LanState {[pscustomobject]@{Shares=@()}}
  Mock Stop-LanHostShare {[pscustomobject]@{Stopped=$true;CleanupErrors=@('NTFS rollback denied')}}
  Mock Get-LanPublicShares {@()}
  $r=Invoke-LanHostActionCore -Action Stop -Payload @{Id='fixture'}
  $r.Summary|Should Match 'ไม่ครบ'
  @($r.CleanupErrors).Count|Should Be 1
 }
 It 'lets an accepted Stop wait for the worker state lock within the create lock budget' {
  $script:stopLockBudget=0
  Mock Enter-LanStateLock { param($StatePath,$TimeoutMilliseconds) $script:stopLockBudget=$TimeoutMilliseconds; [IO.MemoryStream]::new() }
  Mock Stop-LanHostShareCore { [pscustomobject]@{Stopped=$true;CleanupErrors=@()} }
  & $script:nativeStopWrapper -Id 'fixture' -StatePath 'memory-only' -Adapter @{} -LockTimeoutMilliseconds 180000|Out-Null
  $script:stopLockBudget|Should Be 180000
 }
 It 'restores the saved Host Guest snapshot through its own action' {
  $path=Join-Path $TestDrive 'host.json';$state=Read-LanState $path
  Mock Restore-LanGuestConfiguration { [pscustomobject]@{Skipped=@();Restored=@('GuestEnabled')} }
  $r=Invoke-LanHostActionCore -Action RestoreGuest -Payload @{}
  $r.Summary|Should Match 'คืนค่า'
 }
 It 'refuses to restore Guest policy while a Guest share is active' {
  Mock Read-LanState { [pscustomobject]@{Shares=@([pscustomobject]@{AuthMode='Guest'});OnlineSettings=@{Enabled=$false}} } -ParameterFilter {$Path -eq (Join-Path $env:ProgramData 'LanFileSharing\state.json')}
  Mock Restore-LanGuestConfiguration {throw 'Must not restore an active Guest share'}
  {Invoke-LanHostActionCore -Action RestoreGuest -Payload @{}}|Should Throw 'หยุด'
 }
 It 'rejects a renamed or replaced SMB share instead of calling it healthy' {
  $state=New-LanEmptyState
  $state.Shares=@([pscustomobject]@{Id='ours';Name='Lessons';SharePath='F:\Data';AuthMode='WindowsCurrent';AllowedSids=@();AclRecords=@();Status='Running'})
  $path=Join-Path $TestDrive 'health.json';Write-LanState $path $state
  $adapter=@{GetShare={param($name) @{Name=$name;Path='F:\Data';Description='someone else'}}}
  {Test-LanHostShareHealth -Id 'ours' -StatePath $path -Adapter $adapter}|Should Throw
 }
 It 'reports missing shares and non-running state as failures' {
  $path=Join-Path $TestDrive 'missing.json';$state=New-LanEmptyState
  $state.Shares=@([pscustomobject]@{Id='ours';Name='Lessons';SharePath='F:\Data';Status='Offline'})
  Write-LanState $path $state
  {Test-LanHostShareHealth -Id 'ours' -StatePath $path -Adapter @{GetShare={return $null}}}|Should Throw
 }
 It 'rejects SMB Deny even when the account also has an Allow' {
  $script:healthState=[pscustomobject]@{Shares=@([pscustomobject]@{Id='ours';Name='Lessons';SharePath=$TestDrive;Status='Running';AllowedSids=@('S-1-1-0');Mode='Read';AuthMode='WindowsCurrent';AclRecords=@()})}
  Mock Read-LanState {$script:healthState}
  Mock Resolve-LanSmbAccountNames {@('Everyone')}
  $adapter=@{GetShare={@{Path=$TestDrive;Description='LanFileSharing:ours'}};GetShareAccess={@(@{AccountName='Everyone';AccessControlType='Allow';AccessRight='Read'},@{AccountName='Everyone';AccessControlType='Deny';AccessRight='Full'})}}
  {Test-LanHostShareHealth -Id 'ours' -StatePath 'memory-only' -Adapter $adapter}|Should Throw
 }
 It 'rejects removed NTFS access even when Before and After had no app-added delta' {
  $script:healthState=[pscustomobject]@{Shares=@([pscustomobject]@{Id='ours';Name='Lessons';SharePath=$TestDrive;Status='Running';AllowedSids=@('S-1-1-0');Mode='Read';AuthMode='WindowsCurrent';AclRecords=@(@{Path=$TestDrive;Before='D:(A;OICI;0x1200a9;;;WD)';After='D:(A;OICI;0x1200a9;;;WD)'})})}
  Mock Read-LanState {$script:healthState}
  Mock Resolve-LanSmbAccountNames {@('Everyone')}
  Mock Get-LanNtfsAccess {New-Object Security.AccessControl.DirectorySecurity}
  $adapter=@{GetShare={@{Path=$TestDrive;Description='LanFileSharing:ours'}};GetShareAccess={@(@{AccountName='Everyone';AccessControlType='Allow';AccessRight='Read'})}}
  {Test-LanHostShareHealth -Id 'ours' -StatePath 'memory-only' -Adapter $adapter}|Should Throw
 }
 It 'exposes separate read-only, configure and restore buttons' {
  $f=New-LanHostForm -WireEvents:$false
  try{
   $u=$f.Tag;$f.Show();$u.AdvancedToggle.PerformClick()
   $u.GuestCheck.Visible|Should Be $true
   $u.GuestConfig.Visible|Should Be $true
   $u.GuestRestore.Visible|Should Be $true
   $u.CheckShare.Visible|Should Be $true
   ($u.GuestCheck -ne $u.GuestConfig)|Should Be $true
  }finally{$f.Dispose()}
 }
 It 'rejects a Guest share whose Guest account or policies are no longer ready' {
  $script:healthState=[pscustomobject]@{Shares=@([pscustomobject]@{Id='ours';Name='Lessons';SharePath=$TestDrive;Status='Running';AllowedSids=@('S-1-1-0');Mode='Read';AuthMode='Guest';AclRecords=@()});OnlineSettings=@{Enabled=$false}}
  Mock Read-LanState {$script:healthState}
  Mock Resolve-LanSmbAccountNames {@('Everyone')}
  Mock Get-LanGuestCompatibility {[pscustomobject]@{Supported=$true;RequiredChanges=@('GuestEnabled')}}
  $adapter=@{GetShare={@{Path=$TestDrive;Description='LanFileSharing:ours'}};GetShareAccess={@(@{AccountName='Everyone';AccessControlType='Allow';AccessRight='Read'})}}
  {Test-LanHostShareHealth -Id 'ours' -StatePath 'memory-only' -Adapter $adapter}|Should Throw
 }
}
