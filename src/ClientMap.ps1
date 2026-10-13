if (-not ('LanCredentialNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LanCredentialNative {
    // Pointer fields use native alignment on both 32-bit and 64-bit Windows. Strings and the secret
    // blob are allocated explicitly, and the caller wipes the blob before freeing it.
    [StructLayout(LayoutKind.Sequential)]
    public struct Credential {
        public uint Flags, Type;
        public IntPtr TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes, TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", SetLastError=true, EntryPoint="CredWriteW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool Write(IntPtr credential, uint flags);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CredDeleteW")]
    public static extern bool Delete(string targetName, int type, int flags);
}
'@
}

if (-not ('LanNetApiNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LanNetApiNative {
    // NetUseDel is the LAN Manager call behind "net use /delete". WNetCancelConnection2 cannot remove a
    // connection that has no drive letter: it answers success and leaves the session open, which is why a
    // share reached as \\HOST\Name (without mapping a drive) kept its credentials and every later attempt
    // failed with 1219 no matter how many times the cleanup reported that it had closed the connection.
    [DllImport("netapi32.dll", CharSet=CharSet.Unicode)]
    public static extern int NetUseDel(string uncName, string userName, int forceLevel);
    // NetSessionDel is the server-side equivalent: closing the session from the sharing machine's own
    // session table, which removes what the client-side calls could not.
    [DllImport("netapi32.dll", CharSet=CharSet.Unicode)]
    public static extern int NetSessionDel(string serverName, string clientName, string userName);
    // NetShareEnum is how "net view \\HOST" asks a machine what it is sharing. It runs over the SMB session
    // that is already open, so it needs no extra service on the other machine — which CIM and WinRM do, and
    // both are commonly switched off. Reading the list is what turns "share name not found" into an answer the
    // user can act on.
    [StructLayout(LayoutKind.Sequential)]
    public struct SHARE_INFO_1 {
        [MarshalAs(UnmanagedType.LPWStr)] public string shi1_netname;
        public uint shi1_type;
        [MarshalAs(UnmanagedType.LPWStr)] public string shi1_remark;
    }
    [DllImport("netapi32.dll", CharSet=CharSet.Unicode)]
    public static extern int NetShareEnum(string servername, int level, out IntPtr bufptr,
        uint prefmaxlen, out uint entriesread, out uint totalentries, ref uint resume_handle);
    [DllImport("netapi32.dll")]
    public static extern int NetApiBufferFree(IntPtr buffer);
}
'@
}

if (-not ('LanWNetNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LanWNetNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct NetResource {
        public int Scope, Type, DisplayType, Usage;
        [MarshalAs(UnmanagedType.LPWStr)] public string LocalName;
        [MarshalAs(UnmanagedType.LPWStr)] public string RemoteName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        [MarshalAs(UnmanagedType.LPWStr)] public string Provider;
    }
    [DllImport("mpr.dll", CharSet=CharSet.Unicode, EntryPoint="WNetAddConnection2W")]
    public static extern int Add(ref NetResource resource, string password, string userName, int flags);
    [DllImport("mpr.dll", CharSet=CharSet.Unicode, EntryPoint="WNetCancelConnection2W")]
    public static extern int Cancel(string name, int flags, bool force);
    [DllImport("mpr.dll", CharSet=CharSet.Unicode, EntryPoint="WNetGetConnectionW")]
    public static extern int GetConnection(string localName, StringBuilder remoteName, ref int length);
    [DllImport("mpr.dll", CharSet=CharSet.Unicode, EntryPoint="WNetGetUserW")]
    public static extern int GetUser(string resourceName, StringBuilder userName, ref int length);
}
'@
}

if (-not ('LanBlankPasswordNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LanBlankPasswordNative {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="LogonUserW")]
    public static extern bool LogonUser(string userName, string domain, string password, int logonType, int provider, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr token);
}
'@
}

. (Join-Path $PSScriptRoot 'Online.ps1')

function Assert-LanUnc {
    param([Parameter(Mandatory)][string]$Path)
    $value = $Path.Trim().TrimEnd('\')
    if ($value -notmatch '^\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*$') {
        throw 'Enter a UNC path such as \\computer\share.'
    }
    $parts = $value.Substring(2).Split('\')
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..' -or $part.EndsWith(' ') -or $part.EndsWith('.')) { throw 'UNC traversal and trailing spaces or dots are not allowed.' }
    }
    return $value
}

function Get-LanUncRoot {
    param([Parameter(Mandatory)][string]$Path)
    $parts = (Assert-LanUnc $Path).Substring(2).Split('\')
    return '\\' + $parts[0] + '\' + $parts[1]
}

function Get-LanFreeDriveLetter {
    # Lowest free letter first, not highest.
    #
    # Leaving Z: until last was not enough. On this machine every letter from E to Y maps the share
    # correctly while Z: fails with error 1202 even though Windows reports it as free, so a preference for
    # the highest letter walked straight into the one letter that does not work. Choosing from the low end
    # avoids that whole class of oddity, and E: is where a user expects the first mapped drive anyway.
    param([string[]]$Occupied = @())
    $used = @($Occupied | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() })
    for ($code = [int][char]'E'; $code -le [int][char]'Y'; $code++) {
        $letter = [string][char]$code
        if ($letter -notin $used) { return $letter }
    }
    if ('Z' -notin $used) { return 'Z' }
    throw 'No free drive letter from E: through Z:.'
}

function Get-LanFreeDriveLetterList {
    # Every candidate in the order they should be tried. The caller walks this list so a letter the
    # redirector refuses is skipped, instead of ending the attempt with an unexplained error.
    param([string[]]$Occupied = @())
    $used = @($Occupied | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() })
    return @(for ($code = [int][char]'E'; $code -le [int][char]'Z'; $code++) {
        $letter = [string][char]$code
        if ($letter -notin $used) { $letter }
    })
}

function Get-LanClientStatePath {
    param([hashtable]$Adapter)
    if ($Adapter.StatePath) { return [string]$Adapter.StatePath }
    return Join-Path $env:LOCALAPPDATA 'LanFileSharing\mappings.json'
}

function Get-LanClientGuestStatePathForAdapter {
    param([hashtable]$Adapter)
    if ($Adapter.GuestStatePath) { return [string]$Adapter.GuestStatePath }
    return Get-LanClientGuestStatePath
}

function Assert-LanClientSession {
    param([string]$Root, [string]$ConnectionName, [string]$AuthMode, [hashtable]$Adapter)
    if (-not $Adapter.GetSession) { throw 'Cannot verify the SMB session identity.' }
    if (-not $ConnectionName) { $ConnectionName = $Root }
    $session = & $Adapter.GetSession $ConnectionName
    if (-not $session) { throw 'SMB connection succeeded but its identity could not be verified.' }
    $guest = [string]$session -match '(?i)(\\|^)guest$|anonymous'
    if ($AuthMode -eq 'Guest' -and -not $guest) { throw 'The connection did not authenticate as Guest.' }
    if ($AuthMode -eq 'WindowsCurrent' -and $guest) { throw 'Windows unexpectedly fell back to Guest.' }
}

function Assert-LanClientPathReadable {
    param([Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)][string]$ConnectionName,
          [Parameter(Mandatory)][hashtable]$Adapter)
    if (-not $Adapter.ProbeAccess) { return }
    try { & $Adapter.ProbeAccess $Path | Out-Null }
    catch {
        $base = $_.Exception.GetBaseException()
        $detail = $base.Message
        $session = try { [string](& $Adapter.GetSession $ConnectionName) } catch { '' }
        if (-not $session) { $session = 'unknown' }
        if (($base.HResult -band 0xffff) -in @(53,67,1231)) {
            throw "เชื่อมต่อ SMB เป็น '$session' แล้ว แต่ไม่พบแชร์หรือแชร์ไม่พร้อมบนเครื่องผู้แชร์: $ConnectionName ตรวจสอบสถานะ Running และ Host Worker. $detail"
        }
        throw "SMB connected as '$session', but the shared path cannot be read. Check share and NTFS permissions on the host. $detail"
    }
}

function Get-LanWNetUser {
    param([Parameter(Mandatory)][string]$Name, [scriptblock]$Query)
    $buffer = New-Object Text.StringBuilder 1024
    $length = 1024
    $code = if ($Query) { & $Query $Name $buffer ([ref]$length) }
            else { [LanWNetNative]::GetUser($Name, $buffer, [ref]$length) }
    if ([int]$code -ne 0) { return $null }
    return $buffer.ToString()
}

function Get-LanRemoteShareNames {
    # The shares a computer is offering right now, for when a name the user typed does not exist.
    #
    # "SMB error 67: Share name not found" says the machine answered but has no such share — and says nothing
    # about what it does have, so the user is left comparing two screens. Asking the machine for its list turns
    # that into an answer: a wrong name, a share that was stopped, and a Server service that is not running all
    # look different in the reply. The call runs over SMB, so it needs nothing switched on at the other end.
    param([Parameter(Mandatory)][string]$ComputerName)
    $names = @()
    $peer = $ComputerName.TrimStart('\')
    if ($peer -notmatch '^[A-Za-z0-9._-]{1,63}$') { return $names }
    if (-not ('LanNetApiNative' -as [type])) { return $names }
    $buffer = [IntPtr]::Zero
    $read = [uint32]0
    $total = [uint32]0
    $resume = [uint32]0
    try {
        $code = [LanNetApiNative]::NetShareEnum("\\$peer", 1, [ref]$buffer, [uint32]::MaxValue, [ref]$read, [ref]$total, [ref]$resume)
        # 234 is ERROR_MORE_DATA: the list was longer than one buffer, and what arrived is still usable.
        if ($code -ne 0 -and $code -ne 234) { return $names }
        $size = [Runtime.InteropServices.Marshal]::SizeOf([type][LanNetApiNative+SHARE_INFO_1])
        $cursor = $buffer
        for ($index = 0; $index -lt [int]$read; $index++) {
            $info = [Runtime.InteropServices.Marshal]::PtrToStructure($cursor, [type][LanNetApiNative+SHARE_INFO_1])
            $name = [string]$info.shi1_netname
            # Type 0 is a disk share. The administrative ones end in $ and are not what the user is looking for.
            if ($name -and $info.shi1_type -eq 0 -and $name -notmatch '\$$') { $names += $name }
            $cursor = [IntPtr]::Add($cursor, $size)
        }
    } catch { } finally {
        if ($buffer -ne [IntPtr]::Zero) { try { [void][LanNetApiNative]::NetApiBufferFree($buffer) } catch { } }
    }
    return $names
}
function Throw-LanWNetError {
    param([Int]$Code,[string]$Hint)
    $description = switch ($Code) {
        5 { 'Access denied.' }
        53 { 'Computer or network path not found.' }
        67 { 'Share name not found.' }
        86 { 'Incorrect credentials.' }
        1219 { 'Windows already has a connection to this computer with different credentials.' }
        1202 { 'Windows refused this drive letter or network name. Try Map Drive again; the program will pick another drive letter.' }
        85 { 'That drive letter is already in use on this computer.' }
        1272 { 'Windows blocked insecure Guest fallback.' }
        2401 { 'Files are open on this mapped drive.' }
        default { 'Windows networking returned an error.' }
    }
    throw "SMB error $Code`: $description$Hint"
}

function Get-LanClientCredentialPath {
    param([hashtable]$Adapter)
    if ($Adapter.CredentialPath) { return [string]$Adapter.CredentialPath }
    if ($Adapter.StatePath) {
        $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$Adapter.StatePath))
        return Join-Path $directory 'credentials.json'
    }
    return Join-Path $env:LOCALAPPDATA 'LanFileSharing\credentials.json'
}

