foreach($m in @('Selection','State','Progress','Auth','SingleFile','Host')){. "$PSScriptRoot/../src/$m.ps1"}
$script:realAclSet=${function:Set-LanNtfsAccess}
if(-not ('LanAclRecoveryFixture' -as [type])){
 Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class LanAclRecoveryFixture {
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]public static extern bool SetFileSecurity(string path,uint info,byte[] sd);
}
'@
}
function New-LanNormalizationFixture {
 param($Root)
 [IO.Directory]::CreateDirectory($Root)|Out-Null
 $caller=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $acl=[Security.AccessControl.DirectorySecurity]::new()
 $acl.SetSecurityDescriptorSddlForm(('D:P(A;;FA;;;'+$caller+')(A;OICIIO;SDGXGWGR;;;AU)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'))
 & $script:realAclSet $Root $acl
 $child=Join-Path $Root 'child';[IO.Directory]::CreateDirectory($child)|Out-Null
 $stale=[Security.AccessControl.DirectorySecurity]::new()
 $stale.SetSecurityDescriptorSddlForm('D:(A;OICIID;FA;;;BA)(A;OICIID;FA;;;SY)(A;OICIID;0x1200a9;;;BU)(A;ID;0x1301bf;;;AU)(A;OICIIOID;SDGXGWGR;;;AU)')
 if(-not [LanAclRecoveryFixture]::SetFileSecurity($child,4,$stale.GetSecurityDescriptorBinaryForm())){throw 'Native stale-inheritance fixture failed'}
 return $child
}
Describe 'NTFS normalization and bounded automatic recovery' {
 BeforeEach {
  $script:writes=0;$script:writeMode='normal'
  $script:aclTargetSid='S-1-5-21-1-2-3-49999'
  Mock Set-LanNtfsAccess {
   param($Path,$Acl)
   $script:writes++
   if($script:writeMode -eq 'drop' -or ($script:writeMode -eq 'drop-first' -and $script:writes -eq 1)){return}
   & $script:realAclSet $Path $Acl
   if($script:writeMode -eq 'foreign' -and $script:writes -eq 1){
    $fresh=Get-LanNtfsAccess $Path
    $fresh.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-546'),[Security.AccessControl.FileSystemRights]::ReadAndExecute,[Security.AccessControl.AccessControlType]::Allow))
    & $script:realAclSet $Path $fresh
   }
  }
 }
 It 'accepts native inherited Allow reordering and preserves the original ACL on revoke' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'normalization')
  $before=(Get-LanNtfsAccess $child).GetSecurityDescriptorSddlForm('Access')
  $records=@();try{
   $records=@(Grant-LanNtfsAcl $child @($script:aclTargetSid) Modify)
   $records.Count|Should Be 1
   Test-LanNtfsAclEquivalent $records[0].After ((Get-LanNtfsAccess $child).GetSecurityDescriptorSddlForm('Access'))|Should Be $true
  }finally{if($records.Count){Revoke-LanNtfsAcl $records}}
  Test-LanNtfsAclEquivalent $before ((Get-LanNtfsAccess $child).GetSecurityDescriptorSddlForm('Access'))|Should Be $true
 }
 It 'automatically retries a missing write while persisting intention before each attempt' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'retry');$script:writeMode='drop-first';$script:journalWrites=0
  $records=@();try{
   $records=@(Grant-LanNtfsAcl $child @($script:aclTargetSid) Modify -BeforeApply {param($r)$script:journalWrites++})
   $script:writes|Should Be 2;$script:journalWrites|Should Be 2;$records.Count|Should Be 1
  }finally{if($records.Count){Revoke-LanNtfsAcl $records}}
 }
 It 'commits one durable ACL intention when a host transaction retries the write' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'transaction-retry');$script:writeMode='drop-first'
  $path=Join-Path $TestDrive 'state.json';$entry=$null
  $adapter=@{
   GetProfile={'Private'};GetShare={param($name)$null};EnableFirewall={@{Owned=$false}};RemoveFirewall={}
   GrantAcl={param($path,$sids,$mode,$beforeApply,$kind) Grant-LanNtfsAcl -Path $path -Sids $sids -Mode $mode -BeforeApply $beforeApply -Kind $kind}
   RevokeAcl={param($records) Revoke-LanNtfsAcl $records};NewShare={};RemoveShare={}
  }
  try{
   $entry=Start-LanHostShare -Selection (Resolve-LanSelection Folder $child) -Name FixtureRetry -Mode Modify -AutoStart $false -Access ([pscustomobject]@{AuthMode='WindowsCurrent';AllowedSids=@($script:aclTargetSid);CredentialInfo=$null}) -StatePath $path -Adapter $adapter
   $script:writes|Should Be 2
   @((Read-LanState $path).Shares[0].AclRecords).Count|Should Be 1
   @((Read-LanState $path).Journal).Count|Should Be 0
  }finally{if($entry){Revoke-LanNtfsAcl $entry.AclRecords}}
 }
 It 'bounds failed recovery and leaves the original permissions intact' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'bounded');$script:writeMode='drop'
  $before=(Get-LanNtfsAccess $child).GetSecurityDescriptorSddlForm('Access')
  {Grant-LanNtfsAcl $child @($script:aclTargetSid) Modify}|Should Throw
  $script:writes|Should Be 3
  Test-LanNtfsAclEquivalent $before ((Get-LanNtfsAccess $child).GetSecurityDescriptorSddlForm('Access'))|Should Be $true
 }
 It 'does not overwrite an unrelated concurrent change and removes its own failed grant' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'foreign');$script:writeMode='foreign'
  {Grant-LanNtfsAcl $child @($script:aclTargetSid) Modify}|Should Throw
  $rules=@((Get-LanNtfsAccess $child).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
  @($rules|Where-Object {$_.IdentityReference.Value -eq $script:aclTargetSid}).Count|Should Be 0
  @($rules|Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-546'}).Count|Should Be 1
 }
 It 'compares generic masks but rejects permission, protection or inheritance changes' {
  Test-LanNtfsAclEquivalent 'D:(A;;GR;;;AU)' 'D:AI(A;;0x120089;;;AU)'|Should Be $true
  Test-LanNtfsAclEquivalent 'D:(A;;GA;;;AU)' 'D:(A;;0x11000000;;;AU)'|Should Be $false
  foreach($actual in @('D:(A;;FA;;;AU)','D:P(A;;GR;;;AU)','D:(A;ID;GR;;;AU)','D:')){
   Test-LanNtfsAclEquivalent 'D:(A;;GR;;;AU)' $actual|Should Be $false
  }
 }
 It 'preserves an existing explicit target Read grant when normalized Modify is revoked' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'merged')
  $acl=Get-LanNtfsAccess $child
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($script:aclTargetSid),[Security.AccessControl.FileSystemRights]::ReadAndExecute,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
  # Legacy setter retains the original inherited ordering before the upgrade.
  $sddl=$acl.GetSecurityDescriptorSddlForm('Access')
  [LanAclRecoveryFixture]::SetFileSecurity($child,4,$acl.GetSecurityDescriptorBinaryForm())|Should Be $true
  $records=@(Grant-LanNtfsAcl $child @($script:aclTargetSid) Modify)
  Revoke-LanNtfsAcl $records
  Test-LanNtfsAclEquivalent $sddl ((Get-LanNtfsAccess $child).GetSecurityDescriptorSddlForm('Access'))|Should Be $true
 }
 It 'keeps original target Read and unrelated new rights while removing a failed merged grant' {
  $child=New-LanNormalizationFixture (Join-Path $TestDrive 'merged-foreign')
  $acl=Get-LanNtfsAccess $child
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($script:aclTargetSid),[Security.AccessControl.FileSystemRights]::ReadAndExecute,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
  & $script:realAclSet $child $acl
  $script:writeMode='foreign'
  {Grant-LanNtfsAcl $child @($script:aclTargetSid) Modify}|Should Throw
  $rules=@((Get-LanNtfsAccess $child).GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
  $target=@($rules|Where-Object {$_.IdentityReference.Value -eq $script:aclTargetSid})
  $target.Count|Should Be 1
  ([int]$target[0].FileSystemRights)|Should Be ([int][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [int][Security.AccessControl.FileSystemRights]::Synchronize)
  @($rules|Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-546'}).Count|Should Be 1
 }
 It 'never treats Deny reordering or unknown ACEs as harmless Allow normalization' {
  Test-LanNtfsAclEquivalent 'D:(D;;GW;;;AU)(A;;GR;;;AU)' 'D:(A;;GR;;;AU)(D;;GW;;;AU)'|Should Be $false
  Test-LanNtfsAclEquivalent 'D:(A;;GR;;;AU)' 'D:(D;;GR;;;AU)'|Should Be $false
  Test-LanNtfsAclEquivalent 'D:(OA;;GR;00000000-0000-0000-0000-000000000001;;AU)' 'D:(A;;GR;;;AU)'|Should Be $false
 }
}
