function New-LanUserStartupAdapter {
    return @{
        ReadPreference={ param($name)
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\LanFileSharing')
            if ($key) { try { $key.GetValue($name,$null) } finally { $key.Close() } }
        }
        WritePreference={ param($name,$value)
            $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\LanFileSharing')
            try { $key.SetValue($name,[int]$value,[Microsoft.Win32.RegistryValueKind]::DWord) }
            finally { $key.Close() }
        }
        ReadRun={
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
            if ($key) { try { $key.GetValue('LanFileSharing',$null) } finally { $key.Close() } }
        }
        WriteRun={ param($value)
            $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
            try { $key.SetValue('LanFileSharing',$value,[Microsoft.Win32.RegistryValueKind]::String) }
            finally { $key.Close() }
        }
        RemoveRun={
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$true)
            if ($key) { try { $key.DeleteValue('LanFileSharing',$false) } finally { $key.Close() } }
        }
        RemovePreference={
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\LanFileSharing',$false)
        }
    }
}

function Get-LanUserStartupSettings {
    param([hashtable]$Adapter=(New-LanUserStartupAdapter))
    $run=[string](& $Adapter.ReadRun)
    $minimized=& $Adapter.ReadPreference 'StartMinimized'
    $delay=& $Adapter.ReadPreference 'ShowAfterSeconds'
    $reconnect=& $Adapter.ReadPreference 'AutoReconnect'
    if ($null -eq $delay -or [string]::IsNullOrWhiteSpace([string]$delay)) { $delay=15 }
    return [pscustomobject]@{
        # Any registered per-user login command counts, whatever quoting or extra arguments it
        # carries, so the check box always reflects what Windows will actually do.
        StartWithHost=(-not [string]::IsNullOrWhiteSpace($run) -and $run -match '(?i)(^|\s)--auto(\s|$)')
        StartMinimized=([int]$minimized -eq 1)
        # Seconds to wait before showing the window after an automatic start; 0 keeps it in the
        # notification area until the user asks for it.
        ShowAfterSeconds=[int]$delay
        # Reconnecting saved drives is what a reboot usually needs, so it defaults to on: a missing
        # value means the preference was never written, not that the user turned it off.
        AutoReconnect=($null -eq $reconnect -or [int]$reconnect -eq 1)
        LoginCommand=$run
    }
}

function Get-LanUserStartupState {
    param([hashtable]$Adapter=(New-LanUserStartupAdapter))
    # What the window shows and the user can act on: the exact login command Windows will run.
    $settings=Get-LanUserStartupSettings -Adapter $Adapter
    $description=if (-not $settings.StartWithHost) { 'ยังไม่เปิดอัตโนมัติ' }
        elseif (-not $settings.StartMinimized) { 'เปิดโปรแกรมอัตโนมัติเมื่อเข้าสู่ Windows (แสดงหน้าต่างทันที)' }
        elseif ($settings.ShowAfterSeconds -gt 0) { ('เปิดอัตโนมัติ + เด้งหน้าต่างหลัง {0} วินาที' -f $settings.ShowAfterSeconds) }
        else { 'เปิดอัตโนมัติ + อยู่ในถาดระบบเท่านั้น' }
    return [pscustomobject]@{
        Enabled=[bool]$settings.StartWithHost
        StartMinimized=[bool]$settings.StartMinimized
        ShowAfterSeconds=[int]$settings.ShowAfterSeconds
        LoginCommand=[string]$settings.LoginCommand
        Description=$description
    }
}

function Test-LanUserStartupRegistered {
    param([Parameter(Mandatory)][string]$LauncherPath,
          [hashtable]$Adapter=(New-LanUserStartupAdapter))
    $settings=Get-LanUserStartupSettings -Adapter $Adapter
    if (-not $settings.StartWithHost) { return $false }
    $expected='"' + $LauncherPath + '" --auto'
    return [string]::Equals([string]$settings.LoginCommand,$expected,[StringComparison]::OrdinalIgnoreCase)
}

function Set-LanUserStartupSettings {
    param([bool]$StartWithHost,[bool]$StartMinimized,[Parameter(Mandatory)][string]$LauncherPath,
        [int]$ShowAfterSeconds=15,
        [bool]$AutoReconnect=$true,
        [hashtable]$Adapter=(New-LanUserStartupAdapter))
    if ($StartWithHost) {
        if ($LauncherPath -notmatch '^[A-Za-z]:\\' -or $LauncherPath.Contains('"')) {
            throw 'The installed launcher path is invalid.'
        }
        & $Adapter.WriteRun ('"' + $LauncherPath + '" --auto')
    } else { & $Adapter.RemoveRun }
    & $Adapter.WritePreference 'StartMinimized' ([int]$StartMinimized)
    if ($ShowAfterSeconds -lt 0) { $ShowAfterSeconds = 0 }
    & $Adapter.WritePreference 'ShowAfterSeconds' ([int]$ShowAfterSeconds)
    & $Adapter.WritePreference 'AutoReconnect' ([int]$AutoReconnect)
    return Get-LanUserStartupSettings -Adapter $Adapter
}

function Remove-LanUserStartupSettings {
    param([hashtable]$Adapter=(New-LanUserStartupAdapter))
    & $Adapter.RemoveRun
    & $Adapter.RemovePreference
}

function Test-LanStartHidden {
    param([bool]$AutoLaunch,[Parameter(Mandatory)]$Settings)
    return ($AutoLaunch -and [bool]$Settings.StartMinimized)
}

function New-LanSingleInstance {
    param([string]$Name)
    # The name is per Windows account so two accounts never share one window. A caller may pass
    # its own name so a test never collides with a running copy of the application.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $Name='Local\LanFileSharing-UI-'+$sid
    }
    $created=$false
    $mutex=[Threading.Mutex]::new($true,$Name,[ref]$created)
    if (-not $created) {
        $mutex.Dispose()
        try {
            $wake=[Threading.EventWaitHandle]::OpenExisting($Name+'-wake')
            try { [void]$wake.Set() } finally { $wake.Dispose() }
        } catch [Threading.WaitHandleCannotBeOpenedException] { }
        return [pscustomobject]@{IsFirst=$false;Mutex=$null;Wake=$null}
    }
    try {
        $eventCreated=$false
        $wake=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,$Name+'-wake',[ref]$eventCreated)
        return [pscustomobject]@{IsFirst=$true;Mutex=$mutex;Wake=$wake}
    } catch { $mutex.ReleaseMutex(); $mutex.Dispose(); throw }
}

function Close-LanSingleInstance {
    param($Instance)
    if (-not $Instance -or -not $Instance.IsFirst) { return }
    $Instance.Wake.Dispose()
    $Instance.Mutex.ReleaseMutex()
    $Instance.Mutex.Dispose()
}