function Read-LanClientCredentials {
    # Credentials the user chose to remember, keyed by host name.
    #
    # This is what makes the app work between machines whose Windows account names differ: the
    # sharing machine creates its own account for the share, and the user types that name and
    # password once here. Nothing then depends on the two machines happening to have matching
    # accounts, which is the only reason the WindowsCurrent path can ever work.
    param([Parameter(Mandatory)][hashtable]$Adapter)
    $path = Get-LanClientCredentialPath $Adapter
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $stored = Read-LanClientCredentialCiphertexts -Path $path
    $result = @{}
    foreach ($key in $stored.Keys) { $result[$key] = Unprotect-LanSecret -CipherText ([string]$stored[$key]) }
    return $result
}

function Read-LanClientCredentialCiphertexts {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{}
    if (-not [IO.File]::Exists($Path)) {
        if ([IO.Directory]::Exists($Path)) { throw 'The encrypted credential store path is a directory.' }
        return $result
    }
    try {
        $stored = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop
        if ($null -eq $stored -or $stored -isnot [pscustomobject]) { throw 'Invalid credential store.' }
        foreach ($property in $stored.PSObject.Properties) {
            # Verify every existing record before any replacement; preserve its original ciphertext.
            Unprotect-LanSecret -CipherText ([string]$property.Value) | Out-Null
            $result[$property.Name] = [string]$property.Value
        }
    } catch { throw 'The encrypted credential store cannot be read. Existing saved credentials were left unchanged.' }
    return $result
}

