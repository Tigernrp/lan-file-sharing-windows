foreach($m in @('Selection','State','Progress','Online','Auth','SingleFile','Host','ClientMap','InstallLocation','Startup','HostBridge','UserStartup','Ui')){. "$PSScriptRoot/../src/$m.ps1"}
Describe 'Large host operations and independent status reads' {
 It 'reads the same file and directory DACL without the PowerShell provider' {
  $folder=Join-Path $TestDrive 'acl';[IO.Directory]::CreateDirectory($folder)|Out-Null
  $file=Join-Path $folder 'sample.txt';[IO.File]::WriteAllText($file,'sample')
  foreach($p in @($folder,$file)){
   $expected=(Get-Acl -LiteralPath $p).GetSecurityDescriptorSddlForm('Access')
   (Get-LanNtfsAccess -Path $p).GetSecurityDescriptorSddlForm('Access')|Should Be $expected
  }
 }
 It 'reads share lists locally and asks the privileged broker for protected NetBird status' {
  Mock Invoke-LanHostBrokerExchange {[pscustomobject]@{Available=$true;Result=[pscustomobject]@{ConnectionState='Connected'}}}
  Mock Get-LanPublicShares { [pscustomobject]@{Id='real';Name='Lessons';Status='Running'} }
  Mock Read-LanState { [pscustomobject]@{OnlineSettings=[pscustomobject]@{Enabled=$false;AllowedPeers=@()}} }
  (Invoke-LanHostPreferredExchange -Action List -Payload @{} -HelperPath 'unused').Name|Should Be 'Lessons'
  (Invoke-LanHostPreferredExchange -Action OnlineStatus -Payload @{} -HelperPath 'unused').ConnectionState|Should Be 'Connected'
  Assert-MockCalled Invoke-LanHostBrokerExchange -Times 1 -Exactly -Scope It -ParameterFilter {$Action -eq 'OnlineStatus'}
 }
 It 'waits for accepted work longer than its connection budget without resending Create' {
  $name='LanLarge-'+[guid]::NewGuid().ToString('N')
  $server=[IO.Pipes.NamedPipeServerStream]::new($name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
  $job=$null
  try{
   $job=Start-Job -ArgumentList (Join-Path $PSScriptRoot '../src/HostBridge.ps1'),$name -ScriptBlock {
    param($module,$name);. $module
    Invoke-LanHostBrokerExchange -Action Create -Payload @{} -PipeName $name -WaitMilliseconds 3000 -CompletionTimeoutMilliseconds 10000
   }
   $pending=$server.BeginWaitForConnection($null,$null);$pending.AsyncWaitHandle.WaitOne(15000)|Should Be $true;$server.EndWaitForConnection($pending)
   (Read-LanHostPipeMessage $server).Action|Should Be 'Create'
   Start-Sleep -Milliseconds 3500
   Write-LanHostPipeMessage $server @{Ok=$true;Result=@{Name='Completed'}}
   Wait-Job $job -Timeout 15|Out-Null
   (Receive-Job $job -ErrorAction Stop).Result.Name|Should Be 'Completed'
  }finally{$server.Dispose();if($job){Remove-Job $job -Force -ErrorAction SilentlyContinue}}
 }
 It 'updates the outcome when Refresh shows a Running share' {
  $f=New-LanHostForm -WireEvents:$false
  try{
   $u=$f.Tag;$u.Status.Text='Timed out';$u.Name.Text='Lessons'
   Update-LanHostList -Ui $u -StatePath 'unused' -Entries @([pscustomobject]@{Id='real';Name='Lessons';SourcePath='F:\Data';AuthMode='Protected';Status='Running'})
   $u.Status.Text|Should Match 'แชร์พร้อมใช้.*Lessons'
  }finally{$f.Dispose()}
 }
 It 'shows a late Running share automatically without a Refresh click' {
  $script:lateStatePath=Join-Path $TestDrive 'late-state.json'
  Mock Get-LanHostStatePath {$script:lateStatePath}
  Write-LanState $script:lateStatePath (New-LanEmptyState)
  $f=New-LanHostForm -UseBridge:$true
  try{
   $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'late-ui.json';$f.Show();$u.Name.Text='Lessons';$u.Status.Text='Timed out'
   $state=New-LanEmptyState;$state.Shares=@([pscustomobject]@{Id='late';Name='Lessons';SourcePath='F:\Data';Mode='Read';AuthMode='Protected';Status='Running';NtfsPolicy='Managed'})
   Write-LanState $script:lateStatePath $state
   $deadline=[DateTime]::UtcNow.AddSeconds(6)
   while($u.ShareList.Items.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
   $u.ShareList.Items.Count|Should Be 1
   $u.Status.Text|Should Match 'แชร์พร้อมใช้.*Lessons'
  }finally{$f.Dispose()}
 }
 It 'reenables all tools after tracking a late successful Create' {
  $script:lateStatePath=Join-Path $TestDrive 'late-tracked-state.json'
  Mock Get-LanHostStatePath {$script:lateStatePath}
  Write-LanState $script:lateStatePath (New-LanEmptyState)
  $f=New-LanHostForm -UseBridge:$true
  try{
   $u=$f.Tag;$u.PreferencePath=Join-Path $TestDrive 'tracked-ui.json';$f.Show();$u.Name.Text='Lessons'
   $u.JobMode='Create';$u.PendingHostRequest=@{Name='Lessons';Path='F:\Data';Mode='Read';AuthMode='Protected'};$u.PreviousHostIds=@();$u.AwaitingHostOutcome=$true
   foreach($b in $u.HostToolButtons){$b.Enabled=$false};$u.Create.Enabled=$false;$u.Stop.Enabled=$false
   $state=New-LanEmptyState;$state.Shares=@([pscustomobject]@{Id='tracked';Name='Lessons';SourcePath='F:\Data';Mode='Read';AuthMode='Protected';Status='Running';NtfsPolicy='Managed'})
   Write-LanState $script:lateStatePath $state
   $deadline=[DateTime]::UtcNow.AddSeconds(6)
   while($u.AwaitingHostOutcome -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
   $u.AwaitingHostOutcome|Should Be $false
   foreach($b in $u.HostToolButtons){$b.Enabled|Should Be $true}
   $u.Create.Enabled|Should Be $true
  }finally{$f.Dispose()}
 }
 It 'does not turn a failed Stop into success just because the same share still exists' {
  # This uses the recovery function independently of the native process boundary.
  $f=New-LanHostForm -WireEvents:$false
  try{
   $u=$f.Tag;$u.JobMode='Stop';$u.PendingHostRequest=@{Id='real'}
   $state=[pscustomobject]@{Shares=@([pscustomobject]@{Id='real';Name='Lessons';Status='Running'});Journal=@()}
   (Resolve-LanHostOperationOutcome -Ui $u -State $state).State|Should Be 'Failed'
  }finally{$f.Dispose()}
 }
 It 'does not hide a failed Stop cleanup when the share record is already gone' {
  $u=@{JobMode='Stop';PendingHostRequest=@{Id='gone'}}
  (Resolve-LanHostOperationOutcome $u ([pscustomobject]@{Shares=@();Journal=@()})).State|Should Be 'Failed'
 }
 It 'does not report a retained inactive rollback journal as ongoing work' {
  $u=@{JobMode='Create';PendingHostRequest=@{Name='Lessons';Path='F:\Data'}}
  $state=[pscustomobject]@{Shares=@();Journal=@([pscustomobject]@{Id='failed';Name='Lessons';SourcePath='F:\Data';ActiveProcessId=0})}
  (Resolve-LanHostOperationOutcome $u $state).State|Should Be 'Failed'
 }
 It 'correlates canonical paths when a folder ends in a separator' {
  $u=@{JobMode='Create';PendingHostRequest=@{Name='Lessons';Path='F:\Data\';Mode='Read';AuthMode='Protected'};PreviousHostIds=@()}
  $state=[pscustomobject]@{Shares=@([pscustomobject]@{Id='new';Name='Lessons';SourcePath='F:\Data';Mode='Read';AuthMode='Protected';Status='Running'});Journal=@()}
  (Resolve-LanHostOperationOutcome $u $state).State|Should Be 'Running'
 }
 It 'does not recover a different path or an older share with the same name' {
  $f=New-LanHostForm -WireEvents:$false
  try{
   $u=$f.Tag;$u.JobMode='Create';$u.PendingHostRequest=@{Name='Lessons';Path='F:\New';Mode='Read';AuthMode='Protected'};$u.PreviousHostIds=@('old')
   $state=[pscustomobject]@{Shares=@([pscustomobject]@{Id='old';Name='Lessons';SourcePath='F:\Old';Mode='Read';AuthMode='Protected';Status='Running'});Journal=@()}
   (Resolve-LanHostOperationOutcome -Ui $u -State $state).State|Should Be 'Failed'
  }finally{$f.Dispose()}
 }
 It 'does not credit an older preparing journal promoted to Running after this click' {
  $u=@{JobMode='Create';PendingHostRequest=@{Name='Lessons';Path='F:\Data';Mode='Read';AuthMode='Protected'};PreviousHostIds=@();PreviousJournalIds=@('earlier')}
  $state=[pscustomobject]@{Shares=@([pscustomobject]@{Id='earlier';Name='Lessons';SourcePath='F:\Data';Mode='Read';AuthMode='Protected';Status='Running'});Journal=@()}
  (Resolve-LanHostOperationOutcome $u $state).State|Should Be 'Failed'
 }
}
