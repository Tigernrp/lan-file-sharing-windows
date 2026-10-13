if (-not ('LanSingleFileNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class LanSingleFileNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct FileTime { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)]
    public struct FileInformation {
        public uint Attributes; public FileTime Creation; public FileTime Access; public FileTime Write;
        public uint VolumeSerial; public uint FileSizeHigh; public uint FileSizeLow;
        public uint LinkCount; public uint FileIndexHigh; public uint FileIndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CreateHardLink(string newFile, string existingFile, IntPtr security);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetFileInformationByHandle(IntPtr handle, out FileInformation info);
    public static string GetId(string path) {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete)) {
            FileInformation info;
            if (!GetFileInformationByHandle(stream.SafeFileHandle.DangerousGetHandle(), out info))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return info.VolumeSerial.ToString("X8") + ":" +
                (((ulong)info.FileIndexHigh << 32) | info.FileIndexLow).ToString("X16");
        }
    }
}
'@
}

function Get-LanFileId {
    param([Parameter(Mandatory)][string]$Path)
    return [LanSingleFileNative]::GetId($Path)
}

function Get-LanFileHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Set-LanIsolatedRootAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-LanSingleFileRoot {
    param([Parameter(Mandatory)][string]$SourcePath,
          [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{32}$')][string]$ShareId)
    $source = Get-LanCanonicalPath $SourcePath
    if (-not [IO.File]::Exists($source)) { throw "Selected file does not exist: $source" }
    if (([IO.File]::GetAttributes($source) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'File links cannot be shared as a single file.' }
    $volume = Get-LanVolumeIdentity ([IO.Path]::GetPathRoot($source))
    if ($volume.FileSystem -ne 'NTFS') { throw 'Single-file sharing requires NTFS hard links.' }
    $parent = [IO.Path]::GetDirectoryName($source)
    $container = Join-Path $parent '.LanShareSingleFiles'
    $root = Join-Path $container $ShareId
    if ([IO.Directory]::Exists($root)) { throw "Isolation root already exists: $root" }
    [IO.Directory]::CreateDirectory($container) | Out-Null
    [IO.File]::SetAttributes($container, ([IO.File]::GetAttributes($container) -bor [IO.FileAttributes]::Hidden))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        Set-LanIsolatedRootAcl -Path $root
        $link = Join-Path $root ([IO.Path]::GetFileName($source))
        if (-not [LanSingleFileNative]::CreateHardLink($link, $source, [IntPtr]::Zero)) {
            throw "Hard link creation failed (Win32: $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
        }
        return [pscustomobject]@{
            SourcePath=$source; Root=$root; LinkPath=$link
            FileId=(Get-LanFileId $source); BaselineHash=(Get-LanFileHash $source)
            Status='Ready'
        }
    } catch {
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
        throw
    }
}

function Sync-LanSingleFile {
    param([Parameter(Mandatory)]$Entry)
    if (-not [IO.File]::Exists($Entry.SourcePath)) { return [pscustomobject]@{Status='MissingSource';Detail='The original file is unavailable.'} }
    if (-not [IO.File]::Exists($Entry.LinkPath)) { return [pscustomobject]@{Status='MissingLink';Detail='The shared file is being replaced or removed.'} }
    $sourceId = Get-LanFileId $Entry.SourcePath
    $linkId = Get-LanFileId $Entry.LinkPath
    if ($sourceId -eq $linkId) {
        $Entry.FileId = $sourceId
        $Entry.BaselineHash = Get-LanFileHash $Entry.SourcePath
        $Entry.Status = 'Ready'
        return [pscustomobject]@{Status='InPlace';Detail='The original file was edited directly.'}
    }
    $sourceHash = Get-LanFileHash $Entry.SourcePath
    $linkHash = Get-LanFileHash $Entry.LinkPath
    if ($sourceHash -ne $Entry.BaselineHash -and $linkHash -ne $Entry.BaselineHash) {
        $Entry.Status = 'Conflict'
        return [pscustomobject]@{Status='Conflict';Detail='The original and shared replacement both changed; neither was overwritten.'}
    }
    if ($sourceHash -ne $Entry.BaselineHash) {
        [IO.File]::Delete($Entry.LinkPath)
        if (-not [LanSingleFileNative]::CreateHardLink($Entry.LinkPath,$Entry.SourcePath,[IntPtr]::Zero)) { throw 'Cannot relink the changed original.' }
        $Entry.FileId = Get-LanFileId $Entry.SourcePath
        $Entry.BaselineHash = $sourceHash
        $Entry.Status = 'Ready'
        return [pscustomobject]@{Status='SourceUpdated';Detail='The original changed and the hard link was renewed.'}
    }
    if ($linkHash -ne $Entry.BaselineHash) {
        $staging = Join-Path ([IO.Path]::GetDirectoryName($Entry.SourcePath)) ('.lfs-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $backup = $staging + '.bak'
        try {
            [IO.File]::Copy($Entry.LinkPath, $staging)
            if ((Get-LanFileHash $Entry.SourcePath) -ne $Entry.BaselineHash -or
                (Get-LanFileId $Entry.SourcePath) -ne $sourceId) {
                $Entry.Status = 'Conflict'
                return [pscustomobject]@{Status='Conflict';Detail='The original changed during reconciliation.'}
            }
            [IO.File]::Replace($staging, $Entry.SourcePath, $backup)
            [IO.File]::Delete($backup)
        } finally {
            if ([IO.File]::Exists($staging)) { [IO.File]::Delete($staging) }
        }
    }
    [IO.File]::Delete($Entry.LinkPath)
    if (-not [LanSingleFileNative]::CreateHardLink($Entry.LinkPath,$Entry.SourcePath,[IntPtr]::Zero)) { throw 'Cannot relink the reconciled original.' }
    $Entry.FileId = Get-LanFileId $Entry.SourcePath
    $Entry.BaselineHash = Get-LanFileHash $Entry.SourcePath
    $Entry.Status = 'Ready'
    return [pscustomobject]@{Status='Reconciled';Detail='Replacement save copied back to the original path.'}
}

function Remove-LanSingleFileRoot {
    param([Parameter(Mandatory)]$Entry)
    $source = Get-LanCanonicalPath $Entry.SourcePath
    $expected = Join-Path (Join-Path ([IO.Path]::GetDirectoryName($source)) '.LanShareSingleFiles') ([IO.Path]::GetFileName($Entry.Root))
    if (-not [string]::Equals($expected,$Entry.Root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Isolation path mismatch; cleanup refused.' }
    if (-not [IO.Directory]::Exists($Entry.Root)) { return }
    $children = @([IO.Directory]::GetFileSystemEntries($Entry.Root))
    if ($children.Count -gt 1 -or ($children.Count -eq 1 -and $children[0] -ne $Entry.LinkPath)) { throw 'Unexpected files remain in the isolated share.' }
    if ([IO.File]::Exists($Entry.LinkPath)) {
        if ([IO.File]::Exists($source) -and (Get-LanFileId $Entry.LinkPath) -ne (Get-LanFileId $source) -and
            (Get-LanFileHash $Entry.LinkPath) -ne $Entry.BaselineHash) {
            throw 'Unsynchronized shared replacement must be preserved for recovery.'
        }
        [IO.File]::Delete($Entry.LinkPath)
    }
    [IO.Directory]::Delete($Entry.Root)
    $container = [IO.Path]::GetDirectoryName($Entry.Root)
    if (@([IO.Directory]::GetFileSystemEntries($container)).Count -eq 0) { [IO.Directory]::Delete($container) }
}

function Start-LanSingleFileMonitor {
    param([Parameter(Mandatory)]$Entry, [scriptblock]$OnStatus = {})
    $watcher = New-Object IO.FileSystemWatcher($Entry.Root, [IO.Path]::GetFileName($Entry.LinkPath))
    $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'
    $watcher.EnableRaisingEvents = $true
    return $watcher
}