function Write-LanClientCredential {
    param([Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$HostName,
          [Parameter(Mandatory)][string]$UserName,
          [Parameter(Mandatory)][string]$Password)
    $path = [IO.Path]::GetFullPath((Get-LanClientCredentialPath $Adapter))
    $directory = Split-Path -Parent $path
    if ($directory -and -not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $payload = Read-LanClientCredentialCiphertexts -Path $path
    $record=@{UserName=$UserName;Password=$Password}
    if($Adapter.VerifiedOnlineTarget){
        $record.Transport='NetBird'
        $record.OnlinePeerIdentity=$Adapter.VerifiedOnlineTarget.OnlinePeerIdentity
        $record.OnlineBinding=$Adapter.VerifiedOnlineTarget.OnlineBinding
    }
    $payload[$HostName] = Protect-LanSecret -Text ($record | ConvertTo-Json -Depth 6 -Compress)
    $json = $payload | ConvertTo-Json -Depth 3
    $temp = Join-Path $directory ('.lancreds-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $temp + '.bak'
    try {
        [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,$backup); [IO.File]::Delete($backup) }
        else { [IO.File]::Move($temp,$path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    return $path
}

function Get-LanRememberedCredential {
    # Returns the saved {UserName;Password} for a host, or $null. The record holds a JSON object so
    # the account name travels with the password.
    param([Parameter(Mandatory)][string]$HostName,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $all = Read-LanClientCredentials -Adapter $Adapter
    if (-not $all.ContainsKey($HostName)) { return $null }
    try {
        $record = ([string]$all[$HostName]) | ConvertFrom-Json
        if (-not $record.UserName -or -not $record.Password) { return $null }
    } catch { return $null }
    # Keep the identity pin with the encrypted secret even after the last drive is forgotten.
    if($record.Transport -eq 'NetBird'){
        $entry=@{Unc=('\\'+$HostName+'\Credential');Transport='NetBird';OnlinePeerIdentity=$record.OnlinePeerIdentity;OnlineBinding=$record.OnlineBinding}
        $guard=Test-LanClientOnlineTarget -Entry $entry -Adapter $Adapter
        if(-not $guard.Ready){throw $guard.Reason}
    }elseif($Adapter.VerifiedOnlineTarget){return $null}
    return [pscustomobject]@{ UserName=[string]$record.UserName; Password=[string]$record.Password }
}

function Get-LanNetworkDriveLetters {
    # Only the drive letters that are actually network mappings.
    #
    # DisplayRoot is empty for a local volume and holds the UNC for a mapping, which is what tells the two
    # apart. An earlier version listed every letter and then cancelled C: and F: as well: harmless for a
    # fixed disk, but this program has no business touching a local volume.
    try {
        return @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayRoot -and $_.Name.Length -eq 1 -and $_.Name -match '^[A-Za-z]$' } |
            ForEach-Object { $_.Name })
    } catch { return @() }
}

function Remove-LanConnectionEntry {
    # Removes a connection entry by remote name, including one that has no drive letter.
    #
    # This is the call that finally clears a share reached as \\HOST\Name without mapping a drive.
    # WNetCancelConnection2 reports success and leaves that session open, and NetUseDel rejects the UNC form
    # with error 123 (ERROR_INVALID_NAME) because it expects a local device name. Remove-SmbMapping works
    # from the remote path, which is exactly the case that kept a stale credential alive and made every later
    # attempt fail with 1219.
    param([Parameter(Mandatory)][string]$Target)
    $removed = $false
    if (Get-Command Remove-SmbMapping -ErrorAction SilentlyContinue) {
        try {
            Remove-SmbMapping -RemotePath $Target -Force -ErrorAction Stop
            $removed = $true
        } catch { }
    }
    # The Win32 call stays as a fallback for a system without the SMB cmdlets; it is harmless when the entry
    # is already gone.
    if (-not $removed -and ('LanNetApiNative' -as [type])) {
        try {
            $code = [LanNetApiNative]::NetUseDel($Target, $null, 3)
            if ($code -eq 0 -or $code -eq 2250) { $removed = $true }
        } catch { }
    }
    return $removed
}

function Get-LanSmbMappings {
    # Every mapping, including the ones without a drive letter, read from the SMB client's own view.
    param()
    $items = @()
    if (-not (Get-Command Get-SmbMapping -ErrorAction SilentlyContinue)) { return $items }
    try {
        foreach ($mapping in @(Get-SmbMapping -ErrorAction SilentlyContinue)) {
            $items += [pscustomobject]@{
                LocalPath  = [string]$mapping.LocalPath
                RemotePath = [string]$mapping.RemotePath
                Status     = [string]$mapping.Status
            }
        }
    } catch { }
    return $items
}

function Remove-LanServerSession {
    # Closes sessions on the sharing machine itself, which is the last resort when the client side will not
    # let the connection go. Only meaningful against a machine this account administers, so a failure is
    # expected and ignored everywhere else.
    param([string]$ServerName)
    if (-not ('LanNetApiNative' -as [type])) { return 0 }
    $closed = 0
    try {
        $target = if ($ServerName) { "\\$ServerName" } else { $null }
        $code = [LanNetApiNative]::NetSessionDel($target, $null, $null)
        if ($code -eq 0) { $closed = 1 }
    } catch { }
    return $closed
}

function Clear-LanHostConnections {
    # Closes everything this user holds against one host, so a share with different credentials can be
    # reached. Windows keeps a single credential per server and refuses a second session with error 1219,
    # never replacing the first one by itself.
    #
    # Cancelling only "\\HOST" is not enough, and that is why the repair could report success while the next
    # attempt still failed with 1219: Windows can hold the connection at the share level, and a name Windows
    # does not hold answers 2250, which this program treats as "nothing there". Every name that can carry the
    # session is therefore cancelled — the bare host, the share the caller is reaching for, every share this
    # app has recorded for that host, and every mapped drive letter — over several passes, because closing a
    # drive-letter connection can leave the host session behind for a moment.
    param([Parameter(Mandatory)][string]$HostName,
          [hashtable]$Adapter,
          [scriptblock]$Log,
          [string]$Share)
    $closed = New-Object System.Collections.Generic.List[string]
    $stillHeld = New-Object System.Collections.Generic.List[string]
    $write = { param($text)
        try {
            if ($Log) { & $Log $text }
            elseif (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog $text }
        } catch { }
    }
    if (-not $Adapter -or -not $Adapter.Disconnect) { return @() }
    $hostRoot = "\\$HostName"
    $targets = New-Object System.Collections.Generic.List[string]
    # The live drive list goes through the adapter when it can supply one, so a caller can work against its own
    # set of drives instead of whatever this machine happens to have mapped.
    $live = if ($Adapter.GetNetworkDriveLetters) { @(& $Adapter.GetNetworkDriveLetters) }
            else { @(Get-LanNetworkDriveLetters) }
    foreach ($letter in $live) { $targets.Add([string]$letter) }
    if ($Share) { $targets.Add("$hostRoot\$Share") }
    foreach ($entry in @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter))) {
        $unc = [string]$entry.Unc
        if ($unc -and $unc -like "$hostRoot\*" -and $unc -notin $targets) { $targets.Add($unc) }
    }
    $targets.Add($hostRoot)
    # Also the connected sessions the redirector already knows about for this host, so a name reached by
    # another route (an IP address, or a share this app never recorded) is included.
    foreach ($name in @(Get-LanConnectedRemoteNames -HostName $HostName)) {
        if ($name -and $name -notin $targets) { $targets.Add($name) }
    }
    $wrote = @{}
    foreach ($pass in 1..2) {
        foreach ($target in $targets) {
            try {
                # Two calls, because they remove different things. WNetCancelConnection2 clears a drive
                # letter; NetUseDel clears the connection entry itself, including one that has no drive
                # letter at all. Only using the first is what left the session open while the log said it had
                # been closed.
                $result = Disconnect-LanQuietly -Adapter $Adapter -Target $target
                if ($target -like '\\*') { [void](Remove-LanConnectionEntry -Target $target) }
                if ([int]$result -eq 0 -and -not $wrote.ContainsKey($target)) {
                    $closed.Add($target)
                    $wrote[$target] = $true
                    & $write "ปิดการเชื่อมต่อเดิมไปที่ $HostName แล้ว: $target"
                }
            } catch { }
        }
    }
    # Verified, not assumed: answering 0 for a name Windows does not hold proves nothing, so the session is
    # read back. What remains is reported instead of being presented as a successful cleanup.
    foreach ($target in $targets) {
        try {
            if (Test-LanConnectionHeld -Adapter $Adapter -Target $target) { $stillHeld.Add($target) }
        } catch { }
    }
    if ($stillHeld.Count -gt 0) {
        & $write "ยังปิดการเชื่อมต่อไม่หมด: $(@($stillHeld) -join ', ') — Windows ยังถือ session อยู่"
    }
    return @($closed)
}

function Get-LanMappingState {
    # Whether a mapped drive still reaches its share: 'Alive', 'Dead' or 'Unknown'.
    #
    # Three states exist because deleting a working drive is far worse than leaving a dead one. An earlier
    # version answered true/false, and an ordinary failed read — a redirector that had not finished
    # reconnecting, a share list that could not be read — removed a drive that had been mapped successfully a
    # minute earlier. Only a definite answer may delete anything; everything else is 'Unknown' and is kept.
    #
    # Stopping a share on the sharing machine does not remove the drive on the client: Windows keeps the
    # mapping and Explorer keeps listing it under "Network locations" until someone disconnects it by hand.
    # Removing that is the point, and it needs proof.
    param([Parameter(Mandatory)][string]$Letter,
          [string]$ExpectedUnc,
          [hashtable]$Adapter)
    $chosen = $Letter.TrimEnd(':').ToUpperInvariant()
    $status = $null
    foreach ($mapping in @(Get-LanSmbMappings)) {
        if ([string]$mapping.LocalPath -match '^[A-Za-z]:$' -and
            $mapping.LocalPath.TrimEnd(':').ToUpperInvariant() -eq $chosen) { $status = [string]$mapping.Status }
    }
    # No mapping entry at all: Windows does not hold this drive, so there is nothing to keep.
    if ($null -eq $status) { return 'Dead' }
    $root = "${chosen}:\"
    $reachable = $false
    try { $reachable = [bool](Test-Path -LiteralPath $root) } catch { $reachable = $false }
    if (-not $reachable) {
        # One failed read is not evidence. Windows reconnects a persistent mapping in the background, so the
        # drive is given a moment and asked again before anything else is decided.
        Start-Sleep -Milliseconds 700
        try { $reachable = [bool](Test-Path -LiteralPath $root) } catch { $reachable = $false }
    }
    if ($reachable) {
        if ($ExpectedUnc -and $Adapter -and $Adapter.GetMapping) {
            $mapped = [string](& $Adapter.GetMapping $chosen)
            # A drive pointing somewhere else is not this app's business to judge.
            if ($mapped -and $mapped -ine $ExpectedUnc) { return 'Alive' }
        }
        return 'Alive'
    }
    # Windows itself reports the connection as broken: that is a definite answer and needs no server call.
    if ($status -and $status -ine 'OK') { return 'Dead' }
    # Status still claims OK while the drive cannot be read. Only a server that confirms the share is absent
    # turns that into 'Dead'; anything less certain stays 'Unknown'.
    if ($ExpectedUnc -and $ExpectedUnc -match '^\\\\([^\\]+)\\(.+)$') {
        if (Test-LanShareAbsent -HostName $Matches[1] -Share $Matches[2]) { return 'Dead' }
    }
    return 'Unknown'
}

function Test-LanShareAbsent {
    # Whether the sharing machine can be asked and answers that this share no longer exists.
    #
    # Only a positive answer counts. The share is listed through the SMB server component, which works on the
    # machine itself and over a session, and does not depend on WinRM — an earlier CIM-based check failed on
    # every remote machine with "The client cannot connect to the destination", so it proved nothing and its
    # result must never be a reason to delete anything.
    param([Parameter(Mandatory)][string]$HostName,
          [Parameter(Mandatory)][string]$Share)
    if (-not (Test-LanHostReachable -HostName $HostName)) { return $false }
    $session = $null
    try {
        # A local call needs no session and is always available to an administrator.
        if ($HostName -ieq $env:COMPUTERNAME -or $HostName -ieq 'localhost' -or $HostName -eq '127.0.0.1') {
            $names = @(Get-SmbShare -ErrorAction Stop | ForEach-Object { [string]$_.Name })
            return ($names.Count -gt 0 -and $Share -notin $names)
        }
        $session = New-CimSession -ComputerName $HostName -ErrorAction Stop
        $names = @(Get-SmbShare -CimSession $session -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        return ($names.Count -gt 0 -and $Share -notin $names)
    } catch {
        # The machine answered a ping but its share list could not be read. That is not proof.
        return $false
    } finally {
        if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
    }
}
function Set-LanMappingWatch {
    # Turns the automatic connection check on or off for one saved drive.
    #
    # The owner asked for this: the program should keep trying to connect until it succeeds, and when a drive
    # is one they no longer want watched, they should be able to stop it themselves rather than having the
    # program decide. The flag lives in the mapping record, so it survives a restart, and the drive itself is
    # left alone — stopping the check never disconnects or deletes anything.
    param([string]$Letter,
          [string]$Unc,
          [Parameter(Mandatory)][bool]$Watching,
          [hashtable]$Adapter)
    $chosen = if ($Letter) { $Letter.TrimEnd(':').ToUpperInvariant() } else { '' }
    if (-not $chosen -and -not $Unc) { throw 'Choose a saved drive or UNC path.' }
    $full = if ($Unc) { Assert-LanUnc $Unc } else { '' }
    $statePath = Get-LanClientStatePath $Adapter
    $entries = @(Read-LanClientMappings -Path $statePath)
    $changed = $false
    foreach ($entry in $entries) {
        if ($chosen) { if ([string]$entry.Letter -ne $chosen) { continue } }
        elseif ($entry.Letter -or $entry.ConnectionKind -ne 'Unc' -or [string]$entry.Path -ine $full) { continue }
        $entry | Add-Member -NotePropertyName Watching -NotePropertyValue $Watching -Force
        $changed = $true
    }
    if ($changed) { Write-LanClientMappings -Path $statePath -Mappings $entries }
    return $changed
}

function Test-LanMappingWatched {
    # Whether the automatic connection check should work on this drive. A record without the flag — one saved
    # by an older build — is watched, so upgrading does not silently stop watching existing drives.
    param($Entry)
    if (-not $Entry) { return $false }
    $property = $Entry.PSObject.Properties['Watching']
    if (-not $property -or $null -eq $property.Value) { return $true }
    return [bool]$property.Value
}

function Test-LanSavedConnectionReadable {
    param([Parameter(Mandatory)]$Entry,[Parameter(Mandatory)][hashtable]$Adapter)
    try {
        if ($Entry.Letter) {
            if (-not $Adapter.GetMapping -or [string](& $Adapter.GetMapping ([string]$Entry.Letter)) -ine [string]$Entry.Unc) { return $false }
            $path = [string]$Entry.Letter + ':\'
        } else { $path = if ($Entry.Path) { [string]$Entry.Path } else { [string]$Entry.Unc } }
        if ($Adapter.ProbeAccess) { & $Adapter.ProbeAccess $path | Out-Null; return $true }
        return [bool](Test-Path -LiteralPath $path)
    } catch { return $false }
}

function Invoke-LanSavedConnection {
    param([Parameter(Mandatory)]$Entry,[Parameter(Mandatory)][hashtable]$Adapter)
    $unc = Get-LanUncRoot ([string]$Entry.Unc)
    if (-not $Entry.Letter -and $Entry.ConnectionKind -ne 'Unc') { return 'Waiting' }
    # Check the peer identity before inspecting or releasing any secret.
    if ($Entry.Transport -eq 'NetBird' -and -not (Test-LanClientOnlineTarget -Entry $Entry -Adapter $Adapter).Ready) { return 'Waiting' }
    if ($Entry.Letter -and (Test-LanSavedConnectionReadable -Entry $Entry -Adapter $Adapter)) { return 'AlreadyConnected' }
    $runtime = @{}
    foreach ($key in $Adapter.Keys) { $runtime[$key] = $Adapter[$key] }
    $runtime.VerifiedOnlineTarget = if ($Entry.Transport -eq 'NetBird') { $Entry } else { $null }
    $recorded = [string]$Entry.WindowsAccount
    $server = $unc.Substring(2).Split('\')[0]
    # Windows holds one account per server. The same encrypted host record is used for every profile.
    $remembered = if ($runtime.GetRememberedCredential) { & $runtime.GetRememberedCredential $server $runtime }
                  else { Get-LanRememberedCredential -HostName $server -Adapter $runtime }
    if ($remembered -and $Entry.AuthMode -eq 'Protected') { $recorded = [string]$remembered.UserName }
    $credentials = Resolve-LanClientCredentials -Root $unc -AuthMode ([string]$Entry.AuthMode) -WindowsAccount $recorded -Adapter $runtime
    # An unattended reconnect must never open Windows' credential dialog.
    if ($Entry.AuthMode -eq 'Protected' -and (-not $credentials -or -not $credentials.Password)) { return 'Waiting' }
    $user = if ($credentials) { [string]$credentials.UserName } else { $null }
    $password = if ($credentials) { [string]$credentials.Password } else { $null }
    $letter = if ($Entry.Letter) { [string]$Entry.Letter } else { $null }
    $persistent = [bool]($Entry.Persistent -and $Entry.Transport -ne 'NetBird' -and $letter)
    $result = [int](& $Adapter.Connect $unc $letter $persistent $false $user $password)
    if($result -eq 85 -and $letter -and $Adapter.GetMapping){
        $held=[string](& $Adapter.GetMapping $letter)
        # The journal alone does not own a native drive letter. Reclaim only the same remote mapping,
        # without forcing open handles or clearing other working sessions on this server.
        if($held -ieq $unc){
            $closed=Disconnect-LanQuietly -Adapter $Adapter -Target $letter -Persistent $false -Force $false
            if([int]$closed -eq 0){$result=[int](& $Adapter.Connect $unc $letter $persistent $false $user $password)}
        }
    }
    if ($result -eq 1219) {
        $session = if ($Adapter.GetSession) { [string](& $Adapter.GetSession $unc) } else { '' }
        $same = [bool]($user -and $session -ieq $user)
        if (-not $user -and $Entry.AuthMode -eq 'WindowsCurrent') { $same = Test-LanCurrentSession -Root $unc -Adapter $runtime }
        if (-not $same) { return 'Waiting' }
        if (-not $letter) { $result = 0 }
        elseif (Test-LanSavedConnectionReadable -Entry $Entry -Adapter $Adapter) { $result = 0 }
        else {
            # Reuse the established server session to assign the missing letter. Never clear a working
            # session simply because WNet rejected another credential-bearing connection with 1219.
            $result = [int](& $Adapter.Connect $unc $letter $persistent $false $null $null)
        }
    }
    if ($result -ne 0 -or -not (Test-LanSavedConnectionReadable -Entry $Entry -Adapter $Adapter)) { return 'Waiting' }
    if ($Adapter.GetSession) {
        $name = if ($letter) { $letter + ':' } else { $unc }
        Assert-LanClientSession -Root $unc -ConnectionName $name -AuthMode ([string]$Entry.AuthMode) -Adapter $runtime
    }
    return 'Connected'
}

function Repair-LanMonitoredMappings {
    # Watched drive and UNC profiles survive offline periods and are retried without UI prompts.
    param([hashtable]$Adapter,[scriptblock]$Log)
    $connected = New-Object Collections.Generic.List[string]
    $waiting = New-Object Collections.Generic.List[string]
    if (-not $Adapter) { return [pscustomobject]@{ Connected=@(); Waiting=@() } }
    foreach ($entry in @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter))) {
        if (-not $entry.Unc -or (-not $entry.Letter -and $entry.ConnectionKind -ne 'Unc') -or -not (Test-LanMappingWatched $entry)) { continue }
        $label = if ($entry.Letter) { [string]$entry.Letter } elseif ($entry.Path) { [string]$entry.Path } else { [string]$entry.Unc }
        try { $status = Invoke-LanSavedConnection -Entry $entry -Adapter $Adapter }
        catch { $status = 'Waiting' }
        if ($status -eq 'AlreadyConnected') { continue }
        if ($status -eq 'Connected') { $connected.Add($label) }
        else { $waiting.Add($label) }
        try {
            $message = if ($status -eq 'Connected') { "Connected automatically: $label" } else { "Waiting for $label; will retry." }
            if ($Log) { & $Log $message }
            elseif (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog $message }
        } catch { }
    }
    return [pscustomobject]@{ Connected=@($connected); Waiting=@($waiting) }
}

function Remove-LanStaleMappings {
    # Kept for the callers that still ask, and deliberately does nothing.
    #
    # It used to delete the drives whose share could not be reached, and that is exactly what the owner asked
    # to stop: one machine not ready, neither ready, the network not ready, a different SSID or VLAN on each
    # side — every one of those made the app tell the user "the share was stopped" and take the drive away,
    # when the share was fine and simply not reachable yet. The goal is to keep connecting until it works, so
    # nothing is removed on the strength of an unreachable share, and a drive the owner no longer wants
    # watched is taken off automatic checking with the button provided for that.
    #
    # A drive whose share really is gone stays in the list and keeps being retried. That costs one failed
    # connection per pass, it is what "keep trying until it works" means, and it is how the drive comes back
    # on its own the moment the share is created again.
    param([hashtable]$Adapter,
          [scriptblock]$Log)
    return @()
}

function Get-LanConnectedRemoteNames {
    # The remote names Windows currently reports, read from the Win32_NetworkConnection list.
    #
    # The redirector keeps one entry per connected resource, including connections a program never made
    # through this app — a share opened in Explorer, or one reached by IP address. Cancelling those by name
    # is the only way to clear a session that WNetCancelConnection2 on "\\HOST" does not touch.
    param([string]$HostName)
    $names = @()
    try {
        foreach ($item in @(Get-CimInstance -ClassName Win32_NetworkConnection -ErrorAction SilentlyContinue)) {
            $remote = [string]$item.RemoteName
            if (-not $remote) { continue }
            if (-not $HostName -or $remote -like "\\$HostName" -or $remote -like "\\$HostName\*") { $names += $remote }
        }
    } catch { }
    return $names
}

function Test-LanConnectionHeld {
    # Whether Windows still holds a session under this name. WNetGetConnection answers for a drive letter and
    # WNetGetUser for a connected resource; either answering means the name is still in use.
    param([Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$Target)
    try {
        if ($Target.Length -eq 1) {
            $mapped = if ($Adapter.GetMapping) { [string](& $Adapter.GetMapping $Target) } else { '' }
            return [bool]$mapped
        }
        if ($Adapter.GetSession) {
            $session = [string](& $Adapter.GetSession $Target)
            return [bool]$session
        }
    } catch { }
    return $false
}

function Disconnect-LanQuietly {
    # Cancels a connection and treats "there was nothing to cancel" as success.
    #
    # Error 2250 is what Windows returns for a name it does not hold. That is a normal outcome here rather
    # than a failure: repairing a conflicting session closes connections that a later un-map may try to
    # close again, and the user must not be shown an error for something already gone.
    param([Parameter(Mandatory)][hashtable]$Adapter,
          [Parameter(Mandatory)][string]$Target,
          [bool]$Persistent = $true,
          [bool]$Force = $true)
    try {
        $result = & $Adapter.Disconnect $Target $Persistent $Force
        if ([int]$result -eq 2250) { return 0 }
        return [int]$result
    } catch { return 0 }
}

function Clear-LanConflictingSession {
    # Windows refuses a second session to one host with different credentials (error 1219) and never
    # replaces the first one by itself. The only reliable way past it is to close what Windows holds
    # and connect again, which is exactly what this does — once, and only when the existing session
    # really belongs to somebody else.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Adapter,
        [Parameter(Mandatory)][scriptblock]$Retry,
        [string]$Local,
        [bool]$Persistent = $false,
        [bool]$Prompt = $false,
        [string]$UserName,
        [string]$Password
    )
    $existing = ''
    if ($Adapter.GetSession) { try { $existing = [string](& $Adapter.GetSession $Root) } catch { } }
    if ($UserName -and $existing -ieq $UserName) {
        if (-not $Local) { return 0 }
        $entry = [pscustomobject]@{Letter=$Local;Unc=$Root}
        if (Test-LanSavedConnectionReadable -Entry $entry -Adapter $Adapter) { return 0 }
        $result = [int](& $Retry $Root $Local $Persistent $false $null $null)
        if ($result -eq 0 -and (Test-LanSavedConnectionReadable -Entry $entry -Adapter $Adapter)) { return 0 }
        return $(if ($result -eq 0) { 1219 } else { $result })
    }
    if (-not $Adapter.Disconnect) { return 1219 }
    # The account of an existing session cannot be read reliably: WNetGetUser returns nothing for a session
    # that a mapped drive holds, so "is it a different account?" cannot be answered that way and the answer
    # does not matter here. The connection was refused with 1219, so something is held against this host;
    # everything this user holds there is closed, the account is re-checked afterwards if it can be read,
    # and the connection is attempted again.
    Clear-LanHostConnections -HostName ($Root.Substring(2).Split('\')[0]) -Share ($Root.Split('\')[3]) -Adapter $Adapter | Out-Null
    $after = ''
    if ($Adapter.GetSession) { try { $after = [string](& $Adapter.GetSession $Root) } catch { $after = '' } }
    if ($after -and $after -ine [string]$UserName) { return 1219 }   # still held by somebody else
    return (& $Retry $Root $Local $Persistent $Prompt $UserName $Password)
}

function Clear-LanStaleNetworkMappings {
    # Releases drive letters that Windows still holds but that no longer resolve to anything.
    #
    # When the network changes — a different router, SSID or VLAN — a mapped drive can keep its letter
    # while its target is unreachable. GetMapping then returns an empty value (the redirector cannot ask an
    # unreachable server what it is connected to), so the reconnect decides the letter is free, tries to use
    # it, and Windows refuses with error 85 "already in use". The letter is never released and every later
    # attempt fails the same way — which is exactly the failure the log showed with no error code at all.
    param([hashtable]$Adapter,
          [scriptblock]$Log)
    $released = New-Object System.Collections.Generic.List[string]
    $write = { param($text)
        try {
            if ($Log) { & $Log $text }
            elseif (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog $text }
        } catch { }
    }
    if (-not $Adapter) { $Adapter = @{} }
    if (-not $Adapter.Disconnect) { return @() }
    $statePath = Get-LanClientStatePath $Adapter
    $saved = @{}
    foreach ($entry in @(Read-LanClientMappings -Path $statePath)) {
        if ($entry.Letter) { $saved[[string]$entry.Letter] = [string]$entry.Unc }
    }
    # Both the letters the app recorded and the ones Windows currently reports: the record is what should be
    # there, and the live list catches anything left behind by an older run. The live list goes through the
    # adapter when it can supply one, so a caller can work against its own set of drives instead of whatever
    # this machine happens to have mapped.
    $live = if ($Adapter.GetNetworkDriveLetters) { @(& $Adapter.GetNetworkDriveLetters) }
            else { @(Get-LanNetworkDriveLetters) }
    $letters = New-Object System.Collections.Generic.List[string]
    foreach ($letter in @($saved.Keys)) { $letters.Add([string]$letter) }
    foreach ($letter in $live) { if ($letter -notin $letters) { $letters.Add([string]$letter) } }
    $changed = $false
    foreach ($letter in $letters) {
        try {
            $mapped = [string](& $Adapter.GetMapping $letter)
            if ($mapped) { continue }   # Windows still knows where this letter points
            $before = if ($saved.ContainsKey($letter)) { [string]$saved[$letter] } else { '' }
            if (-not $before) {
                # A letter Windows holds with nothing recorded for it: a leftover from an older run.
                # There is no saved path to rebuild it from, so it is simply cancelled.
                if ([int](Disconnect-LanQuietly -Adapter $Adapter -Target $letter -Persistent $true) -eq 0) {
                    $released.Add($letter)
                    $changed = $true
                    & $write "ปล่อยไดรฟ์ที่ไม่รู้ที่มา: $letter`:"
                }
                continue
            }
            # This letter belongs to a saved mapping, so it is worth recovering rather than deleting.
            # GetMapping answers nothing while the host is unreachable, and deleting on that alone is what
            # made a restart or a network change lose the drive: the record vanished, so nothing was left
            # to reconnect. The connection is attempted first, and the drive is only released when the host
            # cannot be reached at all — and even then the record is kept so a later repair can retry.
            $serverName = $before.Substring(2).Split('\')[0]
            if (Test-LanHostReachable -HostName $serverName) {
                & $write "พบไดรฟ์ที่ต้องเชื่อมใหม่: $letter`: → $before (เก็บไว้ ไม่ลบ)"
            } elseif ([int](Disconnect-LanQuietly -Adapter $Adapter -Target $letter -Persistent $true) -eq 0) {
                $released.Add($letter)
                $changed = $true
                & $write "ปล่อยไดรฟ์ชั่วคราวเพราะติดต่อ $serverName ไม่ได้: $letter`: (บันทึกไว้แล้ว จะลองใหม่)"
            }
        } catch { }
    }
    if ($changed) {
        # Only letters with no saved mapping behind them are removed from the list. A released letter that
        # does have a record keeps it, so the drive can still be reconnected once the host is reachable.
        $remaining = @(Read-LanClientMappings -Path $statePath |
            Where-Object { [string]$_.Letter -notin $released -or -not [string]::IsNullOrWhiteSpace([string]$_.Unc) })
        Write-LanClientMappings -Path $statePath -Mappings $remaining
    }
    return @($released)
}

function Test-LanHostReachable {
    # Whether the sharing machine answers at all. This is what tells "the network moved" apart from "the
    # credentials are stale": the two need different repairs and the error code alone does not say which.
    param([Parameter(Mandatory)][string]$HostName)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($HostName, 1500)
        return ($null -ne $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch { return $false }
}

function Repair-LanClientConnection {
    # One entry point for "make the saved drives work again", covering everything a network change breaks.
    #
    # The order matters. Stale drive letters are released first, because a held letter makes every later
    # step fail with "already in use". Any session to the host is closed next, because Windows keeps one
    # credential per server and refuses a different one with error 1219. Only then are the mappings
    # reconnected, each with the credential already stored for its host.
    param([Parameter(Mandatory)][hashtable]$Adapter,
          [string]$Unc,
          [scriptblock]$Log,
          [switch]$SkipConnect)
    $write = { param($text)
        try {
            if ($Log) { & $Log $text }
            elseif (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog $text }
        } catch { }
    }
    $report = [ordered]@{ Released=@(); Closed=@(); Removed=@(); HostReachable=$null; Connected=@(); Failed=@(); Message='' }
    foreach ($savedEntry in @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter))) {
        if ($savedEntry.Transport -eq 'NetBird' -and (-not $Unc -or (Get-LanUncRoot $savedEntry.Unc) -eq (Get-LanUncRoot $Unc))) {
            $guard=Test-LanClientOnlineTarget -Entry $savedEntry -Adapter $Adapter
            if (-not $guard.Ready) { $report.Message=$guard.Reason; return [pscustomobject]$report }
        }
    }
    try {
        # Drives whose share was stopped are removed first. They would otherwise be reconnected forever, and
        # Explorer would keep listing them under "Network locations" for the user to disconnect by hand.
        $report.Removed = @(Remove-LanStaleMappings -Adapter $Adapter -Log $Log)
        $report.Released = @(Clear-LanStaleNetworkMappings -Adapter $Adapter -Log $Log)

        $hostName = ''
        if ($Unc -and $Unc -match '^\\\\[^\\]+') { $hostName = ($Unc -replace '^\\\\','').Split('\')[0] }
        if (-not $hostName) {
            $saved = @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter))
            if ($saved.Count -gt 0) { $hostName = ([string]$saved[0].Unc -replace '^\\\\','').Split('\')[0] }
        }
        if ($hostName) {
            if (Test-LanHostReachable -HostName $hostName) {
                $report.HostReachable = $true
                $shareName = ''
                if ($Unc -and $Unc -match '^\\\\[^\\]+\\([^\\]+)') { $shareName = $Matches[1] }
                # Look before tearing anything down.
                #
                # Closing every session to the host was unconditional, so a machine whose drives were perfectly
                # usable had them cut and reopened on each pass — the connection seemed to drop again and again
                # and nothing could be worked on. A session is now only cleared when at least one saved drive to
                # that host is actually unreadable; when every settled drive is readable there is nothing to
                # repair, and the report says so instead of touching the network.
                $settled = @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter) |
                    Where-Object { [string]$_.Unc -like "\\$hostName\*" -and [string]$_.Letter })
                $broken = @()
                foreach ($candidate in $settled) {
                    if (-not (Test-Path -LiteralPath ("{0}:\" -f [string]$candidate.Letter))) { $broken += $candidate }
                }
                if ($settled.Count -gt 0 -and $broken.Count -eq 0) {
                    $report.Message = 'ไดรฟ์ที่บันทึกไว้เชื่อมต่อได้ทุกตัว — ไม่ต้องซ่อม'
                    return [pscustomobject]$report
                }
                $report.Closed = @(Clear-LanHostConnections -HostName $hostName -Share $shareName -Adapter $Adapter -Log $Log)
            } else {
                $report.HostReachable = $false
                $report.Message = "ติดต่อเครื่องผู้แชร์ $hostName ไม่ได้ — ตรวจว่าเปิดเครื่องอยู่และอยู่ในเครือข่ายเดียวกัน"
            }
        }

        if (-not $SkipConnect) {
            $summary = Restore-LanClientMappings -Adapter $Adapter -Log $Log
            $report.Connected = @($summary.Connected)
            $report.Failed = @($summary.Skipped)
            if (-not $report.Message) {
                $report.Message = if ([int]$summary.Total -eq 0) { 'ไม่มีไดรฟ์ที่บันทึกไว้ให้เชื่อมต่อ' }
                    elseif (@($summary.Connected).Count -gt 0) { ('เชื่อมต่อกลับแล้ว: {0}' -f (@($summary.Connected) -join ', ')) }
                    else { 'ยังเชื่อมต่อไม่ได้ — กด Map Drive อีกครั้งเพื่อเชื่อมด้วยรหัสที่บันทึกไว้' }
            }
        } elseif (-not $report.Message -and $report.HostReachable) {
            $report.Message = 'ปิดการเชื่อมต่อเดิมเรียบร้อย — กด Map Drive หรือ เปิด UNC อีกครั้งได้เลย'
        }
    } catch {
        $report.Message = "ซ่อมการเชื่อมต่อไม่สำเร็จ: $($_.Exception.Message)"
        & $write $report.Message
    }
    return [pscustomobject]$report
}

function Get-LanWindowsCurrentHint {
    # Explains what to do about the Guest fallback in words that match the user's actual situation.
    # The same code has two very different causes, and saying the wrong one sends the user to the
    # wrong fix — which is why this error kept coming back described as unfixable.
    param([Parameter(Mandatory)][string]$Root,
          [Parameter(Mandatory)][bool]$HostAccountGiven,
          [hashtable]$Adapter)
    $server = $Root.Substring(2).Split('\')[0]
    $newline = "`r`n"
    if ($HostAccountGiven) {
        return (' WindowsCurrent sent the account you entered, but the host refused it.' + $newline +
                "  - Check the account name: it must exist on $server." + $newline +
                '  - If that account has a password, set วิธีเข้าใช้ = Protected Password and enter the same' +
                ' user name and password here; Windows then logs on with them.' + $newline +
                '  - On the sharing machine, open the ผู้แชร์ tab and press "อนุญาตบัญชีไม่มีรหัสผ่าน LAN"' +
                ' only when that host account really has no password.')
    }
    $currentAccount = $null
    if ($Adapter -and $Adapter.GetBlankPasswordAccount) { $currentAccount = [string](& $Adapter.GetBlankPasswordAccount) }
    if (-not $currentAccount) {
        # The signed-in account has a password, so Windows has nothing to offer the host: it cannot
        # send the password of the current user to another computer automatically.
        return (" This computer signs in with a password, so Windows cannot pass it to $server by itself and" +
                ' fell back to Guest, which Windows blocks.' + $newline +
                '  Choose one of these:' + $newline +
                "  - Fill in 'บัญชีบนเครื่องผู้แชร์' with the Windows account name that exists on $server and" +
                ' that has NO password (with "อนุญาตบัญชีไม่มีรหัสผ่าน LAN" enabled on the sharing machine).' + $newline +
                '  - Or set วิธีเข้าใช้ = Protected Password, then enter a user name and password created for the share.' + $newline +
                '  - Or sign in to this computer with the same account name and password that exists on the sharing machine.')
    }
    return (' Windows sent the current account name, but it does not exist on ' + $server + ', so Windows fell back to Guest, which Windows blocks.' + "`r`n" +
            "  - Fill in 'บัญชีบนเครื่องผู้แชร์' with an account name that exists on $server (no password)," +
            ' or set วิธีเข้าใช้ = Protected Password and enter a user name and password.' + "`r`n" +
            '  - On the sharing machine, open the ผู้แชร์ tab and press "อนุญาตบัญชีไม่มีรหัสผ่าน LAN"' +
            ' when that host account has no password.')
}

function Resolve-LanClientCredentials {
    param([Parameter(Mandatory)][string]$Root,
          [Parameter(Mandatory)][string]$AuthMode,
          [string]$WindowsAccount,
          [string]$Password,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $server = $Root.Substring(2).Split('\')[0]
    if ($AuthMode -eq 'Protected') {
        # This is the only mode that works between machines whose own Windows account names differ:
        # the sharing machine creates an account for the share and the user types that name and
        # password here, so nothing depends on the two machines matching.
        $account = if ([string]::IsNullOrWhiteSpace($WindowsAccount)) { $null } else { $WindowsAccount.Trim() }
        # The saved credential is read through the adapter when it offers a way to, and directly otherwise.
        #
        # Requiring the adapter to provide it meant the lookup silently returned nothing for every adapter
        # that did not — and a caller that had stored the password and typed the account it belongs to was
        # then told the password was missing. That is what made the automatic reconnect fail while the
        # credentials were sitting correctly in the store.
        $remembered = $null
        try {
            if($account -and $Password){ }
            elseif ($Adapter.GetRememberedCredential) { $remembered = & $Adapter.GetRememberedCredential $server $Adapter }
            elseif (Get-Command Get-LanRememberedCredential -ErrorAction SilentlyContinue) {
                $remembered = Get-LanRememberedCredential -HostName $server -Adapter $Adapter
            }
        } catch { $remembered = $null }
        if (-not $account) {
            # Nothing typed: use what was saved, otherwise fall through with no credentials so the
            # normal prompted logon still happens exactly as it did before.
            if ($remembered) { return [pscustomobject]@{ UserName=$remembered.UserName; Password=$remembered.Password } }
            return $null
        }
        $credentialServer=$server
        if ($account.Contains('\')) {
            $parts = $account.Split('\')
            $credentialServer=$server
            $online=$Adapter.VerifiedOnlineTarget
            if($online -and $online.Transport -eq 'NetBird' -and $online.Unc.TrimStart('\').Split('\')[0] -ieq $server){$credentialServer=$parts[0]}
            if ($parts.Length -ne 2 -or $parts[0] -ine $credentialServer -or $parts[0] -notmatch '^[^\\/:*?"<>|]+$') { throw 'The user name must belong to the UNC host.' }
            $account = $parts[1]
        }
        if(-not $credentialServer){$credentialServer=$server}
        if ($account -notmatch '^[^\\/:*?"<>|]+$') { throw 'The user name is not valid for SMB.' }
        # The password may be left empty only when it was saved for this same account, so the user
        # types it once and later visits need nothing at all. Only the account part is compared: it
        # was saved as "HOST\name" but the user may have typed just "name", and treating those as
        # different made the saved password go unused.
        $secret = $Password
        if ([string]::IsNullOrEmpty($secret) -and $remembered) {
            $rememberedAccount = [string]$remembered.UserName
            if ($rememberedAccount.Contains('\')) { $rememberedAccount = $rememberedAccount.Split('\')[1] }
            if ($rememberedAccount -ieq $account) { $secret = $remembered.Password }
        }
        if ([string]::IsNullOrEmpty($secret)) { throw 'Protected Password needs the password created on the sharing machine.' }
        return [pscustomobject]@{ UserName="$credentialServer\$account"; Password=$secret }
    }
    if ($AuthMode -ne 'WindowsCurrent') { return $null }
    if (-not [string]::IsNullOrWhiteSpace($WindowsAccount)) {
        $account = $WindowsAccount.Trim()
        if ($account.Contains('\')) {
            $parts = $account.Split('\')
            if ($parts.Length -ne 2 -or $parts[0] -ine $server) { throw 'Windows account must belong to the UNC host.' }
            $account = $parts[1]
        }
        if ($account -notmatch '^[^\\/:*?"<>|]+$') { throw 'Host Windows account name is invalid for SMB.' }
        return [pscustomobject]@{ UserName="$server\$account"; Password='' }
    }
    if (-not $Adapter.GetBlankPasswordAccount) { return $null }
    $account = [string](& $Adapter.GetBlankPasswordAccount)
    if (-not $account) { return $null }
    if ($account -notmatch '^[^\\/:*?"<>|]+$') { throw 'Current Windows account name is invalid for SMB.' }
    if ($server -match '^[0-9.]+$' -or $server.Contains(':')) { return $null }
    return [pscustomobject]@{ UserName="$server\$account"; Password='' }
}

function Get-LanCurrentHostAccount {
    param([Parameter(Mandatory)][string]$Root,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $identity = if ($Adapter.GetCurrentIdentityName) { [string](& $Adapter.GetCurrentIdentityName) }
                else { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $localComputer = if ($Adapter.GetLocalComputerName) { [string](& $Adapter.GetLocalComputerName) }
                     else { $env:COMPUTERNAME }
    $parts = $identity.Split('\')
    if ($parts.Length -ne 2 -or $parts[0] -ine $localComputer) { return $null }
    $server = $Root.Substring(2).Split('\')[0]
    if ($server -match '^[0-9.]+$' -or $server.Contains(':')) { return $null }
    return "$server\$($parts[1])"
}

function Test-LanCurrentSession {
    param([Parameter(Mandatory)][string]$Root,
          [Parameter(Mandatory)][hashtable]$Adapter)
    if (-not $Adapter.GetSession) { return $false }
    $expected = Get-LanCurrentHostAccount -Root $Root -Adapter $Adapter
    if (-not $expected) { return $false }
    $actual = & $Adapter.GetSession $Root
    return [string]$actual -ieq $expected
}

function Set-LanWindowsCredential {
    # Stores a share account in Windows Credential Manager, which is what stops the "Enter network
    # credentials" dialog.
    #
    # Windows restores a persistent mapped drive at logon before this application is running, and it can
    # only do that silently if a credential for the server is already in the vault. Without one it asks
    # every single time, even though this program holds the password. The target name is the one Windows
    # uses for a file share: the raw NetBIOS/DNS server name, with a qualified account.
    #
    # The password stays in memory; it is never passed to a child process command line.
    param([Parameter(Mandatory)][string]$HostName,
          [Parameter(Mandatory)][string]$UserName,
          [Parameter(Mandatory)][string]$Password,
          [scriptblock]$Query)
    $account = $UserName
    if(-not $account.Contains('\') -and -not $account.Contains('@')){$account=$HostName+'\'+$account}
    $target = $HostName
    $targetPtr = [IntPtr]::Zero
    $userPtr = [IntPtr]::Zero
    $blobPtr = [IntPtr]::Zero
    $recordPtr = [IntPtr]::Zero
    $bytes = [Text.Encoding]::Unicode.GetBytes($Password)
    try {
        $targetPtr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($target)
        $userPtr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($account)
        $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
        [Runtime.InteropServices.Marshal]::Copy($bytes,0,$blobPtr,$bytes.Length)
        $record = New-Object LanCredentialNative+Credential
        $record.Type = 2
        $record.TargetName = $targetPtr
        $record.UserName = $userPtr
        $record.CredentialBlobSize = $bytes.Length
        $record.CredentialBlob = $blobPtr
        $record.Persist = 2
        $recordPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal([Runtime.InteropServices.Marshal]::SizeOf($record))
        [Runtime.InteropServices.Marshal]::StructureToPtr($record,$recordPtr,$false)
        if ($Query) { return [bool](& $Query $recordPtr) }
        return [LanCredentialNative]::Write($recordPtr,0)
    } catch { return $false }
    finally {
        [Array]::Clear($bytes,0,$bytes.Length)
        if ($blobPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::Copy($bytes,0,$blobPtr,$bytes.Length)
            [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
        }
        foreach ($pointer in @($recordPtr,$targetPtr,$userPtr)) {
            if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
        }
    }
}
function Remove-LanWindowsCredential {
    # Removes only the vault entry this app wrote, so unmapping a drive leaves no password behind.
    param([Parameter(Mandatory)][string]$HostName)
    $target = $HostName
    $removed = $false
    if ('LanCredentialNative' -as [type]) {
        try { if ([LanCredentialNative]::Delete($target, 2, 0)) { $removed = $true } } catch { }
    }
    try { & cmdkey.exe "/delete:$target" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $removed = $true } } catch { }
    return $removed
}

function Restore-LanClientMappings {
    # Reconnects the mappings this app saved, so a reboot needs no attention.
    #
    # Windows does restore a persistent mapping by itself, but only when the sharing machine happens to
    # be reachable at logon. A laptop that starts before the other machine, or on a different network,
    # gets a silent failure and the drive stays missing until somebody connects by hand — which is what
    # the Windows credential prompt was asking for. This runs after logon and reconnects each saved
    # mapping with the credential already stored for its host.
    param([Parameter(Mandatory)][hashtable]$Adapter,
          [scriptblock]$Log)
    # The whole body is guarded. Renewing drive mappings is a convenience that runs unattended at
    # startup, so anything that goes wrong here must be recorded and swallowed: an exception escaping
    # into the application's event loop becomes an unhandled WinForms error dialog, which is far worse
    # than a drive that has to be mapped by hand once.
    try {
        return Invoke-LanRestoreClientMappings -Adapter $Adapter -Log $Log
    } catch {
        try {
            if ($Log) { & $Log "เชื่อมต่ออัตโนมัติล้มเหลว: $($_.Exception.Message)" }
            elseif (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog "เชื่อมต่ออัตโนมัติล้มเหลว: $($_.Exception.Message)" }
        } catch { }
        return [pscustomobject]@{ Connected=@(); Skipped=@('error'); Total=0; Error=$_.Exception.Message }
    }
}

function Invoke-LanRestoreClientMappings {
    param([Parameter(Mandatory)][hashtable]$Adapter,[scriptblock]$Log)
    $entries = @(Read-LanClientMappings -Path (Get-LanClientStatePath $Adapter))
    $connected = New-Object Collections.Generic.List[string]
    $skipped = New-Object Collections.Generic.List[string]
    foreach ($entry in $entries) {
        if (-not $entry.Unc -or (-not $entry.Letter -and $entry.ConnectionKind -ne 'Unc')) { continue }
        $label = if ($entry.Letter) { [string]$entry.Letter } elseif ($entry.Path) { [string]$entry.Path } else { [string]$entry.Unc }
        if (-not (Test-LanMappingWatched $entry)) { $skipped.Add($label); continue }
        try { $status = Invoke-LanSavedConnection -Entry $entry -Adapter $Adapter }
        catch { $status = 'Waiting' }
        if ($status -eq 'Connected') { $connected.Add($label) }
        else { $skipped.Add($label) }
        try {
            $message = if ($status -eq 'Connected') { "Connected automatically: $label" } else { "Connection not ready: $label" }
            if ($Log) { & $Log $message }
            elseif (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog $message }
        } catch { }
    }
    return [pscustomobject]@{ Connected=@($connected); Skipped=@($skipped); Total=$entries.Count }
}
function Save-LanClientConnection {
    # Persistence must never turn a validated working connection into a failed connection. The return
    # value describes what was saved, while exposing no credential material to UI callers or logs.
    param([Parameter(Mandatory)]$Entry,[Parameter(Mandatory)][hashtable]$Adapter,$Credentials)
    $warnings = New-Object Collections.Generic.List[string]
    $remembered = $true
    if ($Entry.AuthMode -eq 'Protected') {
        if (-not $Credentials -or -not $Credentials.Password) {
            $remembered = $false
            $warnings.Add('Connected, but Windows did not provide a password to remember. Enter the share account and password once to reconnect automatically.')
        } else {
            try {
                Write-LanClientCredential -Adapter $Adapter -HostName $Entry.HostName -UserName $Credentials.UserName -Password $Credentials.Password | Out-Null
            } catch { $remembered = $false; $warnings.Add('Connected, but the encrypted account and password could not be saved. Check access to the credential store; existing credentials were preserved.') }
            if ($Entry.Transport -ne 'NetBird') {
                try {
                    $saved = if ($Adapter.SetWindowsCredential) { & $Adapter.SetWindowsCredential $Entry.HostName $Credentials.UserName $Credentials.Password }
                             else { Set-LanWindowsCredential -HostName $Entry.HostName -UserName $Credentials.UserName -Password $Credentials.Password }
                    if (-not $saved) { $warnings.Add('Connected, but Windows Credential Manager could not save the account. The app will retry using its encrypted credential store.') }
                } catch { $warnings.Add('Connected, but Windows Credential Manager could not save the account. The app will retry using its encrypted credential store.') }
            }
        }
    }
    try {
        $statePath = Get-LanClientStatePath $Adapter
        $entries = @(Read-LanClientMappings $statePath)
        if ($Entry.Letter) { $remaining = @($entries | Where-Object { $_.Letter -ine $Entry.Letter }) }
        else { $remaining = @($entries | Where-Object { $_.Letter -or $_.ConnectionKind -ne 'Unc' -or [string]$_.Path -ine [string]$Entry.Path }) }
        Write-LanClientMappings -Path $statePath -Mappings ($remaining + @($Entry))
    } catch { $remembered = $false; $warnings.Add('Connected, but the connection profile could not be saved. Check access to mappings.json; the current connection remains available.') }
    # The app can restore from its encrypted store even if the optional Windows vault is unavailable.
    $Entry | Add-Member -NotePropertyName Remembered -NotePropertyValue $remembered -Force
    $Entry | Add-Member -NotePropertyName PersistenceWarning -NotePropertyValue ($warnings -join ' ') -Force
    return $Entry
}

function Add-LanClientMap {
    param([Parameter(Mandatory)][string]$Unc,
          [string]$Letter = 'Auto',
          [bool]$Persistent = $true,
          [string]$WindowsAccount,
          [string]$Password,
          [Parameter(Mandatory)][ValidateSet('Protected','WindowsCurrent','Guest')][string]$AuthMode,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $root = Get-LanUncRoot $Unc
    if ((Assert-LanUnc $Unc) -ne $root) { throw 'Map Drive requires a share root, not a file or subfolder.' }
    Assert-LanSavedOnlineTarget -Unc $root -Adapter $Adapter
    $onlineTarget=Get-LanNewOnlineTarget -Unc $root -Adapter $Adapter
    $Adapter.VerifiedOnlineTarget=$onlineTarget
    if($onlineTarget){$Persistent=$false}
    if ($AuthMode -eq 'Guest') {
        $check = Get-LanGuestCompatibility -Role Client -Adapter $Adapter
        if (-not $check.Supported -or @($check.RequiredChanges).Count -gt 0) { throw 'Guest SMB client policy is blocked or needs explicit configuration.' }
    }
    $occupied = @(& $Adapter.GetOccupiedLetters)
    $chosen = if ($Letter -eq 'Auto') { Get-LanFreeDriveLetter -Occupied $occupied } else { $Letter.TrimEnd(':').ToUpperInvariant() }
    $statePath = Get-LanClientStatePath $Adapter
    $owned = @(Read-LanClientMappings $statePath | Where-Object { $_.Letter -eq $chosen })
    if ($owned.Count -gt 0) {
        # Pressing Map Drive again on a saved drive is a request to connect it, not an error.
        #
        # The letter is already this app's, so there is nothing to allocate; the old connection is dropped
        # and the mapping is rebuilt with the credentials just supplied. Reporting "this app already owns
        # that drive letter" left the user with no way forward after a repair had removed the connection,
        # which is exactly when they press the button.
        try { Disconnect-LanQuietly -Adapter $Adapter -Target $chosen -Persistent $false | Out-Null } catch { }
        # Keep the previous profile until a replacement connection has passed every validation.
        $occupied = @($occupied | Where-Object { $_ -ne $chosen })
    }
    if ($chosen -notmatch '^[E-Z]$' -or $chosen -in $occupied) { throw "Drive letter is unavailable: $chosen" }
    # One account per server, chosen before anything is attempted.
    #
    # Windows keeps a single credential for a machine, so a second drive to the same machine with a different
    # account can never connect: it answers 1219 while the first drive keeps its session, and the two take
    # turns failing. That is what "several shares on one machine cannot be mapped at once" was.
    #
    # The account stored for the host is therefore used for every share on it. A different name typed here is
    # passed through only when this host has no stored account yet, or when a password was supplied with it —
    # in that case the user is deliberately changing the account for the whole machine, and the stored one is
    # replaced below.
    $serverForAccount = $root.Substring(2).Split('\')[0]
    $storedForHost = ''
    $storedCredential = $null
    if ($Adapter.GetRememberedCredential -and -not ($WindowsAccount -and $Password)) { $storedCredential = & $Adapter.GetRememberedCredential $serverForAccount $Adapter }
    if ($storedCredential) { $storedForHost = [string]$storedCredential.UserName }
    $typedName = if ($WindowsAccount) { $WindowsAccount -replace '^[^\\]+\\','' } else { '' }
    $changingAccount = [bool]($typedName -and $Password)
    if ($storedForHost -and -not $changingAccount) {
        $credentials = [pscustomobject]@{ UserName = $storedForHost; Password = [string]$storedCredential.Password }
    } else {
        $credentials = Resolve-LanClientCredentials -Root $root -AuthMode $AuthMode -WindowsAccount $WindowsAccount -Password $Password -Adapter $Adapter
        if (-not $credentials -and $storedForHost -and $storedCredential) {
            $credentials = [pscustomobject]@{ UserName = $storedForHost; Password = [string]$storedCredential.Password }
        }
    }
    $userName = if ($credentials) { $credentials.UserName } else { $null }
    $password = if ($credentials) { $credentials.Password } else { $null }
    # Windows allows one credential per server. When this machine holds a different one for the same
    # host — another share's account, or a UNC opened by hand — every mapping here would fail with 1219.
    # Clearing it up front is what keeps that error from ever appearing, rather than offering to repair it
    # afterwards.
    $serverName = $root.Substring(2).Split('\')[0]
    $session = if ($Adapter.GetSession) { [string](& $Adapter.GetSession $root) } else { '' }
    if ($credentials -and $session -and $session -ine [string]$userName) {
        Clear-LanHostConnections -HostName $serverName -Share ($root.Split('\')[3]) -Adapter $Adapter | Out-Null
    }
    $result = & $Adapter.Connect $root $chosen $Persistent ($AuthMode -eq 'Protected') $userName $password
    # A letter Windows reports as free can still be refused by the redirector: error 1202 was seen for Z:
    # on this machine while every letter from E to Y worked, and error 85 means the letter is in use
    # after all. With Auto the next candidate is tried, so an unusable letter never ends the attempt.
    if ($Letter -eq 'Auto' -and @(1202, 85) -contains [int]$result) {
        foreach ($candidate in @(Get-LanFreeDriveLetterList -Occupied ($occupied + $chosen))) {
            $attempt = & $Adapter.Connect $root $candidate $Persistent ($AuthMode -eq 'Protected') $userName $password
            if ([int]$attempt -eq 0) {
                # The refused letter can leave a half-made connection behind; drop it before moving on.
                try { & $Adapter.Disconnect $chosen $Persistent $true | Out-Null } catch { }
                $chosen = $candidate
                $result = 0
                break
            }
        }
    }
    if ($AuthMode -eq 'WindowsCurrent' -and -not $credentials -and ($result -eq 5 -or $result -eq 1219)) {
        $sameAccount = Get-LanCurrentHostAccount -Root $root -Adapter $Adapter
        if ($sameAccount) { $result = & $Adapter.Connect $root $chosen $Persistent $false $sameAccount '' }
    }
    # 1219 means Windows already holds a session to this host as somebody else, and Windows never
    # opens a second one with different credentials. Only WindowsCurrent used to handle it, so a
    # Protected share failed on a machine that had reached the same host another way — which is
    # common when the user first tries the wrong account and then pastes the right one.
    if ([int]$result -eq 1219 -and $credentials) {
        $result = Clear-LanConflictingSession -Root $root -Adapter $Adapter -Local $chosen `
            -Persistent $Persistent -Prompt ($AuthMode -eq 'Protected') `
            -UserName $userName -Password $password -Retry {
                param($r,$l,$p,$prompt,$u,$pw)
                & $Adapter.Connect $r $l $p $prompt $u $pw
            }
    }
    # Build the explanation only for the code that needs one, so other failures stay short.
    $hint = if ([int]$result -eq 1272) {
        Get-LanWindowsCurrentHint -Root $root -HostAccountGiven (-not [string]::IsNullOrWhiteSpace($WindowsAccount)) -Adapter $Adapter
    } else { '' }
    if ([int]$result -eq 67) {
        # "Share name not found" is the one error the user cannot act on without knowing what the other machine
        # is actually offering, so the machine is asked for its list and the answer is part of the message.
        $peer = $root.Substring(2).Split('\')[0]
        $wanted = $root.Split('\')[3]
        $offered = @(Get-LanRemoteShareNames -ComputerName $peer)
        $hint = if ($offered.Count -gt 0) {
            (" เครื่อง {0} กำลังเปิดแชร์: {1} — ไม่มีชื่อ '{2}' ตรวจชื่อแชร์ที่เครื่องผู้แชร์ หรือแชร์นั้นถูกหยุดไปแล้ว" -f $peer, ($offered -join ', '), $wanted)
        } else {
            (" อ่านรายชื่อแชร์ของ {0} ไม่ได้ — ตรวจว่าบริการ Server (LanmanServer) ทำงานอยู่ และแชร์ '{1}' ยังเปิดอยู่ในแท็บผู้แชร์" -f $peer, $wanted)
        }
    }
    if ([int]$result -ne 0) { Throw-LanWNetError ([int]$result) -Hint $hint }
    try {
        Assert-LanClientSession -Root $root -ConnectionName "$chosen`:" -AuthMode $AuthMode -Adapter $Adapter
        if ($WindowsAccount -and $AuthMode -eq 'WindowsCurrent' -and
            [string](& $Adapter.GetSession "$chosen`:") -ine [string]$credentials.UserName) { throw 'SMB connected with a different Windows account.' }
        Assert-LanClientPathReadable -Path "$chosen`:" -ConnectionName "$chosen`:" -Adapter $Adapter
    }
    catch {
        & $Adapter.Disconnect $chosen $Persistent $false | Out-Null
        # The session check can fail in place of a network error: Windows returns success and only
        # the session shows the Guest fallback. Explain that case the same way.
        if ($_.Exception.Message -match 'fell back to Guest') {
            throw ($_.Exception.Message + (Get-LanWindowsCurrentHint -Root $root -HostAccountGiven (-not [string]::IsNullOrWhiteSpace($WindowsAccount)) -Adapter $Adapter))
        }
        throw
    }
    # Everything needed to rebuild this mapping later is recorded here, not just the letter and path.
    #
    # The client form used to lose the path, the access mode, the host account and the password on every
    # restart: the fields started empty, so the automatic reconnect had nothing to work from and selecting a
    # saved drive filled in nothing. The record now carries the access mode and the host account, and the
    # password is written to the credential store at the same moment, because this object is only built
    # after the connection has actually succeeded.
    $entry = [pscustomobject]@{
        Letter         = $chosen
        Unc            = $root
        Persistent     = $Persistent
        AuthMode       = $AuthMode
        WindowsAccount = if ($credentials) { [string]$credentials.UserName } else { '' }
        HostName       = $root.Substring(2).Split('\')[0]
        SavedAt        = [DateTime]::UtcNow.ToString('o')
        Watching       = $true
    }
    if ($onlineTarget) {
        $entry | Add-Member Transport 'NetBird'
        $entry | Add-Member OnlinePeerIdentity $onlineTarget.OnlinePeerIdentity
        $entry | Add-Member OnlineBinding $onlineTarget.OnlineBinding
    }
    return Save-LanClientConnection -Entry $entry -Adapter $Adapter -Credentials $credentials
}

function Remove-LanClientMap {
    param([AllowEmptyString()][string]$Letter,
          [Parameter(Mandatory)][string]$ExpectedUnc,
          [Parameter(Mandatory)][hashtable]$Adapter,
          [switch]$SkipGuestRestore)
    $chosen = if ($Letter) { $Letter.TrimEnd(':').ToUpperInvariant() } else { '' }
    $expected = Get-LanUncRoot $ExpectedUnc
    $statePath = Get-LanClientStatePath $Adapter
    $mappings = @(Read-LanClientMappings $statePath)
    if (-not $chosen) {
        $full = Assert-LanUnc $ExpectedUnc
        $entry = @($mappings | Where-Object { -not $_.Letter -and $_.ConnectionKind -eq 'Unc' -and [string]$_.Path -ieq $full }) | Select-Object -First 1
        if (-not $entry) { throw 'This UNC connection was not remembered by the app.' }
        $remaining = @($mappings | Where-Object { $_.Letter -or $_.ConnectionKind -ne 'Unc' -or [string]$_.Path -ine $full })
        Write-LanClientMappings -Path $statePath -Mappings $remaining
        # Forgetting a UNC profile must leave shared SMB sessions and identity-pinned secrets alone.
        return [pscustomobject]@{ Letter=''; Unc=$expected; Path=$full; Removed=$true }
    }
    $entry = @($mappings | Where-Object { $_.Letter -eq $chosen }) | Select-Object -First 1
    if (-not $entry -or $entry.Unc -ne $expected) { throw 'This mapping was not created by the app for that share.' }
    $actual = & $Adapter.GetMapping $chosen
    if ($actual -and $actual -ne $expected) { throw 'Drive letter now points to another share; unmap refused.' }
    $result = Disconnect-LanQuietly -Adapter $Adapter -Target $chosen -Force $false
    if ([int]$result -ne 0) { Throw-LanWNetError ([int]$result) }
    $remaining = @($mappings | Where-Object { $_.Letter -ne $chosen })
    Write-LanClientMappings -Path $statePath -Mappings $remaining
    # The vault entry is removed once no mapping uses that host any more. Leaving it behind would keep a
    # share password on the machine after the user asked for the drive to be forgotten, and would make
    # Windows reconnect a share the user believes is gone.
    if (([string]$entry.AuthMode) -eq 'Protected' -and $entry.Transport -ne 'NetBird') {
        try {
            $serverName = ([string]$entry.Unc).Substring(2).Split('\')[0]
            $stillUsed = @($remaining | Where-Object { ([string]$_.Unc).Substring(2).Split('\')[0] -ieq $serverName }).Count -gt 0
            if (-not $stillUsed) { Remove-LanWindowsCredential -HostName $serverName | Out-Null }
        } catch { }
    }
    if (-not $SkipGuestRestore -and $entry.AuthMode -eq 'Guest' -and @($remaining | Where-Object { $_.AuthMode -eq 'Guest' }).Count -eq 0) {
        if ($Adapter.RestoreGuest) { & $Adapter.RestoreGuest (Get-LanClientGuestStatePathForAdapter $Adapter) | Out-Null }
        else { Restore-LanGuestConfiguration -Role Client -Adapter $Adapter -StatePath (Get-LanClientGuestStatePathForAdapter $Adapter) | Out-Null }
    }
    return [pscustomobject]@{ Letter=$chosen; Removed=$true }
}

function Get-LanHostShareAccounts {
    # The share accounts that exist on this machine, so "connected but denied" can name the likely one.
    #
    # It happens when the account Windows accepts for the server is not the account the folder grants: the
    # session opens — SMB says connected — and every read is then refused by NTFS. The message the user sees
    # ("the shared path cannot be read") says nothing about what to do. Naming the other account this program
    # made turns that into something that can be acted on.
    param()
    $found = @()
    foreach ($user in @(Get-LocalUser -ErrorAction SilentlyContinue)) {
        if (-not $user.Enabled) { continue }
        if ([string]$user.Description -ne 'LAN File Sharing app account') { continue }
        $found += [pscustomobject]@{ UserName = [string]$user.Name; Sid = [string]$user.SID.Value }
    }
    return $found
}

function Open-LanUnc {
    param([Parameter(Mandatory)][string]$Path,
          [string]$WindowsAccount,
          [string]$Password,
          [Parameter(Mandatory)][ValidateSet('Protected','WindowsCurrent','Guest')][string]$AuthMode,
          [Parameter(Mandatory)][hashtable]$Adapter)
    $full = Assert-LanUnc $Path
    $root = Get-LanUncRoot $full
    Assert-LanSavedOnlineTarget -Unc $root -Adapter $Adapter
    $onlineTarget=Get-LanNewOnlineTarget -Unc $root -Adapter $Adapter
    $Adapter.VerifiedOnlineTarget=$onlineTarget
    if ($AuthMode -eq 'Guest') {
        $check = Get-LanGuestCompatibility -Role Client -Adapter $Adapter
        if (-not $check.Supported -or @($check.RequiredChanges).Count -gt 0) { throw 'Guest SMB client policy is blocked or needs explicit configuration.' }
    }
    # The same rule as Map Drive: Windows keeps one credential per server, so the account already stored for
    # this host is the one that works for every share on it. Using anything else here would close the other
    # drives' session to make room, and "เปิด UNC" would work while the mapped drives stopped.
    $serverForAccount = $root.Substring(2).Split('\')[0]
    $storedForHost = ''
    $storedCredential = $null
    if ($Adapter.GetRememberedCredential -and -not ($WindowsAccount -and $Password)) { $storedCredential = & $Adapter.GetRememberedCredential $serverForAccount $Adapter }
    if ($storedCredential) { $storedForHost = [string]$storedCredential.UserName }
    $accountForHost = $WindowsAccount
    if ($storedForHost) {
        $storedName = $storedForHost -replace '^[^\\]+\\',''
        $typedName = if ($WindowsAccount) { $WindowsAccount -replace '^[^\\]+\\','' } else { '' }
        if (-not $typedName -or $typedName -ieq $storedName) { $accountForHost = $storedForHost }
    }
    $credentials = Resolve-LanClientCredentials -Root $root -AuthMode $AuthMode -WindowsAccount $accountForHost -Password $Password -Adapter $Adapter
    if (-not $credentials -and $storedForHost -and $storedCredential) {
        $credentials = [pscustomobject]@{ UserName = $storedForHost; Password = [string]$storedCredential.Password }
    }
    $userName = if ($credentials) { $credentials.UserName } else { $null }
    $password = if ($credentials) { $credentials.Password } else { $null }
    # Same reasoning as Map Drive: reach the host with the right account by clearing a different one first,
    # so "เปิด UNC" never reports 1219 either.
    $session = if ($Adapter.GetSession) { [string](& $Adapter.GetSession $root) } else { '' }
    if ($credentials -and $session -and $session -ine [string]$userName) {
        Clear-LanHostConnections -HostName ($root.Substring(2).Split('\')[0]) -Share ($root.Split('\')[3]) -Adapter $Adapter | Out-Null
    }
    $result = & $Adapter.Connect $root $null $false ($AuthMode -eq 'Protected') $userName $password
    if ($AuthMode -eq 'WindowsCurrent' -and $credentials -and $result -eq 1219 -and
        [string](& $Adapter.GetSession $root) -ieq [string]$credentials.UserName) { $result = 0 }
    if ($AuthMode -eq 'WindowsCurrent' -and $result -eq 1219 -and
        (Test-LanCurrentSession -Root $root -Adapter $Adapter)) { $result = 0 }
    if ($AuthMode -eq 'WindowsCurrent' -and -not $credentials -and ($result -eq 5 -or $result -eq 1219)) {
        $sameAccount = Get-LanCurrentHostAccount -Root $root -Adapter $Adapter
        if ($sameAccount) { $result = & $Adapter.Connect $root $null $false $false $sameAccount '' }
    }
    # A Protected share meets the same 1219 as Map Drive when Windows already holds a session to this
    # host as somebody else, so it needs the same recovery. Without it the user saw "Windows already
    # has a connection to this computer with different credentials" and had no way forward.
    if ([int]$result -eq 1219 -and $credentials) {
        $result = Clear-LanConflictingSession -Root $root -Adapter $Adapter -Persistent $false `
            -Prompt ($AuthMode -eq 'Protected') -UserName $userName -Password $password -Retry {
                param($r,$l,$p,$prompt,$u,$pw)
                & $Adapter.Connect $r $l $p $prompt $u $pw
            }
    }
    # The same explanation as the Map Drive path: this is the button that shows the error the user
    # reported, so it must say what to do rather than only what Windows did.
    $hint = if ([int]$result -eq 1272) {
        Get-LanWindowsCurrentHint -Root $root -HostAccountGiven (-not [string]::IsNullOrWhiteSpace($WindowsAccount)) -Adapter $Adapter
    } else { '' }
    if ([int]$result -ne 0) { Throw-LanWNetError ([int]$result) -Hint $hint }
    try {
        Assert-LanClientSession -Root $root -AuthMode $AuthMode -Adapter $Adapter
        if ($WindowsAccount -and $AuthMode -eq 'WindowsCurrent' -and
            [string](& $Adapter.GetSession $root) -ine [string]$credentials.UserName) { throw 'SMB connected with a different Windows account.' }
        Assert-LanClientPathReadable -Path $full -ConnectionName $root -Adapter $Adapter
    } catch {
        if ($_.Exception.Message -match 'fell back to Guest') {
            throw ($_.Exception.Message + (Get-LanWindowsCurrentHint -Root $root -HostAccountGiven (-not [string]::IsNullOrWhiteSpace($WindowsAccount)) -Adapter $Adapter))
        }
        # "Connected but denied" needs to say which account to use.
        #
        # SMB accepted the account, so the password and the account are real — the folder on the sharing machine
        # simply does not grant it. That happens when the share was made with a different account than the one
        # Windows now accepts for that server, and nothing in "the shared path cannot be read" tells the user
        # what to change. The other accounts this program made are listed instead, so the right one can be
        # pasted rather than guessed.
        if ($_.Exception.Message -match 'cannot be read' -or $_.Exception.Message -match 'ถูกปฏิเสธ') {
            $others = @(Get-LanHostShareAccounts | Where-Object { $_.UserName -ine ($userName -replace '^[^\\]+\\','') })
            $extra = if ($others.Count -eq 1) {
                " เครื่องผู้แชร์มีบัญชี '" + $others[0].UserName + "' — ลองคัดลอกข้อมูลเข้าใช้ของแชร์นั้นมาวางใหม่อีกครั้ง"
            } elseif ($others.Count -gt 1) {
                " เครื่องผู้แชร์มีบัญชีอื่นอีก: " + (($others | ForEach-Object { $_.UserName }) -join ', ')
            } else {
                ' ตรวจว่าแชร์บนเครื่องผู้แชร์ถูกสร้างด้วยบัญชีนี้จริง (แชร์ที่สร้างด้วยบัญชีอื่นจะอ่านไม่ได้)'
            }
            throw ($_.Exception.Message + $extra)
        }
        throw
    }
    $entry = [pscustomobject]@{
        Letter=''; ConnectionKind='Unc'; Unc=$root; Path=$full; Persistent=$false
        AuthMode=$AuthMode; WindowsAccount=$(if ($credentials) { [string]$credentials.UserName } else { '' })
        HostName=$root.Substring(2).Split('\')[0]; SavedAt=[DateTime]::UtcNow.ToString('o'); Watching=$true
    }
    if ($onlineTarget) {
        $entry | Add-Member Transport 'NetBird'
        $entry | Add-Member OnlinePeerIdentity $onlineTarget.OnlinePeerIdentity
        $entry | Add-Member OnlineBinding $onlineTarget.OnlineBinding
    }
    $result = Save-LanClientConnection -Entry $entry -Adapter $Adapter -Credentials $credentials
    & $Adapter.LaunchExplorer $full | Out-Null
    return $result
}

function New-LanClientAdapter {
    $auth = New-LanAuthAdapter
    $launcher = Join-Path (Split-Path -Parent $PSScriptRoot) 'LanShare.ps1'
    # The moment this client started. Nothing is removed from the drive list during the settling period after
    # it, because that is when both machines and the network are still coming up and an unreachable share is
    # normal rather than a sign that it was stopped.
    if (-not $script:LanClientStartedAt) { $script:LanClientStartedAt = Get-Date }
    # The closure below has to reach this adapter, so the adapter is stored in a script-scoped
    # variable. GetNewClosure is NOT usable here: it captures the value each variable holds when the
    # scriptblock is created, so anything still being built inside the hashtable literal stays $null
    # forever. That produced "Cannot bind argument to parameter 'Adapter' because it is null" and
    # made every button on the client tab look like it did nothing.
    $script:LanClientAdapter = @{
        GetOnlineStatus={ Get-LanClientOnlineStatus }
        # The remembered account for a host is what lets a return visit need no typing at all.
        GetRememberedCredential = { param($hostName,$context) if(-not $context){$context=$script:LanClientAdapter}; Get-LanRememberedCredential -HostName $hostName -Adapter $context }
        RestoreGuest = {
            param($statePath)
            if (-not (Test-Path -LiteralPath $statePath)) { return }
            $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $launcher + '" -RestoreGuestClient'
            $child = Start-Process -FilePath powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            if ($child.ExitCode -ne 0) { throw 'Could not restore Guest client policy; use the Restore Guest button.' }
        }.GetNewClosure()
        GetOccupiedLetters = {
            return @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0,1) })
        }
        GetCurrentIdentityName = { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        GetLocalComputerName = { return $env:COMPUTERNAME }
        GetBlankPasswordAccount = {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $parts = $identity.Split('\')
            if ($parts.Length -ne 2 -or $parts[0] -ine $env:COMPUTERNAME) { return $null }
            $token = [IntPtr]::Zero
            try {
                if ([LanBlankPasswordNative]::LogonUser($parts[1], $parts[0], '', 2, 0, [ref]$token)) {
                    return $parts[1]
                }
                return $null
            } finally {
                if ($token -ne [IntPtr]::Zero) { [LanBlankPasswordNative]::CloseHandle($token) | Out-Null }
            }
        }
        Connect = {
            param($unc,$local,$persistent,$prompt,$userName,$password)
            $resource = New-Object LanWNetNative+NetResource
            $resource.Type = 1
            $resource.LocalName = if ($local) { "$local`:" } else { $null }
            $resource.RemoteName = $unc
            $flags = 0
            if ($persistent) { $flags = $flags -bor 1 }
            # CONNECT_INTERACTIVE (8) and CONNECT_PROMPT (16) are only requested when there is no
            # credential to send. Asking Windows to prompt while this program already holds the password
            # is what produced the "Enter network credentials" dialog on every restart.
            if ($prompt -and -not $userName) { $flags = $flags -bor 8 -bor 16 }
            return [LanWNetNative]::Add([ref]$resource,$password,$userName,$flags)
        }
        Disconnect = {
            param($local,$update,$force)
            $flags = if ($update) { 1 } else { 0 }
            return [LanWNetNative]::Cancel("$local`:",$flags,[bool]$force)
        }
        GetMapping = {
            param($local)
            $buffer = New-Object Text.StringBuilder 1024
            $size = 1024
            $code = [LanWNetNative]::GetConnection("$local`:",$buffer,[ref]$size)
            if ($code -in @(0,1201) -and $buffer.ToString().StartsWith('\\')) { return $buffer.ToString() }
            return $null
        }
        GetSession = {
            param($connectionName)
            return Get-LanWNetUser -Name $connectionName
        }
        ProbeAccess = {
            param($path)
            $attributes = [IO.File]::GetAttributes($path)
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $enumerator = [IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
                try { [void]$enumerator.MoveNext() }
                finally { $enumerator.Dispose() }
            } else {
                $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
                $stream.Dispose()
            }
        }
        LaunchExplorer = { param($path) Start-Process -FilePath explorer.exe -ArgumentList ('"' + $path + '"') | Out-Null }
        GetGuestPolicy = $auth.GetGuestPolicy
        ApplyGuestChange = $auth.ApplyGuestChange
    }
    # The script-scoped variable above is already the adapter being returned.
    return $script:LanClientAdapter
}
