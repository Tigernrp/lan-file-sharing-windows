function Get-LanScheduledTask {
    param([string]$TaskName = 'LanFileSharing-HostWorker')
    # This machine's CIM bridge raises a terminating error for a missing task even with
    # -ErrorAction SilentlyContinue, which aborted installs and resets. Return $null instead.
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = 'LanFileSharing-HostWorker' }
    try { return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch { return $null }
}

function Get-LanDefaultInstallRoot {
    param([Parameter(Mandatory)][bool]$Is64BitOs)
    if ($Is64BitOs) { return 'C:\Program Files\LanFileSharing' }
    return 'C:\Program Files (x86)\LanFileSharing'
}

function ConvertTo-LanInstallRoot {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Choose a local drive for the installation.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not [string]::Equals([IO.Path]::GetFileName($full),'LanFileSharing',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The selected install directory must end in LanFileSharing.'
    }
    return $full
}

function New-LanInstallLocationAdapter {
    return @{
        GetDrive = {
            param($root)
            $drive = New-Object IO.DriveInfo($root)
            return [pscustomobject]@{DriveType=[string]$drive.DriveType;DriveFormat=[string]$drive.DriveFormat}
        }
        GetPathInfo = {
            param($path)
            if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
                return [pscustomobject]@{Exists=$false;Reparse=$false;OwnerSid='';UntrustedWrite=$false;UntrustedDelete=$false}
            }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
            $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            $writeMask = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
            $deleteMask = [Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles'
            $untrustedWrite = $false
            $untrustedDelete = $false
            foreach ($ace in @($acl.Access)) {
                if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
                if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                $sid = try { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                    catch { [string]$ace.IdentityReference.Value }
                if ($sid -in @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) { continue }
                if (($ace.FileSystemRights -band $writeMask) -ne 0) { $untrustedWrite = $true }
                if (($ace.FileSystemRights -band $deleteMask) -ne 0) { $untrustedDelete = $true }
            }
            return [pscustomobject]@{
                Exists=$true
                Reparse=(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
                OwnerSid=$owner
                UntrustedWrite=$untrustedWrite
                UntrustedDelete=$untrustedDelete
            }
        }
        CreateProtectedParent = {
            param($path)
            $driveRoot = [IO.Path]::GetPathRoot($path)
            $acl = New-LanInstalledDirectoryAcl -Acl (Get-Acl -LiteralPath $driveRoot -ErrorAction Stop) -Role Code
            [IO.Directory]::CreateDirectory($path,$acl) | Out-Null
        }
        ReadRecord = {
            $value = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\LanFileSharing' -Name InstallRoot -ErrorAction SilentlyContinue
            if ($value) { return [string]$value.InstallRoot }
            return $null
        }
        WriteRecord = {
            param($path)
            New-Item -Path 'HKLM:\SOFTWARE\LanFileSharing' -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\LanFileSharing' -Name InstallRoot -Value $path -PropertyType String -Force -ErrorAction Stop | Out-Null
        }
        DeleteRecord = { Remove-Item -LiteralPath 'HKLM:\SOFTWARE\LanFileSharing' -Force -ErrorAction Stop }
    }
}

function Initialize-LanInstallParent {
    param([Parameter(Mandatory)][string]$Path,[hashtable]$Adapter=(New-LanInstallLocationAdapter))
    $full = ConvertTo-LanInstallRoot -Path $Path
    $parentPath = [IO.Directory]::GetParent($full).FullName
    $existing = & $Adapter.GetPathInfo $parentPath
    if ($existing.Exists) { return }
    if (-not [string]::Equals($full,(Get-LanDefaultInstallRoot -Is64BitOs $false),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Only the requested 32-bit default parent may be created automatically.'
    }
    & $Adapter.CreateProtectedParent $parentPath | Out-Null
    $created = & $Adapter.GetPathInfo $parentPath
    if (-not $created.Exists -or $created.Reparse -or $created.UntrustedWrite -or
        [string]$created.OwnerSid -notin @('S-1-5-18','S-1-5-32-544')) {
        throw 'The requested 32-bit install parent could not be secured.'
    }
}

function Assert-LanSafeInstallRoot {
    param([Parameter(Mandatory)][string]$Path,[hashtable]$Adapter=(New-LanInstallLocationAdapter))
    $full = ConvertTo-LanInstallRoot -Path $Path
    $root = [IO.Path]::GetPathRoot($full)
    $drive = & $Adapter.GetDrive $root
    if (-not $drive -or [string]$drive.DriveType -ne 'Fixed' -or [string]$drive.DriveFormat -ne 'NTFS') {
        throw 'Installation requires a local fixed NTFS drive.'
    }
    $parentPath = [IO.Directory]::GetParent($full).FullName
    $parentInfo = & $Adapter.GetPathInfo $parentPath
    $requestedX86Default = [string]::Equals($full,(Get-LanDefaultInstallRoot -Is64BitOs $false),[StringComparison]::OrdinalIgnoreCase)
    if (-not $parentInfo.Exists -and -not $requestedX86Default) {
        throw 'Choose an existing protected parent directory for the installation.'
    }
    $current = $full
    while ($true) {
        $info = & $Adapter.GetPathInfo $current
        if ($info.Exists) {
            if ($info.Reparse) { throw "An install path contains a reparse point: $current" }
            $owner = [string]$info.OwnerSid
            $trustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
            if ($owner -and $owner -notin @('S-1-5-18','S-1-5-32-544',$trustedInstaller)) {
                throw "An install path is owned by an untrusted account: $current"
            }
            if ([string]::Equals($current,$root,[StringComparison]::OrdinalIgnoreCase)) {
                if ($info.UntrustedDelete) { throw "Untrusted users can delete from the drive root: $current" }
            } elseif ($info.UntrustedWrite) {
                throw "Untrusted users can modify an install path: $current"
            }
        }
        if ([string]::Equals($current,$root,[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Directory]::GetParent($current)
        if (-not $parent) { throw 'Could not verify the install path ancestors.' }
        $current = $parent.FullName
    }
    return $full
}

function Get-LanInstallRecord {
    param([hashtable]$Adapter=(New-LanInstallLocationAdapter))
    $value = & $Adapter.ReadRecord
    if (-not $value) { return $null }
    $path = if ($value -is [string]) { $value } else { [string]$value.InstallRoot }
    return [pscustomobject]@{InstallRoot=(ConvertTo-LanInstallRoot -Path $path)}
}

function Write-LanInstallRecord {
    param([Parameter(Mandatory)][string]$Path,[hashtable]$Adapter=(New-LanInstallLocationAdapter))
    $full = ConvertTo-LanInstallRoot -Path $Path
    $previous = Get-LanInstallRecord -Adapter $Adapter
    if ($previous -and -not [string]::Equals($previous.InstallRoot,$full,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'An installation is already recorded at another location.'
    }
    & $Adapter.WriteRecord $full | Out-Null
}

function Remove-LanInstallRecord {
    param([Parameter(Mandatory)][string]$ExpectedPath,[hashtable]$Adapter=(New-LanInstallLocationAdapter))
    $current = Get-LanInstallRecord -Adapter $Adapter
    if (-not $current) { return }
    $expected = ConvertTo-LanInstallRoot -Path $ExpectedPath
    if (-not [string]::Equals($current.InstallRoot,$expected,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The recorded installation points to another location.'
    }
    & $Adapter.DeleteRecord | Out-Null
}
