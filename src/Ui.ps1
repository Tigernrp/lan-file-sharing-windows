. (Join-Path $PSScriptRoot 'OnlineUi.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'ModernUi.ps1')
. (Join-Path $PSScriptRoot 'RememberedUi.ps1')

if (-not ('LanTaskbarIdentityNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct LanPropertyKey {
    public Guid FormatId;
    public uint PropertyId;
    public LanPropertyKey(uint id) {
        FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        PropertyId = id;
    }
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct LanPropVariant {
    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public IntPtr StringValue;
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ILanPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out LanPropertyKey key);
    [PreserveSig] int GetValue(ref LanPropertyKey key, out LanPropVariant value);
    [PreserveSig] int SetValue(ref LanPropertyKey key, ref LanPropVariant value);
    [PreserveSig] int Commit();
}

public static class LanTaskbarIdentityNative {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr appId);
    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out ILanPropertyStore store);
    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref LanPropVariant value);

    private static ILanPropertyStore Open(IntPtr window) {
        if (window == IntPtr.Zero) throw new ArgumentException("Window handle is required.");
        Guid iid = typeof(ILanPropertyStore).GUID;
        ILanPropertyStore store;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
        return store;
    }

    public static void SetProcess(string appId) {
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appId));
    }

    public static string ReadProcess() {
        IntPtr ptr;
        Marshal.ThrowExceptionForHR(GetCurrentProcessExplicitAppUserModelID(out ptr));
        try { return Marshal.PtrToStringUni(ptr); }
        finally { Marshal.FreeCoTaskMem(ptr); }
    }

    private static void SetString(ILanPropertyStore store, uint id, string text) {
        LanPropertyKey key = new LanPropertyKey(id);
        LanPropVariant value = new LanPropVariant();
        value.Type = 31; // VT_LPWSTR
        value.StringValue = Marshal.StringToCoTaskMemUni(text);
        try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
        finally { Marshal.FreeCoTaskMem(value.StringValue); }
    }

    private static string GetString(ILanPropertyStore store, uint id) {
        LanPropertyKey key = new LanPropertyKey(id);
        LanPropVariant value;
        Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
        try { return value.Type == 31 ? Marshal.PtrToStringUni(value.StringValue) : null; }
        finally { PropVariantClear(ref value); }
    }

    public static void Set(IntPtr window, string appId, string iconPath) {
        if (!File.Exists(iconPath)) throw new FileNotFoundException("Taskbar icon is missing.", iconPath);
        ILanPropertyStore store = Open(window);
        try {
            SetString(store, 3, iconPath + ",0"); // RelaunchIconResource
            SetString(store, 5, appId); // AppUserModel.ID last: notifies the taskbar
            Marshal.ThrowExceptionForHR(store.Commit());
        } finally { Marshal.ReleaseComObject(store); }
    }

    public static string[] Read(IntPtr window) {
        ILanPropertyStore store = Open(window);
        try { return new string[] { GetString(store, 5), GetString(store, 3) }; }
        finally { Marshal.ReleaseComObject(store); }
    }

}
'@
}

function Set-LanTaskbarIdentity {
    param([Parameter(Mandatory)][Windows.Forms.Form]$Form)
    $root=Split-Path -Parent $PSScriptRoot
    $icon=Join-Path $root 'icon/Tiger_Tech_Share_File.ico'
    if ([IO.File]::Exists($icon)) {
        [LanTaskbarIdentityNative]::Set($Form.Handle,'TigerTech.LanFileSharing',$icon)
    }
}

function Get-LanUiIcon {
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) 'icon/Tiger_Tech_Share_File.ico'
    if (-not [IO.File]::Exists($path)) { return $null }
    $stream=[IO.File]::OpenRead($path)
    try {
        $source=[Drawing.Icon]::new($stream)
        try { return [Drawing.Icon]$source.Clone() }
        finally { $source.Dispose() }
    } finally { $stream.Dispose() }
}

function Set-LanFormIcon {
    param([Parameter(Mandatory)][Windows.Forms.Form]$Form)
    $icon=Get-LanUiIcon
    if ($icon) {
        $Form.Icon=$icon
        $Form.Add_Disposed({ $icon.Dispose() }.GetNewClosure())
    }
}

function Get-LanTaskbarWindowProperties {
    param([Parameter(Mandatory)][Windows.Forms.Form]$Form)
    $values=[LanTaskbarIdentityNative]::Read($Form.Handle)
    return [pscustomobject]@{AppId=$values[0];IconResource=$values[1]}
}

function Write-LanUiLog {
    # Records why the window started, was already running, or stopped. Logging must never stop
    # the application, so every failure here is swallowed. Event handlers write the same file
    # with plain file calls instead of calling this, because a call from inside a handler is not
    # reliably resolved.
    param([Parameter(Mandatory)][string]$Message)
    try {
        $directory = Join-Path $env:LOCALAPPDATA 'LanFileSharing'
        if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
        [IO.File]::AppendAllText((Join-Path $directory 'launcher.log'),
            ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ui: ' + $Message + "`r`n"), [Text.Encoding]::UTF8)
    } catch { }
}

function Add-LanUiLabel {
    param($Form,[string]$Text,[int]$X,[int]$Y,[int]$Width=140)
    $label = New-Object Windows.Forms.Label
    $label.Text=$Text; $label.Location=[Drawing.Point]::new($X,$Y); $label.Size=[Drawing.Size]::new($Width,24)
    $Form.Controls.Add($label)
    return $label
}

function Add-LanUiTextBox {
    param($Form,[int]$X,[int]$Y,[int]$Width)
    $box = New-Object Windows.Forms.TextBox
    $box.Location=[Drawing.Point]::new($X,$Y); $box.Size=[Drawing.Size]::new($Width,26)
    $Form.Controls.Add($box)
    return $box
}

function Set-LanUiPlaceholder {
    # Shows grey hint text in an empty text box.
    #
    # The TextBox.PlaceholderText property does not exist on the .NET Framework this program runs on
    # (4.0.30319), so the hint is drawn and cleared through the focus events instead. The hint is never a
    # value: it is removed before anything reads the box, so a user who presses Map Drive without typing
    # gets a real "enter a path" answer rather than a connection attempt against sample text.
    param([Parameter(Mandatory)]$Box,
          [Parameter(Mandatory)][string]$Text)
    $Box.ForeColor = [Drawing.Color]::Gray
    $Box.Text = $Text
    $Box.Add_GotFocus({
        if ($Box.ForeColor -eq [Drawing.Color]::Gray) {
            $Box.Text = ''
            $Box.ForeColor = [Drawing.Color]::Black
        }
    }.GetNewClosure())
    $Box.Add_LostFocus({
        if (-not $Box.Text.Trim()) {
            $Box.ForeColor = [Drawing.Color]::Gray
            $Box.Text = $Text
        }
    }.GetNewClosure())
    # The value a caller should send: empty while the hint is still showing.
    $Box.Tag = $Text
    return $Box
}

function Get-LanUiText {
    # Reads a text box, treating the grey hint as empty.
    param($Box)
    if (-not $Box) { return '' }
    if ($Box.ForeColor -eq [Drawing.Color]::Gray -and [string]$Box.Tag -and $Box.Text -eq [string]$Box.Tag) { return '' }
    return ([string]$Box.Text).Trim()
}

function Add-LanUiButton {
    param($Form,[string]$Text,[int]$X,[int]$Y,[int]$Width=115)
    $button = New-Object Windows.Forms.Button
    $button.Text=$Text; $button.Location=[Drawing.Point]::new($X,$Y); $button.Size=[Drawing.Size]::new($Width,31)
    $Form.Controls.Add($button)
    return $button
}

function Add-LanUiCombo {
    param($Form,[string[]]$Choices,[int]$X,[int]$Y,[int]$Width=180)
    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Location=[Drawing.Point]::new($X,$Y); $combo.Size=[Drawing.Size]::new($Width,26)
    [void]$combo.Items.AddRange([object[]]$Choices)
    if ($Choices.Count -gt 0) { $combo.SelectedIndex=0 }
    $Form.Controls.Add($combo)
    return $combo
}

function ConvertTo-LanAuthMode {
    param([Parameter(Mandatory)][string]$Label)
    switch ($Label) {
        'WindowsCurrent' { return 'WindowsCurrent' }
        'Protected Password' { return 'Protected' }
        'Guest' { return 'Guest' }
        default { throw "Unknown access method: $Label" }
    }
}

function ConvertTo-LanAuthLabel {
    param([string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Mode)) { return 'Unknown' }
    if ($Mode -eq 'Protected') { return 'Protected Password' }
    return $Mode
}

function Get-LanHostProtectedPassword {
    param([Parameter(Mandatory)][hashtable]$Ui)
    if ($Ui.Auth.Text -ne 'Protected Password') { return $null }
    $password = [string]$Ui.PasswordInput.Text
    if ([string]::IsNullOrWhiteSpace($password)) { throw 'Password is required for Protected Password.' }
    if ($password.Length -gt 127) { throw 'Protected Password cannot exceed 127 characters.' }
    return $password
}

function Update-LanHostPasswordControls {
    param([Parameter(Mandatory)][hashtable]$Ui)
    $protected = $Ui.Auth.Text -eq 'Protected Password'
    foreach ($control in @($Ui.PasswordLabel,$Ui.PasswordMethod,$Ui.PasswordInput,$Ui.RegeneratePassword,$Ui.ShowPassword)) {
        $control.Visible = $protected
    }
    $windowsCurrent = $Ui.Auth.Text -eq 'WindowsCurrent'
    $Ui.PrincipalsLabel.Visible = $windowsCurrent
    $Ui.Principals.Visible = $windowsCurrent
    # The blank-password policy buttons only apply to WindowsCurrent sharing.
    if ($Ui.BlankPasswordEnable) { $Ui.BlankPasswordEnable.Visible = $windowsCurrent }
    if ($Ui.BlankPasswordRestore) { $Ui.BlankPasswordRestore.Visible = $windowsCurrent }
    $manual = $Ui.PasswordMethod.Text -eq 'กำหนดเอง'
    $Ui.PasswordInput.ReadOnly = -not $manual
    $Ui.PasswordInput.UseSystemPasswordChar = $manual
    $Ui.RegeneratePassword.Enabled = -not $manual
    $Ui.ShowPassword.Text = if ($manual) { 'แสดง' } else { 'ซ่อน' }
}

function Get-LanHostStatePath {
    return Join-Path (Join-Path $env:ProgramData 'LanFileSharing') 'state.json'
}

function Assert-LanHostCreateFields {
    param([Parameter(Mandatory)][hashtable]$Ui)
    if ([string]::IsNullOrWhiteSpace([string]$Ui.Path.Text)) {
        $Ui.Path.Focus() | Out-Null
        throw 'กรุณาเลือก Drive / Folder / File ที่ต้องการแชร์ก่อน'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Ui.Name.Text)) {
        $Ui.Name.Focus() | Out-Null
        throw 'กรุณากรอกชื่อ Share ก่อนเริ่มแชร์'
    }
}

function Sync-LanUiKindForPath {
    param([Parameter(Mandatory)][hashtable]$Ui)
    if ($Ui.Kind.Text -ne 'Drive' -or [string]::IsNullOrWhiteSpace([string]$Ui.Path.Text)) { return }
    $full=[IO.Path]::GetFullPath([string]$Ui.Path.Text)
    $root=[IO.Path]::GetPathRoot($full)
    if ($root -and -not $root.StartsWith('\\') -and
        -not [string]::Equals($full.TrimEnd('\'),$root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
        $Ui.Kind.SelectedItem='Folder'
        $Ui.Status.Text='พาธที่เลือกเป็นโฟลเดอร์ย่อย โปรแกรมเปลี่ยนชนิดที่แชร์เป็น Folder แล้ว'
        return
    }
    # Sharing a whole drive means walking every file on it before the share appears, which can take
    # many minutes. Say so before Start Share is pressed, so the wait is not a surprise.
    try {
        $count = 0
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($root, '*', [IO.SearchOption]::AllDirectories)) {
            $count++
            if ($count -ge 30000) { break }
        }
        $Ui.Progress.Text = if ($count -ge 30000) {
            'ไดรฟ์นี้มีไฟล์มากกว่า 30,000 รายการ การเริ่มแชร์ต้องสแกนสิทธิ์ทั้งหมด อาจใช้เวลาหลายนาที — ความคืบหน้าจะแสดงด้านล่าง'
        } else {
            "ไดรฟ์นี้มี $count รายการ — พร้อมเริ่มแชร์"
        }
    } catch { }
}

function Update-LanHostList {
    param([hashtable]$Ui,[string]$StatePath,[string]$SelectName,$Entries)
    $Ui.RefreshingShares=$true
    $Ui.ShareList.Items.Clear()
    $entries = if ($PSBoundParameters.ContainsKey('Entries')) { @($Entries) }
        elseif ($Ui.UseBridge) { @(Invoke-LanHostRequest -Action List -Payload @{} -Adapter $Ui.BridgeAdapter) }
        else { @((Read-LanState $StatePath).Shares) }
    $invalid = $false
    foreach ($entry in @($entries)) {
        if ($null -eq $entry) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Id) -or [string]::IsNullOrWhiteSpace([string]$entry.Name)) {
            $invalid = $true
            continue
        }
        $row = New-Object Windows.Forms.ListViewItem($entry.Name)
        $authLabel = ConvertTo-LanAuthLabel -Mode $entry.AuthMode
        if ($authLabel -eq 'Unknown') {
            $Ui.Status.Text = "รายการแชร์ $($entry.Name) ไม่มีข้อมูลวิธีเข้าใช้ กรุณาหยุดแชร์แล้วสร้างใหม่"
        }
        foreach ($value in @($entry.Kind,$entry.SourcePath,$entry.Mode,$authLabel,[string]$entry.AutoStart,$entry.Status,"\\$env:COMPUTERNAME\$($entry.Name)")) {
            [void]$row.SubItems.Add([string]$value)
        }
        $row.Tag = $entry.Id
        if ($entry.LastError) {
            $row.ToolTipText = [string]$entry.LastError
            $Ui.Status.Text = "$($entry.Name): $($entry.LastError)"
        }
        [void]$Ui.ShareList.Items.Add($row)
        if ($SelectName -and $entry.Name -eq $SelectName) {
            $row.Selected = $true
            $row.Focused = $true
            $row.EnsureVisible()
        }
    }
    if ($invalid) {
        $Ui.Status.Text = 'พบข้อมูลแชร์เดิมไม่สมบูรณ์ กรุณากดรีเฟรชเพื่อให้โปรแกรมซ่อมรายการที่ว่าง'
    } elseif ($Ui.ShareList.Items.Count -eq 0) {
        $Ui.Status.Text = 'ยังไม่มีรายการแชร์ เลือก Drive / Folder / File แล้วกดเริ่มแชร์'
    } elseif (-not $Ui.Job) {
        $wanted = @($entries | Where-Object { $_.Name -eq $Ui.Name.Text.Trim() -and $_.Status -eq 'Running' -and -not $_.LastError }) | Select-Object -First 1
        if ($wanted) { $Ui.Status.Text = "แชร์พร้อมใช้: \\$env:COMPUTERNAME\$($wanted.Name) (NTFS: $($wanted.NtfsPolicy))" }
    }
    $Ui.LastHostListSignature = ConvertTo-Json -InputObject @($entries) -Depth 8 -Compress
    $Ui.RefreshingShares=$false
}

function Resolve-LanHostOperationOutcome {
    param([hashtable]$Ui,$State)
    $request=$Ui.PendingHostRequest
    if (-not $request -or -not $State) { return @{State='Failed'} }
    if ($Ui.JobMode -eq 'Stop') {
        # Removing a share record precedes some cleanup steps. Only the helper's
        # successful Stop response proves that permissions/policies were restored.
        return @{State='Failed'}
    }
    if ($Ui.JobMode -ne 'Create') { return @{State='Failed'} }
    $match = @($State.Shares | Where-Object {
        $_.Name -eq $request.Name -and (Get-LanCanonicalPath $_.SourcePath) -eq (Get-LanCanonicalPath $request.Path) -and $_.Mode -eq $request.Mode -and
        $_.AuthMode -eq $request.AuthMode -and $_.Status -eq 'Running' -and -not $_.LastError -and
        $_.Id -notin (@($Ui.PreviousHostIds)+@($Ui.PreviousJournalIds))
    }) | Select-Object -First 1
    if ($match) { return @{State='Running';Entry=$match} }
    $pending = @($State.Journal | Where-Object { $_.Name -eq $request.Name -and
        (Get-LanCanonicalPath $_.SourcePath) -eq (Get-LanCanonicalPath $request.Path) -and
        $_.Id -notin @($Ui.PreviousJournalIds) -and (Test-LanActiveJournal $_ -AllowLeaseOnly) })
    if ($pending.Count) { return @{State='Pending'} }
    return @{State='Failed'}
}

function Show-LanHostList {
    param([Parameter(Mandatory)][hashtable]$Ui,[Parameter(Mandatory)][string]$StatePath)
    try { Update-LanHostList -Ui $Ui -StatePath $StatePath }
    catch { $Ui.Status.Text = "โหลดรายการแชร์ไม่สำเร็จ: $($_.Exception.Message)" }
}

function Invoke-LanCopyUnc {
    param(
        [Parameter(Mandatory)][hashtable]$Ui,
        [scriptblock]$SetClipboardText = { param($Text) [Windows.Forms.Clipboard]::SetText($Text) }
    )
    if ($Ui.ShareList.SelectedItems.Count -eq 0) {
        $Ui.Status.Text = 'เลือกรายการแชร์ที่ต้องการคัดลอก UNC ก่อน'
        return
    }
    $row = $Ui.ShareList.SelectedItems[0]
    if ($row.SubItems.Count -lt 8 -or $row.SubItems[6].Text -ne 'Running') {
        $Ui.Status.Text = 'รายการแชร์ที่เลือกยังไม่พร้อมใช้งาน'
        return
    }
    $unc = [string]$row.SubItems[7].Text
    try {
        & $SetClipboardText $unc
        $Ui.Status.Text = "คัดลอก UNC แล้ว: $unc"
    } catch {
        $Ui.Status.Text = "คัดลอก UNC ไม่สำเร็จ: $($_.Exception.Message)"
    }
}

function Format-LanLoginBlock {
    # The whole hand-over in one block, so the sharer copies once and the client pastes once.
    #
    # The labels are kept machine-readable ("ผู้ใช้ :", "รหัสผ่าน :", "UNC :") and the client tab
    # parses exactly these lines. The password therefore travels with the account name, which is what
    # removes the guessing: nobody has to work out which account belongs to which password, or
    # whether the computer name belongs in front of it.
    param([Parameter(Mandatory)][string]$UserName,
          [Parameter(Mandatory)][string]$Password,
          [Parameter(Mandatory)][string]$Unc,
          [string]$Note)
    $lines = @(
        'LAN File Sharing'
        "ผู้ใช้ : $UserName"
        "รหัสผ่าน : $Password"
        "UNC : $Unc"
    )
    if ($Note) { $lines += "หมายเหตุ : $Note" }
    return ($lines -join "`r`n")
}

function Write-LanClientLogSafe {
    # Records a line without ever throwing, and without assuming the logging helper exists.
    #
    # Call sites inside an event handler must use this. A handler that throws again while reporting an
    # earlier failure is what produced the WinForms "Unhandled exception" dialog: the handler called the
    # logging helper in its catch block, and when that helper was not loaded the second failure escaped
    # into the application's event loop. The message is also placed in a file the window can always
    # write, so a missing helper still leaves a trace instead of nothing.
    param([Parameter(Mandatory)][string]$Message)
    try {
        if (Get-Command Add-LanClientLog -ErrorAction SilentlyContinue) { Add-LanClientLog $Message; return }
    } catch { }
    try {
        $path = Join-Path $env:TEMP 'LanFileSharing-client-trace.txt'
        [IO.File]::AppendAllText($path, ((Get-Date -Format 'HH:mm:ss') + '  ' + $Message + "`r`n"), [Text.Encoding]::UTF8)
    } catch { }
}

function Update-LanClientLogPane {
    # Same contract as Update-LanHostLogPane, and separate for the same reason: a WinForms timer only
    # ticks while a message loop runs, so the fill routine must be callable on its own from a test.
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.Log) { return }
    # The reader lives with the writer in Progress.ps1. A timer callback must tolerate it being absent,
    # otherwise the pane's own refresh raises an unhandled WinForms error dialog.
    if (-not (Get-Command Get-LanClientLog -ErrorAction SilentlyContinue)) { return }
    $lines = @(Get-LanClientLog -TailLines 200)
    # $null, never an empty array: an empty array has count 0, so a pane that had already drawn the
    # hint would compare 0 against 0 forever and never pick up the lines written afterwards.
    $known = @($State.LogLines)
    if ($null -ne $State.LogLines -and
        $lines.Count -eq $known.Count -and
        ($lines.Count -eq 0 -or $lines[$lines.Count-1] -eq $known[$known.Count-1])) { return }
    $State.LogLines = $lines
    $State.Log.BeginUpdate()
    try {
        $State.Log.Items.Clear()
        if ($lines.Count -eq 0) {
            $hint = New-Object Windows.Forms.ListViewItem('')
            $hint.ForeColor=[Drawing.Color]::Gray
            [void]$hint.SubItems.Add('ยังไม่มีบันทึก — กด "เปิด UNC" หรือ "Map Drive" แล้วความคืบหน้าจะแสดงที่นี่แบบเรียลไทม์')
            [void]$State.Log.Items.Add($hint)
        } else {
            foreach ($line in $lines) {
                $text = [string]$line
                $split = $text.IndexOf('  ')
                $row = if ($split -gt 0) { New-Object Windows.Forms.ListViewItem($text.Substring(0,$split)) }
                       else { New-Object Windows.Forms.ListViewItem('') }
                [void]$row.SubItems.Add($(if ($split -gt 0) { $text.Substring($split).Trim() } else { $text }))
                [void]$State.Log.Items.Add($row)
            }
            if ($State.Log.Items.Count -gt 0) { $State.Log.EnsureVisible($State.Log.Items.Count - 1) }
        }
    } finally { $State.Log.EndUpdate() }
}

function Invoke-LanCopyLogin {
    param(
        [Parameter(Mandatory)][hashtable]$Ui,
        # The state path is resolved here when the caller has none, so reading the state never depends
        # on a value captured by a closure. That dependency produced "ไม่พบบันทึกข้อมูลแชร์นี้ในสถานะ
        # ของโปรแกรม" while the record was present, because the captured $statePath was null.
        [string]$StatePath,
        [scriptblock]$SetClipboardText = { param($Text) [Windows.Forms.Clipboard]::SetText($Text) },
        [scriptblock]$ReadState,
        [scriptblock]$Unprotect = { param($c) Unprotect-LanSecret -CipherText $c },
        [switch]$Online
    )
    if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Get-LanHostStatePath }
    if (-not $ReadState) { $ReadState = { param($p) Read-LanState -Path $p } }
    if ($Ui.ShareList.Items.Count -eq 0) {
        $Ui.Status.Text = 'ยังไม่มีรายการแชร์ให้คัดลอกข้อมูลเข้าใช้'
        return
    }
    # A row that is merely present is used when the user has not clicked one yet. With a single share
    # that is the common case, and refusing there was needless friction. A list with several rows
    # still requires a choice, so the wrong account can never be handed over by accident.
    $row = if ($Ui.ShareList.SelectedItems.Count -gt 0) { $Ui.ShareList.SelectedItems[0] }
           elseif ($Ui.ShareList.Items.Count -eq 1) { $Ui.ShareList.Items[0] }
           else {
               $Ui.Status.Text = 'เลือกรายการแชร์ที่ต้องการคัดลอกข้อมูลเข้าใช้ก่อน'
               return
           }
    $name = [string]$row.SubItems[0].Text
    $unc = [string]$row.SubItems[7].Text
    try {
        $shares = @((& $ReadState $StatePath).Shares)
        # The row's own id is used first: it is written by the app itself, so it cannot be affected by
        # a name that was retyped, padded or otherwise altered between the list and the record.
        $entry = if ($row.Tag) { @($shares | Where-Object { $_.Id -eq $row.Tag }) | Select-Object -First 1 }
                 else { $null }
        if (-not $entry) { $entry = @($shares | Where-Object { $_.Name -eq $name }) | Select-Object -First 1 }
        if (-not $entry) {
            # Say what was searched for and what the state holds. A bare "not found" left no way to
            # tell a stale window from a genuinely missing record.
            $available = if ($shares.Count -eq 0) { '(ไม่มีรายการ)' } else { (@($shares | ForEach-Object { $_.Name }) -join ', ') }
            Write-LanClientLogSafe "คัดลอกข้อมูลเข้าใช้: หาไม่พบ name=[$name] id=[$($row.Tag)] path=[$StatePath] มี=[$available]"
            if (-not (Test-Path -LiteralPath $StatePath)) {
                throw "อ่านสถานะของโปรแกรมไม่ได้: ไม่พบไฟล์ $StatePath"
            }
            throw "ไม่พบบันทึกของแชร์ '$name' ในสถานะของโปรแกรม (มี: $available)"
        }
        if ($entry.AuthMode -ne 'Protected') {
            # Only a Protected share carries a stored account and password. Saying so is more useful
            # than copying a block with an empty password the client could never use.
            $Ui.Status.Text = ('แชร์ "{0}" ใช้วิธีเข้าใช้ {1} ซึ่งไม่มีรหัสผ่านให้คัดลอก — ' +
                'ถ้าต้องการแชร์ข้ามเครื่องที่ชื่อบัญชีต่างกัน ให้หยุดแชร์แล้วสร้างใหม่ด้วย Protected Password' -f $name, $entry.AuthMode)
            return
        }
        $cipher = [string]$entry.CredentialInfo.PasswordCipher
        if (-not $cipher) { throw 'ไม่พบรหัสผ่านที่บันทึกไว้สำหรับแชร์นี้' }
        $password = & $Unprotect $cipher
        $user = [string]$entry.CredentialInfo.UserName
        # The account and password exist from the moment the share is created, so they are handed over
        # even while the share is waiting for its network to come back. Refusing in that state — which
        # is what "รายการแชร์ที่เลือกยังไม่พร้อมใช้งาน" did — left the user unable to prepare the other
        # machine at all. The address is the only part the status affects, and the note says so.
        $note = if ([string]$entry.Status -ne 'Running') {
            ('สถานะปัจจุบัน: {0} — ที่อยู่ด้านบนจะใช้งานได้เมื่อเครื่องนี้กลับมาอยู่ในเครือข่ายเดิม ({1}) หรือกดเริ่มแชร์ใหม่' -f `
                $entry.Status, $entry.NetworkProfile.Name)
        } else { $null }
        $block = Format-LanLoginBlock -UserName $user -Password $password -Unc $unc -Note $note
        if($Online){
            if(-not $Ui.GetOnlineStatus){throw 'เปิดแท็บ Online แล้วตรวจสถานะก่อนคัดลอก'}
            $onlineStatus=& $Ui.GetOnlineStatus
            if(-not $onlineStatus){throw 'ตรวจสถานะในแท็บ Online ก่อนคัดลอก'}
            $block=Format-LanOnlineLoginBlock -Entry $entry -OnlineStatus $onlineStatus -Password $password
        }
        # The clipboard is a shared, lockable resource. Another program holding it makes SetText fail
        # with "Access denied", which is not the user's mistake and must not look like a dead button:
        # retry briefly, and fall back to showing the block so it can still be selected by hand.
        $copied = $false
        for ($attempt = 0; $attempt -lt 5 -and -not $copied; $attempt++) {
            try { & $SetClipboardText $block; $copied = $true }
            catch {
                if ($attempt -eq 4) {
                    Write-LanClientLogSafe "คัดลอกข้อมูลเข้าใช้: clipboard ล้มเหลว — $($_.Exception.Message)"
                    $Ui.Status.Text = ('คัดลอกอัตโนมัติไม่สำเร็จเพราะโปรแกรมอื่นกำลังใช้ clipboard อยู่ — ' +
                        'คัดลอกข้อความนี้ด้วยมือได้: ' + ($block -replace "`r`n", ' | '))
                    return
                }
                Start-Sleep -Milliseconds 200
            }
        }
        $Ui.Status.Text = ('คัดลอกข้อมูลเข้าใช้ของ "{0}" แล้ว (สถานะ {1}) — ไปวางที่เครื่องผู้ใช้ในช่อง "วางข้อมูลเข้าใช้ครั้งเดียว" ได้เลย' -f $name, $entry.Status)
    } catch {
        # Report the inner message too: a bare "Access denied" gave no way to tell which step failed.
        $detail = if ($_.Exception.InnerException) { "$($_.Exception.Message) ($($_.Exception.InnerException.Message))" } else { $_.Exception.Message }
        Write-LanClientLogSafe "คัดลอกข้อมูลเข้าใช้ล้มเหลว: $detail"
        $Ui.Status.Text = "คัดลอกข้อมูลเข้าใช้ไม่สำเร็จ: $detail"
    }
}

function Get-LanPaneDiagnostics {
    # One line describing why the pane is empty, so a report from another machine can be read
    # without guessing. The file keeps one line per process instead of growing on every form built.
    param([string]$Extra)
    try {
        $directory = Get-LanProgressDirectory
        $logPath = Get-LanProgressPath -Leaf 'progress.log'
        $parts = @(
            ('time=' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
            ('pid=' + $PID)
            ('user=' + $env:USERNAME)
            ('progressDir=' + $directory)
            ('dirExists=' + [IO.Directory]::Exists($directory))
            ('logExists=' + [IO.File]::Exists($logPath))
            ('logLines=' + @(Get-LanProgressLog -TailLines 200).Count)
            # Record the read result itself. A pane that is empty while the log is growing means the
            # READ failed, and a bare line count cannot tell those apart.
            ('readError=' + $(try {
                $probe = Get-LanProgressLogPath
                if ([IO.File]::Exists($probe)) { [void][IO.File]::ReadAllLines($probe,[Text.Encoding]::UTF8); 'none' } else { 'no-file' }
            } catch { $_.Exception.GetType().Name }))
            ('paneRows=' + $(if ($null -ne $State -and $null -ne $State.Log) { $State.Log.Items.Count } else { 'n/a' }))
            ('policy=' + (Get-ExecutionPolicy))
        )
        if ($Extra) { $parts += ('note=' + $Extra) }
        $text = ($parts -join '  ')
        $out = Join-Path $env:LOCALAPPDATA 'LanFileSharing\pane-diagnostics.txt'
        $parent = [IO.Path]::GetDirectoryName($out)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        # Drop this process's earlier line, keep a few lines from other runs, then add the new one.
        $kept = @()
        if ([IO.File]::Exists($out)) {
            $kept = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue |
                Where-Object { $_ -notlike "*pid=$PID *" } | Select-Object -Last 4)
        }
        [IO.File]::WriteAllLines($out, (@($kept) + @($text)), [Text.Encoding]::UTF8)
        return $text
    } catch { return '(diagnostics unavailable)' }
}

function Update-LanHostLogPane {
    # Fills the host window's progress pane from the files the share operation writes. Extracted
    # from the timer handler so it can be called directly: a WinForms timer only ticks while the
    # application message loop runs, so a test cannot rely on the timer firing.
    param([Parameter(Mandatory)][hashtable]$State)
    $lines = @(Get-LanProgressLog -TailLines 200)
    # $null, never an empty array: the check below compares counts, and an empty array has count 0,
    # so a pane that had already drawn the empty hint would compare 0 against 0 forever and never
    # pick up the lines written afterwards. That is why the pane stayed frozen at the hint even
    # though the log file was growing.
    $known = @($State.LogLines)
    if ($null -eq $State.LogLines -or
        $lines.Count -ne $known.Count -or
        ($lines.Count -gt 0 -and $lines[$lines.Count-1] -ne $known[$known.Count-1])) {
        $State.LogLines = $lines
        $State.Log.BeginUpdate()
        try {
            $State.Log.Items.Clear()
            if ($lines.Count -eq 0) {
                # An empty pane looks broken. Say why it is empty and what to do.
                $hint = New-Object Windows.Forms.ListViewItem('')
                $hint.ForeColor=[Drawing.Color]::Gray
                [void]$hint.SubItems.Add('ยังไม่มีบันทึก — กด "เริ่มแชร์" หรือ "หยุดแชร์ที่เลือก" แล้วความคืบหน้าจะแสดงที่นี่แบบเรียลไทม์')
                [void]$State.Log.Items.Add($hint)
            } else {
                foreach ($line in $lines) {
                    $text = [string]$line
                    $split = $text.IndexOf('  ')
                    $row = if ($split -gt 0) { New-Object Windows.Forms.ListViewItem($text.Substring(0,$split)) }
                           else { New-Object Windows.Forms.ListViewItem('') }
                    [void]$row.SubItems.Add($(if ($split -gt 0) { $text.Substring($split + 2) } else { $text }))
                    [void]$State.Log.Items.Add($row)
                }
                $State.Log.EnsureVisible($State.Log.Items.Count - 1)
            }
        } finally { $State.Log.EndUpdate() }
    }
    $current = Get-LanProgressStatus
    $State.Progress.Text = if ($current) { $current.Time } else { 'พร้อมทำงาน' }
}

function New-LanHostForm {
    param([bool]$WireEvents=$true,[bool]$UseBridge=$false)
    $form = New-Object Windows.Forms.Form
    Set-LanFormIcon -Form $form
    $form.Text=('LAN File Sharing — ผู้แชร์' + (Get-LanVersionSuffix)); $form.Size=[Drawing.Size]::new(950,806)
    $form.MinimumSize=[Drawing.Size]::new(920,700)
    $form.StartPosition=[Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    Add-LanUiLabel $form 'ชนิดที่แชร์' 20 22 | Out-Null
    $kind = Add-LanUiCombo $form @('Drive','Folder','File') 170 18 180
    Add-LanUiLabel $form 'Drive / Folder / File' 20 65 | Out-Null
    $path = Add-LanUiTextBox $form 170 61 590
    $browse = Add-LanUiButton $form 'เลือก...' 775 58 125
    Add-LanUiLabel $form 'ชื่อ Share' 20 108 | Out-Null
    $name = Add-LanUiTextBox $form 170 104 245
    Add-LanUiLabel $form 'สิทธิ์' 445 108 70 | Out-Null
    $mode = Add-LanUiCombo $form @('Read','Modify') 520 104 180
    Add-LanUiLabel $form 'วิธีเข้าใช้' 20 150 | Out-Null
    $auth = Add-LanUiCombo $form @('Protected Password','WindowsCurrent','Guest') 170 146 220
    $principalsLabel = Add-LanUiLabel $form 'บัญชีที่อนุญาต (ว่าง = ทุกบัญชีที่ยืนยันตัวตน)' 410 150 330
    $principals = Add-LanUiTextBox $form 745 146 155
    $passwordLabel = Add-LanUiLabel $form 'รหัสผ่าน' 20 192
    $passwordMethod = Add-LanUiCombo $form @('โปรแกรมสุ่ม','กำหนดเอง') 170 188 180
    $passwordInput = Add-LanUiTextBox $form 365 188 190
    $passwordInput.Text = New-LanProtectedPassword
    $regeneratePassword = Add-LanUiButton $form 'สุ่มใหม่' 562 185 80
    $showPassword = Add-LanUiButton $form 'ซ่อน' 650 185 75
    # The account name, which the owner asked to be able to choose.
    #
    # One account per machine is what makes several shares on it usable at the same time: Windows keeps a
    # single credential per server, so every share on a machine is reached with the same account. The name is
    # therefore a property of the machine, not of one share, and this box sets it for every share created here
    # from now on. The default names the machine, which is far easier to recognise in Windows than a random
    # string, and a name the owner chooses is not against any policy — the account is a local one on their own
    # computer and its password is the part that has to stay strong.
    $accountNameLabel = Add-LanUiLabel $form 'ชื่อบัญชีแชร์ (ต้องเป็นชื่อใหม่ ห้ามซ้ำบัญชี Windows)' 20 231
    $accountName = Add-LanUiTextBox $form 170 227 320
    # The default names the machine, and is cut to the length Windows allows for a local account. A machine
    # called SCHOOL-HOST makes "LanShare_SCHOOL-HOST" twenty-two characters, which Windows refuses, so the
    # default has to be shortened rather than left to fail and fall back to a random name.
    $defaultAccountName = "LanShare_$env:COMPUTERNAME"
    if ($defaultAccountName.Length -gt 20) { $defaultAccountName = $defaultAccountName.Substring(0,20) }
    $accountName.Text = $defaultAccountName
    $reuseAccount = Add-LanUiButton $form 'ใช้บัญชีเดิม' 510 224 130
    $copyOnline=Add-LanUiButton $form 'คัดลอกเข้าใช้ Online' 655 224 245
    $auto = New-Object Windows.Forms.CheckBox
    $auto.Text='แชร์อัตโนมัติเมื่อเปิดเครื่อง'; $auto.Checked=$true
    $auto.Location=[Drawing.Point]::new(170,266); $auto.Size=[Drawing.Size]::new(260,28)
    $form.Controls.Add($auto)
    # Windows blocks network logon for accounts without a password; these two buttons let the
    # sharer allow that for the LAN and put the previous policy back afterwards.
    $blankPasswordEnable = Add-LanUiButton $form 'อนุญาตบัญชีไม่มีรหัสผ่าน LAN' 440 264 300
    $blankPasswordRestore = Add-LanUiButton $form 'คืนค่านโยบายรหัสว่าง' 750 264 220
    $create = Add-LanUiButton $form 'เริ่มแชร์' 20 306 140
    $stop = Add-LanUiButton $form 'หยุดแชร์ที่เลือก' 175 306 160
    $refresh = Add-LanUiButton $form 'รีเฟรช' 350 306 125
    $guestCheck = Add-LanUiButton $form 'ตรวจ Guest' 490 306 150
    $guestConfig = Add-LanUiButton $form 'ตั้งค่า Guest' 490 306 150
    $guestRestore = Add-LanUiButton $form 'คืนค่า Guest' 490 306 150
    $checkShare = Add-LanUiButton $form 'ตรวจแชร์ที่เลือก' 490 306 160
    $copyUnc = Add-LanUiButton $form 'Copy UNC' 680 306 120
    # The one button that makes sharing between different machines easy: it copies the account, the
    # password and the address together, and the client tab understands the block when it is pasted.
    $copyLogin = Add-LanUiButton $form 'คัดลอกข้อมูลเข้าใช้' 805 306 110
    $status = Add-LanUiLabel $form 'พร้อมเลือกข้อมูล โปรแกรมจะตั้งเครือข่าย LAN ที่ใช้อยู่เป็น Private เมื่อเริ่มแชร์' 20 353 880
    $status.AutoSize=$false; $status.Size=[Drawing.Size]::new(880,55)
    $list = New-Object Windows.Forms.ListView
    $list.View=[Windows.Forms.View]::Details; $list.FullRowSelect=$true; $list.MultiSelect=$false; $list.ShowItemToolTips=$true
    $list.Location=[Drawing.Point]::new(20,412); $list.Size=[Drawing.Size]::new(885,158)
    foreach ($column in @(@('ชื่อ',90),@('ชนิด',60),@('ต้นทาง',200),@('สิทธิ์',70),@('เข้าใช้',145),@('เปิดเมื่อบูต',90),@('สถานะ',80),@('UNC',145))) {
        [void]$list.Columns.Add($column[0],[int]$column[1])
    }
    $form.Controls.Add($list)
    # Live log of what the share operation is doing. The work itself runs in the host process,
    # so the window reads the progress files instead of local state.
    Add-LanUiLabel $form 'การทำงานของโปรแกรม (ล่าสุดอยู่ด้านล่าง)' 20 576 880 | Out-Null
    $log = New-Object Windows.Forms.ListView
    $log.View=[Windows.Forms.View]::Details; $log.FullRowSelect=$true; $log.MultiSelect=$false
    $log.HeaderStyle=[Windows.Forms.ColumnHeaderStyle]::Nonclickable
    $log.Location=[Drawing.Point]::new(20,598); $log.Size=[Drawing.Size]::new(885,120)
    $log.Anchor=[Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    [void]$log.Columns.Add('เวลา',80)
    [void]$log.Columns.Add('ขั้นตอน',790)
    $form.Controls.Add($log)
    $ui = @{Kind=$kind;Path=$path;Browse=$browse;Name=$name;Mode=$mode;Auth=$auth;Principals=$principals;PrincipalsLabel=$principalsLabel;
        AutoStart=$auto;Create=$create;Stop=$stop;Refresh=$refresh;GuestCheck=$guestCheck;GuestConfig=$guestConfig;GuestRestore=$guestRestore;CheckShare=$checkShare;CopyUnc=$copyUnc;CopyLogin=$copyLogin;CopyOnline=$copyOnline;Status=$status;
        HostToolButtons=@($guestCheck,$guestConfig,$guestRestore,$checkShare,$blankPasswordEnable,$blankPasswordRestore);
        BlankPasswordEnable=$blankPasswordEnable;BlankPasswordRestore=$blankPasswordRestore;
        # LogLines starts as a one-element sentinel so the first tick always fills the pane: with
        # an empty array the change check compared 0 against 0 and the pane stayed blank.
        ShareList=$list;Log=$log;LogLines=$null;LogTimer=$null;
        PasswordLabel=$passwordLabel;PasswordMethod=$passwordMethod;PasswordInput=$passwordInput;
        AccountNameLabel=$accountNameLabel;AccountName=$accountName;ReuseAccount=$reuseAccount;
        RegeneratePassword=$regeneratePassword;ShowPassword=$showPassword;Job=$null;JobStartedAt=$null;JobMode='Create';LastWaitNoteAt=$null;Root=(Split-Path -Parent $PSScriptRoot);
        HandlingJobResult=$false;CredentialPresenter={param($owner,$text,$title)
            [Windows.Forms.MessageBox]::Show($owner,$text,$title,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        };
        UseBridge=$UseBridge;BridgeAdapter=(New-LanHostBridgeAdapter);LastHostPoll=[DateTime]::MinValue;AwaitingHostOutcome=$false;
        # Runs the Create request off the UI thread so the window keeps responding. A PowerShell
        # background job is NOT used: it starts a plain powershell.exe that does not inherit
        # -ExecutionPolicy Bypass, so on a machine whose policy is Restricted every script the job
        # loads is refused. A helper process started with -ExecutionPolicy Bypass always loads.
        BridgeJobStarter={
            param($root,$payload,$action='Create')
            $stamp = [guid]::NewGuid().ToString('N')
            $helper = Join-Path $env:TEMP ('LanFileSharing-run-' + $stamp + '.ps1')
            $payloadFile = Join-Path $env:TEMP ('LanFileSharing-payload-' + $stamp + '.json')
            $stdoutFile = Join-Path $env:TEMP ('LanFileSharing-stdout-' + $stamp + '.txt')
            $stderrFile = Join-Path $env:TEMP ('LanFileSharing-stderr-' + $stamp + '.txt')
            # The helper writes its own trace here. It must NOT be one of the redirect targets:
            # Start-Process holds those open for the whole run, so writing them fails with
            # "being used by another process" and the helper then reports nothing at all.
            $traceFile = Join-Path $env:TEMP ('LanFileSharing-trace-' + $stamp + '.txt')
            $resultFile = Join-Path $env:TEMP ('LanFileSharing-result-' + $stamp + '.json')
            $utf8 = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($payloadFile, ($payload | ConvertTo-Json -Depth 8 -Compress), $utf8)
            # The helper keeps EVERY path in its own arguments, never as a literal in the body.
            # The installation folder can contain non-ASCII characters (for example a Thai path);
            # a literal would have to survive how this script file is encoded, and PowerShell 5.1
            # decodes a .ps1 without a BOM as ANSI, which corrupts such a path and makes the helper
            # fail to load the modules. Arguments are bound by PowerShell itself, so they are safe.
            # The helper also writes a failure entry before doing anything, so even a crash leaves a
            # readable reason behind.
            $body = @'
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$HostAction,
    [Parameter(Mandatory)][string]$PayloadPath,
    [Parameter(Mandatory)][string]$TracePath,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
# The launcher can inherit module paths from PowerShell 7 or another host.
# This helper runs Windows PowerShell 5.1: resolve its built-in modules first.
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + $env:PSModulePath
$utf8 = New-Object Text.UTF8Encoding($false)
function Add-Trace { param([string]$Text) try { [IO.File]::AppendAllText($TracePath, ((Get-Date -Format 'HH:mm:ss') + '  ' + $Text + "`r`n"), $utf8) } catch { } }
function Set-Result { param($Object) [IO.File]::WriteAllText($ResultPath, ($Object | ConvertTo-Json -Depth 8 -Compress), $utf8) }
Add-Trace 'helper started'
try {
    $policy = try { Get-ExecutionPolicy } catch { 'unavailable' }
    Add-Trace ('policy=' + $policy + '  root=' + $Root + '  action=' + $HostAction)
    try {
        foreach ($module in @('Selection','State','Progress','Online','Auth','SingleFile','Host','InstallLocation','Startup','HostBridge')) {
            . (Join-Path $Root "src/$module.ps1")
        }
        Add-Trace 'modules loaded'
        $request = Get-Content -LiteralPath $PayloadPath -Raw | ConvertFrom-Json
        $fields = @{}
        foreach ($property in $request.PSObject.Properties) { $fields[$property.Name] = $property.Value }
        Add-Trace ('calling host request ' + $HostAction)
        $response = Invoke-LanHostRequest -Action $HostAction -Payload $fields -Adapter (New-LanHostBridgeAdapter)
        Add-Trace ('host request returned: ' + $HostAction)
        $shares = @(Get-LanPublicShares -StatePath (Join-Path $env:ProgramData 'LanFileSharing\state.json'))
        $result = @{ Shares = $shares }
        # Create carries the credential details the window shows; other actions carry only Shares.
        foreach ($name in @('Name','UserName','InitialPassword','NtfsPolicy','Stopped','Summary','Healthy','Supported','CleanupErrors')) {
            if ($response -and $response.PSObject.Properties.Name -contains $name) { $result[$name] = $response.$name }
        }
        Set-Result $result
        Add-Trace 'result written'
    } catch {
        Add-Trace ('FAILED: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
        Add-Trace ('at: ' + $_.InvocationInfo.PositionMessage)
        Set-Result @{ Error = $_.Exception.Message }
    }
} catch {
    Add-Trace ('outer failure: ' + $_.Exception.Message)
    try { Set-Result @{ Error = $_.Exception.Message } } catch { }
}
'@
            # A BOM keeps the helper readable even if it ever needs a non-ASCII character.
            [IO.File]::WriteAllText($helper, $body, (New-Object Text.UTF8Encoding($true)))
            $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"' + $helper + '"'),
                '-Root',('"' + $root + '"'),
                '-HostAction',$action,
                '-PayloadPath',('"' + $payloadFile + '"'),
                '-TracePath',('"' + $traceFile + '"'),
                '-ResultPath',('"' + $resultFile + '"'))
            $process = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -ErrorAction Stop -ArgumentList $arguments
            foreach ($pair in @(@('JobHelperPath',$helper),@('JobPayloadPath',$payloadFile),
                                @('JobOutputPath',$traceFile),@('JobErrorPath',$stderrFile),
                                @('JobStdoutPath',$stdoutFile),@('JobResultPath',$resultFile))) {
                Add-Member -InputObject $process -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
            }
            return $process
        }}
    $form.Tag=$ui
    $progressLabel = Add-LanUiLabel $form 'พร้อมทำงาน' 20 742 880
    $ui.Progress=$progressLabel
    $logTimer = New-Object Windows.Forms.Timer
    $logTimer.Interval=500
    # Read the window state from the form: this closure is built before $ui is assigned, so a
    # captured $ui would stay $null and the pane would never fill.
    $logTimer.Add_Tick({
        # Every branch below is recorded for the first ticks and then once every ten seconds. The
        # pane sat frozen through several fixes because a silent branch and a stopped timer look
        # identical from the outside; this leaves a trail that says which one happened.
        try {
            $script:LanLogTickCount = [int]$script:LanLogTickCount + 1
            $verbose = ($script:LanLogTickCount -le 6) -or ($script:LanLogTickCount % 20 -eq 0)
            if ($verbose) {
                $probe = $form.Tag
                $jobText = 'none'
                if ($probe -and $probe.Job) {
                    $jobText = if ($probe.Job -is [Diagnostics.Process]) { 'proc exited=' + $probe.Job.HasExited } else { 'job ' + $probe.Job.State }
                }
                $tickNote = 'tick#' + $script:LanLogTickCount +
                    ' tag=' + $(if ($null -eq $probe) { 'null' } else { 'set' }) +
                    ' logRows=' + $(if ($null -eq $probe) { 'n/a' } elseif ($null -eq $probe.Log) { 'null' } else { [string]$probe.Log.Items.Count }) +
                    ' fileLines=' + @(Get-LanProgressLog -TailLines 200).Count +
                    ' job=' + $jobText +
                    ' startedAt=' + $(if ($probe -and $probe.JobStartedAt) { 'set' } else { 'NULL' }) +
                    ' waitNote=' + $(if ($probe -and $probe.LastWaitNoteAt) { 'set' } else { 'NULL' }) +
                    ' enabled=' + $(if ($probe -and $probe.LogTimer) { $probe.LogTimer.Enabled } else { 'n/a' })
                Get-LanPaneDiagnostics -Extra $tickNote | Out-Null
            }
        } catch {
            try { Get-LanPaneDiagnostics -Extra ('tick probe failed: ' + $_.Exception.Message) | Out-Null } catch { }
        }
        try {
            $state = $form.Tag
            # Only a window that is really gone stops the timer. A tick that cannot read the pane
            # yet is skipped so the next tick can still fill it: stopping here permanently is how
            # an empty pane used to stay empty forever.
            if ($null -eq $state -or $null -eq $state.Log -or $null -eq $state.Progress) {
                # Report an unreachable pane once in a while: silence here is what made this bug
                # invisible for so long.
                $script:LanLogTickCount = [int]$script:LanLogTickCount + 1
                if ($script:LanLogTickCount % 20 -eq 0) {
                    Get-LanPaneDiagnostics -Extra ('tick: pane not reachable (Log=' + ($null -ne $state) + ')') | Out-Null
                }
                return
            }
            if ($state.Log.IsDisposed -or $state.Progress.IsDisposed) {
                $state.LogTimer.Stop()
                Get-LanPaneDiagnostics -Extra 'tick: pane disposed; log timer stopped' | Out-Null
                return
            }
            Update-LanHostLogPane -State $state
            # A periodic record proves the timer is alive and says how much it drew, which is the
            # one fact missing whenever the pane looks empty.
            $script:LanLogTickCount = [int]$script:LanLogTickCount + 1
            if ($script:LanLogTickCount % 20 -eq 0) {
                Get-LanPaneDiagnostics -Extra ('tick ok: rows=' + $state.Log.Items.Count +
                    ' fileLines=' + @(Get-LanProgressLog -TailLines 200).Count) | Out-Null
            }
        } catch {
            # A failure here must not silently kill the pane: record it and keep ticking.
            try { Get-LanPaneDiagnostics -Extra ('timer error: ' + $_.Exception.Message) | Out-Null } catch { }
        }
    }.GetNewClosure())
    $ui.LogTimer=$logTimer
    $logTimer.Start()
    # Record the state of the log plumbing once per window so a report from another machine says
    # why the pane is empty instead of leaving it to guesswork.
    Get-LanPaneDiagnostics -Extra ('startup hostWindow') | Out-Null
    $updatePasswordControls = ${function:Update-LanHostPasswordControls}
    $newProtectedPassword = ${function:New-LanProtectedPassword}
    $getProtectedPassword = ${function:Get-LanHostProtectedPassword}
    $validateHostFields = ${function:Assert-LanHostCreateFields}
    $syncShareKind = ${function:Sync-LanUiKindForPath}
    $toAuthMode = ${function:ConvertTo-LanAuthMode}
    $protectSecret = ${function:Protect-LanSecret}
    $copySelectedUnc = ${function:Invoke-LanCopyUnc}
    $updateHostList = ${function:Update-LanHostList}
    $showHostList = ${function:Show-LanHostList}
    $findHostAccount = ${function:Find-LanHostShareAccount}
    $ui.StatePath = Get-LanHostStatePath
    $auth.Add_SelectedIndexChanged({ & $updatePasswordControls -Ui $ui }.GetNewClosure())
    $passwordMethod.Add_SelectedIndexChanged({
        if ($ui.PasswordMethod.Text -eq 'กำหนดเอง') { $ui.PasswordInput.Clear() }
        else { $ui.PasswordInput.Text = & $newProtectedPassword }
        & $updatePasswordControls -Ui $ui
    }.GetNewClosure())
    $regeneratePassword.Add_Click({ $ui.PasswordInput.Text = & $newProtectedPassword }.GetNewClosure())
    # Show the account this machine already uses for its shares, so the name can be filled in rather than
    # guessed. Reusing the account is what lets several shares on one machine work at the same time.
    $reuseAccount.Add_Click({
        try {
            # Capture the function before GetNewClosure creates its dynamic module.
            # A bare function name here cannot resolve the application's dot-sourced functions.
            $found = & $findHostAccount -StatePath $ui.StatePath
            if (-not $found) {
                $ui.Status.Text = 'ยังไม่มีบัญชีที่เครื่องนี้ใช้อยู่ — ตั้งชื่อในช่อง "ชื่อบัญชี" ได้เลย แล้วกดเริ่มแชร์'
                return
            }
            $ui.Auth.SelectedItem = 'Protected Password'
            $ui.AccountName.Text = [string]$found.UserName
            if ($found.Password) {
                $ui.PasswordMethod.SelectedItem = 'กำหนดเอง'
                $ui.PasswordInput.UseSystemPasswordChar = $true
                $ui.PasswordInput.Text = [string]$found.Password
            }
            & $updatePasswordControls -Ui $ui
            $ui.Status.Text = ('เติมบัญชีเดิม "{0}" และรหัสผ่านที่บันทึกไว้แล้ว — เลือกข้อมูลและกด "เริ่มแชร์" เพื่อใช้บัญชีนี้' -f $found.UserName)
        } catch { $ui.Status.Text = "ค้นหาบัญชีเดิมไม่สำเร็จ: $($_.Exception.Message)" }
    }.GetNewClosure())
    $showPassword.Add_Click({
        $ui.PasswordInput.UseSystemPasswordChar = -not $ui.PasswordInput.UseSystemPasswordChar
        $ui.ShowPassword.Text = if ($ui.PasswordInput.UseSystemPasswordChar) { 'แสดง' } else { 'ซ่อน' }
    }.GetNewClosure())
    Update-LanHostPasswordControls -Ui $ui
    Set-LanModernHostPage $form
    if (-not $WireEvents) { return $form }
    $statePath = Get-LanHostStatePath
    # Handlers reach the state path through the hashtable they already close over. Referencing the
    # function variable directly does not work: GetNewClosure captures what its own scope holds, so
    # $statePath was $null at click time and "คัดลอกข้อมูลเข้าใช้" reported
    # "ไม่พบบันทึกข้อมูลแชร์นี้ในสถานะของโปรแกรม" even though the record was there.
    $ui.StatePath = $statePath
    $ui.RestoreHostSelection=${function:Restore-LanHostSelection}
    # Reads what the helper process wrote. The helper always leaves a JSON file: either the result
    # object or an "Error" member, so a failure is reported instead of looking like a silent stop.
    $readHelperResult = {
        param([string]$ResultPath,[string]$OutputPath,[string]$ErrorPath)
        # The helper's own trace explains a failure far better than "no result", so it is read
        # first and quoted when nothing else is available.
        # The result is authoritative. Redirected diagnostic streams may still
        # be closing after HasExited and must not turn a valid result into failure.
        if ($ResultPath -and [IO.File]::Exists($ResultPath)) {
            $rawResult = [IO.File]::ReadAllText($ResultPath).Trim()
            if ($rawResult) {
                $parsed = $rawResult | ConvertFrom-Json
                if ($null -eq $parsed) { throw 'helper returned an empty result.' }
                if ($parsed.PSObject.Properties.Name -contains 'Error' -and $parsed.Error) { throw ([string]$parsed.Error) }
                return $parsed
            }
        }
        $trace = ''
        if ($OutputPath -and [IO.File]::Exists($OutputPath)) { try { $trace = ([IO.File]::ReadAllText($OutputPath)).Trim() } catch { } }
        $stderr = ''
        if ($ErrorPath -and [IO.File]::Exists($ErrorPath)) { try { $stderr = ([IO.File]::ReadAllText($ErrorPath)).Trim() } catch { } }
        # Say exactly which evidence was missing. A bare "the helper left no output" hid the fact
        # that the run had already stopped, and sent three rounds of investigation in the wrong
        # direction. The file names are small and let a reader find them directly.
        $reason = if ($trace) { $trace }
                  elseif ($stderr) { $stderr }
                  else { 'ไม่พบไฟล์บันทึกของ helper เลย (helper อาจถูกปิดก่อนเริ่มทำงาน)' }
        $raw = ''
        if ($ResultPath -and [IO.File]::Exists($ResultPath)) { $raw = ([IO.File]::ReadAllText($ResultPath)).Trim() }
        if (-not $raw) {
            # No result file: say what the helper managed to do. The trace names the last step it
            # reached, which is what actually tells the user where the run stopped.
            throw ("แชร์ไม่สำเร็จ — helper หยุดกลางทาง. ขั้นตอนสุดท้าย: " + ($reason -replace "`r?`n", ' | '))
        }
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) { throw 'helper returned an empty result.' }
        if ($parsed.PSObject.Properties.Name -contains 'Error' -and $parsed.Error) {
            throw ([string]$parsed.Error)
        }
        return $parsed
    }.GetNewClosure()
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval=500
    # Keep the operation timer reachable through the form state. This makes lifecycle diagnostics and
    # deterministic tests possible without searching private WinForms event fields.
    $ui.OperationTimer=$timer
    $readHostState=${function:Read-LanState}
    $publicShares=${function:Get-LanPublicShares}
    $resolveOutcome=${function:Resolve-LanHostOperationOutcome}
    $timer.Add_Tick({
        # MessageBox runs a nested Windows message loop. Without this guard, the 500 ms timer
        # re-entered this handler while the first credentials dialog was still open and consumed
        # the same completed helper result repeatedly, producing an unbounded stack of dialogs.
        if ($ui.HandlingJobResult) { return }
        if (-not $ui.Job) {
            if ($ui.UseBridge -and [IO.File]::Exists($ui.StatePath) -and
                ([DateTime]::UtcNow - $ui.LastHostPoll).TotalSeconds -ge 2) {
                $ui.LastHostPoll=[DateTime]::UtcNow
                try {
                    $entries=@(& $publicShares -StatePath $ui.StatePath)
                    $signature=ConvertTo-Json -InputObject $entries -Depth 8 -Compress
                    if ($signature -cne $ui.LastHostListSignature) { & $updateHostList -Ui $ui -StatePath $ui.StatePath -Entries $entries -SelectName $ui.Name.Text.Trim() }
                    if ($ui.AwaitingHostOutcome) {
                        $outcome=& $resolveOutcome $ui (& $readHostState $ui.StatePath)
                        if ($outcome.State -eq 'Running') {
                            & $updateHostList -Ui $ui -StatePath $ui.StatePath -Entries $entries -SelectName $outcome.Entry.Name
                            & $ui.RestoreHostSelection $ui
                            $ui.Status.Text="แชร์พร้อมใช้: \\$env:COMPUTERNAME\$($outcome.Entry.Name)"
                            $ui.AwaitingHostOutcome=$false
                        } elseif ($outcome.State -eq 'Failed') { $ui.Status.Text='งานแชร์สิ้นสุดแล้ว แต่ยังยืนยันความสำเร็จไม่ได้ กรุณาตรวจบันทึก';$ui.AwaitingHostOutcome=$false }
                        if (-not $ui.AwaitingHostOutcome) {
                            $ui.Create.Enabled=$true;$ui.Stop.Enabled=$true
                            foreach($button in $ui.HostToolButtons){$button.Enabled=$true}
                        }
                    }
                } catch { }
            }
            return
        }
        # A helper process (Start-Process) reports through HasExited; a legacy background job
        # reports through State. Both are accepted so an older caller keeps working.
        $isProcess = $ui.Job -is [Diagnostics.Process]
        if ($isProcess) {
            if (-not $ui.Job.HasExited) {
                # Still working: say so, with elapsed time. A large folder can take minutes while
                # the broker walks it, and a status that never changes reads as a frozen program.
                if ($ui.JobStartedAt) {
                    $elapsed = [int]([DateTime]::UtcNow - $ui.JobStartedAt).TotalSeconds
                    $ui.Status.Text = if ($ui.JobMode -eq 'Stop') {
                        "กำลังหยุดแชร์และคืนสิทธิ์ NTFS เดิม... ($elapsed วินาที)"
                    } elseif ($ui.JobMode -eq 'Create') {
                        "กำลังแชร์อยู่... ($elapsed วินาที) ดูความคืบหน้าด้านล่าง"
                    } else { "กำลังตรวจสอบ / ตั้งค่า... ($elapsed วินาที)" }
                    # The helper cannot write progress while it is itself blocked waiting for the
                    # broker, and the broker serves one caller at a time, so those waits produced
                    # no line at all. The window therefore writes its own line every five seconds,
                    # which keeps the log moving whatever the helper happens to be doing.
                    if ($null -eq $ui.LastWaitNoteAt -or ([DateTime]::UtcNow - $ui.LastWaitNoteAt).TotalSeconds -ge 5) {
                        $ui.LastWaitNoteAt = [DateTime]::UtcNow
                        try { Add-LanProgressLog -Message "กำลังดำเนินการ... รอมา $elapsed วินาที (โปรแกรมยังทำงานอยู่)" } catch { }
                    }
                }
                return
            }
        }
        elseif ($ui.Job.State -eq 'Running') { return }
        $ui.HandlingJobResult=$true
        try {
            $result = if ($isProcess) {
                # HasExited can precede completion of redirected output callbacks.
                # The child has already ended; finish draining before reading and cleanup.
                $ui.Job.WaitForExit()
                & $readHelperResult -ResultPath $ui.Job.JobResultPath -OutputPath $ui.Job.JobOutputPath -ErrorPath $ui.Job.JobErrorPath
            } else {
                $value = Receive-Job -Job $ui.Job -ErrorAction Stop
                if ($ui.Job.State -ne 'Completed') { throw 'Share setup did not complete.' }
                $value
            }
            if ($ui.JobMode -notin @('Create','Stop')) {
                if (-not $result.Summary) { throw 'เครื่องมือไม่ส่งผลการทำงานกลับมา' }
                $ui.Status.Text=[string]$result.Summary
                return
            }
            if ($ui.JobMode -eq 'Stop') {
                # The stop runs through this same poll timer, for the same reason Create does:
                # restoring a large folder's permissions takes minutes and the window must stay
                # responsive and keep showing the broker's progress lines while it happens.
                $elapsed = if ($ui.JobStartedAt) { [int]([DateTime]::UtcNow - $ui.JobStartedAt).TotalSeconds } else { 0 }
                if ($result.PSObject.Properties.Name -contains 'Shares') {
                    & $updateHostList -Ui $ui -StatePath $statePath -Entries $result.Shares
                } else {
                    & $updateHostList -Ui $ui -StatePath $statePath
                }
                $ui.Status.Text = if($result.Summary){[string]$result.Summary+" (${elapsed}s)"}else{"หยุดแชร์แล้ว และคืนสิทธิ์เดิมเรียบร้อย (${elapsed}s)"}
                return
            }
            # Report what happened to the folder's existing NTFS permissions, not just the name.
            $ntfs = if ($result.PSObject.Properties.Name -contains 'NtfsPolicy' -and $result.NtfsPolicy) { [string]$result.NtfsPolicy } else { 'Preserved' }
            $elapsed = if ($ui.JobStartedAt) { [int]([DateTime]::UtcNow - $ui.JobStartedAt).TotalSeconds } else { 0 }
            $ui.Status.Text=("แชร์พร้อมใช้: \\$env:COMPUTERNAME\$($result.Name) (NTFS: $ntfs, ${elapsed}s)")
            if ($result.InitialPassword) {
                # Written as the client form asks for it, so the values can be copied straight across.
                # The computer name is included in the user name line because Windows also accepts
                # that form, and it makes clear which machine the account lives on.
                $credentialText = @(
                    'ข้อมูลสำหรับเข้าใช้จากเครื่องอื่น'
                    ''
                    "ชื่อบัญชี : $($result.UserName)"
                    "รหัสผ่าน  : $($result.InitialPassword)"
                    ''
                    "เส้นทาง   : \\$env:COMPUTERNAME\$($result.Name)"
                    ''
                    "ที่เครื่องผู้ใช้ เลือกวิธีเข้าใช้ = Protected Password แล้ววางชื่อบัญชีและรหัสผ่านข้างบน"
                    "ครั้งต่อไปไม่ต้องกรอกอีก เพราะโปรแกรมจำไว้ให้"
                ) -join "`r`n"
                & $ui.CredentialPresenter $form $credentialText 'ข้อมูลเข้าใช้'
                $ui.AccountName.Text=[string]$result.UserName
                $ui.PasswordInput.UseSystemPasswordChar=$true;$ui.ShowPassword.Text='แสดง'
                $ui.PasswordInput.Text=[string]$result.InitialPassword
            }
            # Call through the captured function: a bare call to a module function from inside
            # this handler is not reliably resolved. Show the list the helper returned.
            if ($result.PSObject.Properties.Name -contains 'Shares' -and $result.Shares) {
                & $updateHostList -Ui $ui -StatePath $statePath -SelectName $result.Name -Entries $result.Shares
            } else {
                & $updateHostList -Ui $ui -StatePath $statePath -SelectName $result.Name
            }
            & $ui.RestoreHostSelection $ui
        } catch {
            # The helper can die without leaving a result (the window was closed, the process was
            # stopped). Before reporting a failure, ask the broker whether the share exists: the
            # work may well have completed, and telling the user it failed when it did not is worse
            # than saying nothing.
            $originalError=$_.Exception.Message
            $recovered = $false
            try {
                if (-not [IO.File]::Exists($ui.StatePath)) { throw 'No durable state to reconcile.' }
                $state=& $readHostState $ui.StatePath
                $outcome=& $resolveOutcome $ui $state
                if ($outcome.State -eq 'Running') {
                    $recovered = $true
                    & $updateHostList -Ui $ui -StatePath $statePath -SelectName $outcome.Entry.Name -Entries @($state.Shares)
                    & $ui.RestoreHostSelection $ui
                    $ui.Status.Text = "แชร์พร้อมใช้: \\$env:COMPUTERNAME\$($outcome.Entry.Name)"
                } elseif ($outcome.State -eq 'Stopped') {
                    $recovered=$true
                    & $updateHostList -Ui $ui -StatePath $statePath -Entries @($state.Shares)
                    $ui.Status.Text='หยุดแชร์แล้ว และคืนสิทธิ์เดิมเรียบร้อย'
                } elseif ($outcome.State -eq 'Pending') {
                    $recovered=$true;$ui.AwaitingHostOutcome=$true
                    $ui.Status.Text='งานแชร์ยังทำอยู่ กำลังติดตามผลอัตโนมัติ กรุณารอโดยไม่กดแชร์ซ้ำ'
                }
            } catch { }
            if (-not $recovered) {
                $prefix=if($ui.JobMode -eq 'Stop'){'หยุดแชร์ไม่สำเร็จ'}elseif($ui.JobMode -eq 'Create'){'เริ่มแชร์ไม่สำเร็จ'}else{'เครื่องมือทำงานไม่สำเร็จ'}
                $ui.Status.Text="$prefix`: $originalError"
            }
        }
        finally {
            # Cleanup must never throw: an unhandled error here reached the user as a .NET
            # Framework crash dialog. Every path is checked before it is used.
            try {
                if ($isProcess) {
                    $paths = @($ui.Job.JobResultPath,$ui.Job.JobOutputPath,$ui.Job.JobErrorPath,
                        $ui.Job.JobHelperPath,$ui.Job.JobPayloadPath,$ui.Job.JobStdoutPath) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                    foreach ($path in $paths) {
                        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
                    }
                    try { $ui.Job.Dispose() } catch { }
                } elseif ($ui.Job) { Remove-Job -Job $ui.Job -Force -ErrorAction SilentlyContinue }
            } catch {
                try { Get-LanPaneDiagnostics -Extra ('cleanup error: ' + $_.Exception.Message) | Out-Null } catch { }
            }
            $ui.Job=$null; $ui.JobOutputPath=$null; $ui.JobErrorPath=$null
            $ui.JobHelperPath=$null; $ui.JobPayloadPath=$null; $ui.JobResultPath=$null
            $ui.HandlingJobResult=$false
            $ui.Create.Enabled=(-not $ui.AwaitingHostOutcome); $ui.Stop.Enabled=(-not $ui.AwaitingHostOutcome); $ui.Refresh.Enabled=$true
            foreach($button in $ui.HostToolButtons){$button.Enabled=(-not $ui.AwaitingHostOutcome)}
        }
    }.GetNewClosure())
    $browse.Add_Click({
        if ($ui.Kind.Text -eq 'File') {
            $dialog = New-Object Windows.Forms.OpenFileDialog
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $ui.Path.Text=$dialog.FileName }
        } else {
            $dialog = New-Object Windows.Forms.FolderBrowserDialog
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $ui.Path.Text=$dialog.SelectedPath
                try { & $syncShareKind -Ui $ui } catch { $ui.Status.Text=$_.Exception.Message }
            }
        }
    }.GetNewClosure())
    $path.Add_Leave({ try { & $syncShareKind -Ui $ui } catch { $ui.Status.Text=$_.Exception.Message } }.GetNewClosure())
    $refresh.Add_Click({ try { & $updateHostList -Ui $ui -StatePath $ui.StatePath } catch { $ui.Status.Text=$_.Exception.Message } }.GetNewClosure())
    $copyUnc.Add_Click({ & $copySelectedUnc -Ui $ui }.GetNewClosure())
    # The block travels through the clipboard, so the client tab can fill every field from one paste.
    $copySelectedLogin = ${function:Invoke-LanCopyLogin}
    $copyLogin.Add_Click({ & $copySelectedLogin -Ui $ui -StatePath $ui.StatePath }.GetNewClosure())
    $copyOnline.Add_Click({ & $copySelectedLogin -Ui $ui -StatePath $ui.StatePath -Online }.GetNewClosure())
    $create.Add_Click({
        # One host operation at a time. The broker serves a single caller, so a second request
        # queues behind the first and both appear to hang; two helpers were seen running at once
        # because a second press was accepted while the first was still working.
        if ($ui.Job) {
            $ui.Status.Text='กำลังทำงานอยู่ กรุณารอให้เสร็จก่อนสั่งงานใหม่'
            return
        }
        try {
            & $validateHostFields -Ui $ui
            & $syncShareKind -Ui $ui
        }
        catch { $ui.Status.Text=$_.Exception.Message; return }
        if (-not $ui.UseBridge -and -not (Get-ScheduledTask -TaskName 'LanFileSharing-HostWorker' -ErrorAction SilentlyContinue)) {
            $ui.Status.Text='ต้องติดตั้ง Host Worker ก่อน โดยเรียก Install-LanShare.ps1 แบบผู้ดูแลระบบ'
            return
        }
        try {
            $authMode = & $toAuthMode -Label $ui.Auth.Text
            $password = & $getProtectedPassword -Ui $ui
            $passwordCipher = if (-not $ui.UseBridge -and $password) { & $protectSecret -Text $password } else { $null }
        } catch { $ui.Status.Text=$_.Exception.Message; return }
        $ui.Create.Enabled=$false; $ui.Stop.Enabled=$false; $ui.Refresh.Enabled=$false
        $ui.Status.Text='กำลังตั้งค่าเครือข่ายและสิทธิ์...'
        # Write the first line of the log here, in the window's own process. The elevated host
        # writes every later step, but waiting for it leaves a fresh install looking dead until it
        # produces its first line. This also clears the previous run's log.
        try {
            if (Get-Command Start-LanProgress -ErrorAction SilentlyContinue) {
                Start-LanProgress -Message ("เริ่มแชร์ '{0}' จาก {1}" -f $ui.Name.Text, $ui.Path.Text)
            }
        } catch { }
        $passwordMode = if ($ui.PasswordMethod.Text -eq 'กำหนดเอง') { 'Manual' } else { 'Random' }
        if ($ui.UseBridge) {
            # Run the request in a background job so the window keeps responding, then let the
            # poll timer report the result. A synchronous call here froze the window.
            try {
                $payload = @{Kind=$ui.Kind.Text;Path=$ui.Path.Text;Name=$ui.Name.Text;Mode=$ui.Mode.Text;
                    AuthMode=$authMode;Principals=$ui.Principals.Text;AutoStart=[bool]$ui.AutoStart.Checked;
                    PasswordMethod=$passwordMode;Password=$password;AccountName=$ui.AccountName.Text}
                # Keep only non-secret correlation fields for late completion.
                $ui.PendingHostRequest=@{Name=$payload.Name;Path=$payload.Path;Mode=$payload.Mode;AuthMode=$payload.AuthMode}
                $ui.PreviousHostIds=@($ui.ShareList.Items | ForEach-Object {[string]$_.Tag})
                $ui.PreviousJournalIds=@()
                if([IO.File]::Exists($ui.StatePath)){
                    $before=& $readHostState $ui.StatePath
                    $ui.PreviousHostIds=@($ui.PreviousHostIds)+@($before.Shares | ForEach-Object {$_.Id})
                    $ui.PreviousJournalIds=@($before.Journal | ForEach-Object {$_.Id})
                }
                $ui.Job = & $ui.BridgeJobStarter $ui.Root $payload
                $ui.JobMode = 'Create'
                $ui.JobStartedAt = [DateTime]::UtcNow
                $timer.Start()
            } catch { $ui.Status.Text="เริ่มแชร์ไม่สำเร็จ: $($_.Exception.Message)" }
            if (-not $ui.Job) { $ui.Create.Enabled=$true }
            return
        }
        $values = @($ui.Kind.Text,$ui.Path.Text,$ui.Name.Text,$ui.Mode.Text,$authMode,$ui.Principals.Text,[bool]$ui.AutoStart.Checked,$statePath,$ui.Root,$passwordMode,$passwordCipher)
        $ui.Job = Start-Job -ArgumentList $values -ScriptBlock {
            param($kind,$path,$name,$mode,$auth,$principal,$auto,$statePath,$root,$passwordMode,$passwordCipher)
            $ErrorActionPreference='Stop'
            foreach ($module in @('Selection','State','Online','Auth','SingleFile','Host')) { . (Join-Path $root "src/$module.ps1") }
            $selection = Resolve-LanSelection -Kind $kind -Path $path
            $authAdapter = New-LanAuthAdapter
            $principals = if ($principal) { @($principal.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
            $protectedPassword = if ($passwordCipher) { Unprotect-LanSecret -CipherText $passwordCipher } else { $null }
            $access = Resolve-LanAccess -AuthMode $auth -WindowsPrincipals $principals -ProtectedPasswordMode $passwordMode -ProtectedPassword $protectedPassword -Adapter $authAdapter
            $hostAdapter = New-LanHostAdapter
            Start-LanHostShare -Selection $selection -Name $name -Mode $mode -Access $access -AutoStart $auto -StatePath $statePath -Adapter $hostAdapter
        }
        $timer.Start()
    }.GetNewClosure())
    $stop.Add_Click({
        if ($ui.Job) {
            $ui.Status.Text='กำลังทำงานอยู่ กรุณารอให้เสร็จก่อนสั่งงานใหม่'
            return
        }
        if ($ui.ShareList.SelectedItems.Count -eq 0) { $ui.Status.Text='เลือกรายการที่ต้องการหยุดแชร์'; return }
        try {
            $id = [string]$ui.ShareList.SelectedItems[0].Tag
            if (-not $id) { $ui.Status.Text='รายการที่เลือกไม่มีรหัสแชร์ กรุณากดรีเฟรชแล้วเลือกใหม่'; return }
            $ui.Create.Enabled=$false; $ui.Stop.Enabled=$false; $ui.Refresh.Enabled=$false
            $ui.Status.Text='กำลังหยุดแชร์และคืนสิทธิ์ NTFS เดิม...'
            # Run the stop through the same helper process the Create button uses. Calling the broker
            # directly would block this window for the whole permission restore — minutes on a large
            # folder — and the pane would sit on its first line the entire time.
            $ui.Job = & $ui.BridgeJobStarter $ui.Root @{Id=$id} 'Stop'
            $ui.PendingHostRequest=@{Id=$id}
            $ui.JobMode = 'Stop'
            $ui.JobStartedAt = [DateTime]::UtcNow
            $ui.LastWaitNoteAt = $null
            $ui.Status.Text='กำลังหยุดแชร์และคืนสิทธิ์ NTFS เดิม...'
            if (-not $ui.Job) { throw 'เริ่มคำสั่งหยุดแชร์ไม่สำเร็จ' }
            $timer.Start()
        } catch { $ui.Status.Text="หยุดแชร์ไม่สำเร็จ: $($_.Exception.Message)" }
    }.GetNewClosure())
    $startHostTool={
        param([string]$action,$payload=@{})
        if($ui.Job -or $ui.AwaitingHostOutcome){$ui.Status.Text='มีงานกำลังทำอยู่ กรุณารอให้เสร็จก่อน';return}
        try {
            $ui.PendingHostRequest=$null
            $ui.Job=& $ui.BridgeJobStarter $ui.Root $payload $action
            if(-not $ui.Job){throw 'เริ่มเครื่องมือไม่สำเร็จ'}
            $ui.JobMode=$action;$ui.JobStartedAt=[DateTime]::UtcNow;$ui.LastWaitNoteAt=$null
            $ui.Create.Enabled=$false;$ui.Stop.Enabled=$false
            foreach($button in $ui.HostToolButtons){$button.Enabled=$false}
            $ui.Status.Text='กำลังตรวจสอบ / ตั้งค่า...';$timer.Start()
        }catch{$ui.Status.Text=$_.Exception.Message}
    }.GetNewClosure()
    $guestCheck.Add_Click({& $startHostTool CheckGuest @{}}.GetNewClosure())
    $guestConfig.Add_Click({& $startHostTool ConfigureGuest @{}}.GetNewClosure())
    $guestRestore.Add_Click({& $startHostTool RestoreGuest @{}}.GetNewClosure())
    $blankPasswordEnable.Add_Click({& $startHostTool EnableBlankPassword @{}}.GetNewClosure())
    $blankPasswordRestore.Add_Click({& $startHostTool RestoreBlankPassword @{}}.GetNewClosure())
    $checkShare.Add_Click({
        if($ui.ShareList.SelectedItems.Count -eq 0){$ui.Status.Text='เลือกรายการแชร์ที่จะตรวจก่อน';return}
        & $startHostTool CheckShare @{Id=[string]$ui.ShareList.SelectedItems[0].Tag}
    }.GetNewClosure())
    $restoreHostSelection=${function:Restore-LanHostSelection}
    $list.Add_SelectedIndexChanged({
        if($ui.RefreshingShares -or $ui.RestoringHostSelection){return}
        try{$ui.RestoringHostSelection=$true;& $restoreHostSelection $ui}
        catch{$ui.Status.Text='เรียกคืนค่าผู้แชร์ไม่สำเร็จ: '+$_.Exception.Message}
        finally{$ui.RestoringHostSelection=$false}
    }.GetNewClosure())
    $form.Add_Shown({
        $timer.Start()
        & $showHostList -Ui $ui -StatePath $ui.StatePath
        try{$ui.RestoringHostSelection=$true;& $restoreHostSelection $ui -Initial}
        catch{$ui.Status.Text='เรียกคืนค่าผู้แชร์ไม่สำเร็จ: '+$_.Exception.Message}
        finally{$ui.RestoringHostSelection=$false}
    }.GetNewClosure())
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); if ($logTimer) { $logTimer.Stop(); $logTimer.Dispose() } }.GetNewClosure())
    return $form
}

function Update-LanClientMapList {
    # Refreshes the saved-drive list.
    #
    # Nothing is removed here because a share could not be reached. The program's job is to keep connecting a
    # watched drive until it succeeds — through restarts, network changes and machines that are not ready yet —
    # so an unreachable share is a drive to keep trying, not one to delete. Only a record Windows no longer
    # holds at all is dropped, and only the owner stops watching a drive, with the button provided for that.
    param([hashtable]$Ui,[hashtable]$Adapter)
    $Ui.Adapter=$Adapter
    try {
        # The cleanup is skipped when the caller supplies its own mapping source, so a window built by a test
        # does not act on the real machine's drives.
        if (-not $Adapter.SkipLivenessCheck) { [void](Remove-LanStaleMappings -Adapter $Adapter) }
    } catch { }
    $key=''
    if($Ui.CurrentMap){$target=if(-not $Ui.CurrentMap.Letter -and $Ui.CurrentMap.Path){[string]$Ui.CurrentMap.Path}else{[string]$Ui.CurrentMap.Unc};$key=[string]$Ui.CurrentMap.Letter+'|'+$target}
    else{try{$key=[string](Get-LanUiPreferences $Ui).LastClientConnectionKey}catch{$Ui.Status.Text=$_.Exception.Message}}
    $Ui.RefreshingConnections=$true
    $Ui.SavedMaps.Items.Clear()
    $Ui.MapEntries = @(Read-LanClientMappings (Get-LanClientStatePath $Adapter))
    foreach ($entry in $Ui.MapEntries) {
        # The watching state is part of the label: the user has to be able to tell at a glance which drives the
        # program is still working on and which ones they have taken off automatic checking.
        $watched = Test-LanMappingWatched -Entry $entry
        $suffix = if ($watched) { '' } else { '   (หยุดตรวจ)' }
        $prefix=if($entry.Letter){[string]$entry.Letter+':'}else{'UNC'}
        $target=if(-not $entry.Letter -and $entry.Path){[string]$entry.Path}else{[string]$entry.Unc}
        [void]$Ui.SavedMaps.Items.Add("$prefix  $target$suffix")
    }
    $index=-1
    for($n=0;$n -lt $Ui.MapEntries.Count;$n++){
        $item=$Ui.MapEntries[$n];$target=if(-not $item.Letter -and $item.Path){[string]$item.Path}else{[string]$item.Unc}
        if(([string]$item.Letter+'|'+$target) -eq $key){$index=$n;break}
    }
    if($index -lt 0 -and $Ui.MapEntries.Count -gt 0){
        $latest=$Ui.MapEntries|Sort-Object SavedAt|Select-Object -Last 1
        $index=[array]::IndexOf($Ui.MapEntries,$latest)
    }
    if($index -ge 0){$Ui.SavedMaps.SelectedIndex=$index}
    $Ui.RefreshingConnections=$false
    $Ui.CurrentMap=if($index -ge 0){$Ui.MapEntries[$index]}else{$null}
    if(-not $Ui.ClientFieldsRestored -and $index -ge 0 -and [string]::IsNullOrWhiteSpace($Ui.Unc.Text)){Restore-LanClientFields $Ui $Ui.MapEntries[$index]}
}

function Format-LanOnlineLoginBlock {
    param($Entry,$OnlineStatus,[string]$Password,[string]$ComputerName=$env:COMPUTERNAME)
    if ($Entry.AuthMode -ne 'Protected' -or -not $OnlineStatus.OnlineEnabled -or $OnlineStatus.ConnectionState -ne 'Connected' -or -not $OnlineStatus.InterfaceId) { throw 'Online sharing requires a ready NetBird connection and Protected Password.' }
    $user=$ComputerName+'\'+[string]$Entry.CredentialInfo.UserName
    $unc='\\'+$OnlineStatus.LocalAddress+'\'+$Entry.Name
    return (Format-LanLoginBlock -UserName $user -Password $Password -Unc $unc) + "`r`nOnlinePeer : " + $OnlineStatus.LocalPeerIdentity
}

function ConvertFrom-LanLoginBlock {
    # Reads the block written by "คัดลอกข้อมูลเข้าใช้" on the sharing machine. Returns $null when the
    # text is an ordinary path, so the UNC field keeps working exactly as before.
    #
    # This is the whole point of the block: the client pastes once and never has to decide which
    # account belongs to which password, or whether the computer name belongs in front of the
    # account name. Anything unparseable is reported rather than silently ignored.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value = $Text.Trim()
    if ($value -notmatch '(?m)^\s*(ผู้ใช้|รหัสผ่าน|UNC)\s*:') { return $null }
    $result = [ordered]@{ UserName=$null; Password=$null; Unc=$null;OnlinePeerIdentity=$null }
    foreach ($line in ($value -split "`r?`n")) {
        if ($line -match '^\s*ผู้ใช้\s*:\s*(.+?)\s*$') { $result.UserName = $Matches[1] }
        elseif ($line -match '^\s*รหัสผ่าน\s*:\s*(.*?)\s*$') { $result.Password = $Matches[1] }
        elseif ($line -match '^\s*UNC\s*:\s*(.+?)\s*$') { $result.Unc = $Matches[1] }
        elseif ($line -match '^\s*OnlinePeer\s*:\s*(.+?)\s*$') { $result.OnlinePeerIdentity = $Matches[1] }
    }
    if (-not $result.Unc) { throw 'ไม่พบบรรทัด UNC ในข้อมูลที่วาง — คัดลอกข้อมูลเข้าใช้จากเครื่องผู้แชร์ใหม่' }
    if (-not $result.UserName -or -not $result.Password) {
        throw 'ข้อมูลที่วางไม่ครบ ต้องมีบรรทัด "ผู้ใช้ :" และ "รหัสผ่าน :"'
    }
    return [pscustomobject]$result
}

function Set-LanClientFromLoginBlock {
    # Applies a pasted login block to the client form and reports whether the text was one. Kept
    # apart from the TextChanged handler so it can be tested directly: an event only fires while a
    # message loop is pumping, which a test does not do, and testing it through the event produced a
    # test that silently read the field before anything had happened.
    param(
        [Parameter(Mandatory)][hashtable]$Ui,
        [AllowEmptyString()][string]$Text
    )
    # Keep the UNC box paste path for users of older releases, while allowing the new dedicated
    # one-paste box to feed the exact same validated parser.
    if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = $Ui.Unc.Text }
    $block = ConvertFrom-LanLoginBlock -Text $Text
    if (-not $block) { $Ui.Adapter.ExpectedOnlinePeerIdentity=$null; return $false }
    $Ui.Unc.Text = $block.Unc
    $Ui.Auth.SelectedIndex = [array]::IndexOf(@($Ui.Auth.Items),'Protected Password')
    & ${function:Update-LanClientCredentialFields} -Ui $Ui
    $Ui.WindowsAccount.Text = $block.UserName
    $Ui.PasswordInput.Text = $block.Password
    $Ui.Adapter.ExpectedOnlinePeerIdentity=$block.OnlinePeerIdentity
    $Ui.Status.Text = ('วางข้อมูลเข้าใช้แล้ว: บัญชี {0} — กด "เปิด UNC" หรือ "Map Drive" ได้เลย' -f $block.UserName)
    return $true
}

function Update-LanClientCredentialFields {
    # The meaning of the account and password fields depends on the access mode, so the labels say
    # which one is wanted rather than leaving an empty box to guess at.
    param([Parameter(Mandatory)][hashtable]$Ui)
    switch ($Ui.Auth.Text) {
        'Protected Password' {
            $Ui.WindowsAccountLabel.Text='บัญชีบนเครื่องผู้แชร์'
            # The account is the one the sharing machine created (LFS_...), so it is always entered.
            $Ui.WindowsAccount.Visible=$true
            $Ui.WindowsAccountLabel.Visible=$true
            $Ui.AccountHint.Visible=$true
            $Ui.PasswordLabel.Visible=$true
            $Ui.PasswordInput.Visible=$true
            $Ui.ShowPassword.Visible=$true
            $Ui.PasswordInput.Enabled=$true
            $Ui.Status.Text = ('Protected Password เป็นวิธีเดียวที่ใช้ได้กับทุกเครื่อง: ' +
                'เครื่องผู้แชร์สร้างบัญชีเฉพาะให้ กรอกชื่อบัญชีและรหัสผ่านที่โปรแกรมแสดงบนเครื่องนั้น ' +
                'ระบบจะจำรหัสผ่านไว้ในเครื่องนี้แบบเข้ารหัส และครั้งต่อไปไม่ต้องพิมพ์อีก')
        }
        'WindowsCurrent' {
            $Ui.WindowsAccountLabel.Text='บัญชีบนเครื่องผู้แชร์ (ถ้าชื่อต่างกัน)'
            $Ui.WindowsAccount.Visible=$true
            $Ui.WindowsAccountLabel.Visible=$true
            $Ui.AccountHint.Visible=$false
            # WindowsCurrent sends a blank password by design: Windows itself supplies the logon.
            $Ui.PasswordLabel.Visible=$false
            $Ui.PasswordInput.Visible=$false
            $Ui.ShowPassword.Visible=$false
            $Ui.Status.Text = ('WindowsCurrent ใช้ได้เมื่อบัญชีและรหัสผ่านตรงกันทั้งสองเครื่อง ' +
                'ถ้าชื่อบัญชีต่างกัน ให้กรอกบัญชีบนเครื่องผู้แชร์ที่ไม่มีรหัสผ่าน หรือเปลี่ยนไปใช้ Protected Password')
        }
        default {
            $Ui.WindowsAccount.Visible=$false
            $Ui.WindowsAccountLabel.Visible=$false
            $Ui.AccountHint.Visible=$false
            $Ui.PasswordLabel.Visible=$false
            $Ui.PasswordInput.Visible=$false
            $Ui.ShowPassword.Visible=$false
            $Ui.Status.Text='Guest ต้องให้ Windows อนุญาต Guest logon ก่อน จึงจะใช้ได้'
        }
    }
}

function New-LanClientForm {
    param([bool]$WireEvents=$true)
    $form = New-Object Windows.Forms.Form
    Set-LanFormIcon -Form $form
    $form.Text=('LAN File Sharing — ผู้ใช้ไฟล์' + (Get-LanVersionSuffix)); $form.Size=[Drawing.Size]::new(720,712)
    $form.StartPosition=[Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    # A visible, dedicated landing place for the complete block copied on the sharing machine.
    # It is cleared as soon as parsing succeeds so the plain-text password is not left on screen.
    $loginBlockInput = Add-LanUiTextBox $form 20 0 680
    $loginBlockInput.Multiline=$true
    $loginBlockInput.AcceptsReturn=$true
    $loginBlockInput.ScrollBars=[Windows.Forms.ScrollBars]::Vertical
    $loginBlockInput.WordWrap=$false
    $loginBlockInput.Height=88
    $loginBlockHint = Add-LanUiLabel $form 'วางข้อความจากปุ่ม “คัดลอกข้อมูลเข้าใช้” ระบบจะแยก UNC บัญชี และรหัสผ่านให้อัตโนมัติ แล้วล้างข้อความต้นฉบับออก' 20 0 680
    $loginBlockHint.Height=44
    $loginBlockHint.ForeColor=[Drawing.Color]::FromArgb(90,90,90)
    Add-LanUiLabel $form 'เส้นทาง UNC' 20 25 130 | Out-Null
    $unc = Add-LanUiTextBox $form 150 21 340
    # No example text is left in the field as a value.
    #
    # It used to be pre-filled with "\\computer\share", which is not a real machine. A user who pressed Map
    # Drive without clearing it got "SMB error 67: Share name not found" — an error that says nothing about
    # the cause and reads like the network or the share is broken, when the field simply still held the
    # sample. The field starts empty and a small button fills in a correctly shaped example on request, so
    # the sample can never be mistaken for a real path.
    $unc.Text = ''
    # A stated example, on request only. Never a value in the box, so it cannot be submitted by accident.
    $uncExample = Add-LanUiButton $form 'ตัวอย่าง' 498 19 100
    $uncExample.Add_Click({
        try {
            $share = ''
            try {
                $statePath = Get-LanHostStatePath
                if ($statePath -and (Test-Path -LiteralPath $statePath)) {
                    $state = Read-LanState -Path $statePath
                    $first = @($state.Shares)[0]
                    if ($first) { $share = [string]$first.Name }
                }
            } catch { }
            if (-not $share) { $share = 'ชื่อแชร์' }
            $ui.Unc.Text = "\\$env:COMPUTERNAME\$share"
            $ui.Unc.ForeColor = [Drawing.Color]::Black
        } catch { }
    }.GetNewClosure())
    Add-LanUiLabel $form 'วิธีเข้าใช้' 20 70 130 | Out-Null
    $auth = Add-LanUiCombo $form @('Protected Password','WindowsCurrent','Guest') 150 65 220
    Add-LanUiLabel $form 'ตัวอักษรไดรฟ์' 390 70 130 | Out-Null
    $letters = @('Auto') + @([char[]](69..90))
    $letter = Add-LanUiCombo $form $letters 525 65 145
    $reconnect = New-Object Windows.Forms.CheckBox
    $reconnect.Text='เชื่อมต่อใหม่เมื่อเข้าสู่ Windows'; $reconnect.Checked=$true
    $reconnect.Location=[Drawing.Point]::new(150,107); $reconnect.Size=[Drawing.Size]::new(370,28)
    $form.Controls.Add($reconnect)
    # A separate Windows account on the sharing machine, used when the two accounts differ. It
    # sits below the access-mode row and above the action buttons. The label is wide enough for its
    # text and the box starts past it: at 125 px the Thai text ran into the box beside it.
    $accountLabel = Add-LanUiLabel $form 'บัญชีบนเครื่องผู้แชร์' 20 146 128
    $account = Add-LanUiTextBox $form 152 142 258
    # Protected Password is the only access mode that works between machines whose Windows account
    # names differ, because the sharing machine creates its own account for the share. The password
    # belongs beside the account name, and the same field is reused by WindowsCurrent as a note.
    $passwordLabel = Add-LanUiLabel $form 'รหัสผ่านของบัญชีนั้น' 420 146 135
    $passwordInput = Add-LanUiTextBox $form 555 142 115
    $passwordInput.UseSystemPasswordChar=$true
    $showPassword = Add-LanUiButton $form 'แสดง' 676 142 60
    $showPassword.Size=[Drawing.Size]::new(60,26)
    # Spelled out because the account name has to be copied from the sharing machine, and it was not
    # obvious whether the computer name belonged in front of it.
    $accountHint = Add-LanUiLabel $form 'วางชื่อบัญชีที่โปรแกรมแสดงบนเครื่องผู้แชร์ เช่น LFS_a74ed9171b — ใส่หรือไม่ใส่ชื่อเครื่องนำหน้าก็ได้' 20 172 700
    $accountHint.Size=[Drawing.Size]::new(700,22)
    $accountHint.ForeColor=[Drawing.Color]::FromArgb(90,90,90)
    $open = Add-LanUiButton $form 'เปิด UNC' 20 200 120
    $map = Add-LanUiButton $form 'Map Drive' 150 200 125
    $openDrive = Add-LanUiButton $form 'เปิดไดรฟ์' 285 200 125
    $unmap = Add-LanUiButton $form 'ยกเลิก Map' 420 200 125
    $guestConfig = Add-LanUiButton $form 'ตั้งค่า Guest' 555 200 125
    Add-LanUiLabel $form 'ไดรฟ์ที่เคย Map' 20 260 130 | Out-Null
    $savedMaps = Add-LanUiCombo $form @() 150 255 520
    $status = Add-LanUiLabel $form '' 20 303 700
    $status.Size=[Drawing.Size]::new(700,88)
    $restoreGuest = Add-LanUiButton $form 'คืนค่า Guest' 20 394 150
    # A repair the user can run themselves. Windows allows one credential per server, so with two shares on
    # the same machine using different accounts every second mapping is refused with error 1219, and nothing
    # in the window could clear it. This closes the connections this program can see and reports what it did.
    $tools = Add-LanUiButton $form 'ซ่อมการเชื่อมต่อ...' 180 394 165
    # Stops the automatic connection check for the selected drive, at the owner's request.
    #
    # The program keeps trying to connect a watched drive for as long as it takes, which is what makes moving
    # networks, restarts and half-ready machines work on their own. When a drive is one the user no longer
    # wants watched, this is how they say so — the program should never decide that for them. The drive itself
    # is left untouched: stopping the check never disconnects or removes anything.
    $watchToggle = Add-LanUiButton $form 'หยุดตรวจไดรฟ์นี้' 355 394 165
    # Windows only restores a persistent mapping when the sharing machine is reachable at logon. A
    # laptop that starts first, or on another network, keeps a missing drive until somebody connects by
    # hand — which is what the Windows credential prompt was asking for. This makes the program
    # reconnect its saved drives itself.
    $autoReconnect = New-Object Windows.Forms.CheckBox
    $autoReconnect.Text='ตรวจและเชื่อมต่อไดรฟ์อัตโนมัติตลอดเวลา'
    $autoReconnect.Checked=$true
    $autoReconnect.AutoSize=$true
    $autoReconnect.Location=[Drawing.Point]::new(20,426)
    $form.Controls.Add($autoReconnect)
    # The client tab gets the same live log as the sharing tab, so a slow connection shows what is
    # happening instead of looking frozen. It is anchored to the bottom so enlarging the window makes
    # it taller rather than leaving a gap, and sized so it still fits when the window is at its
    # smallest: 484 + 208 = 692, and the smallest tab area is about 640.
    $logLabel = Add-LanUiLabel $form 'การทำงานของโปรแกรม (ล่าสุดอยู่ด้านล่าง)' 20 430 660
    $logLabel.AutoSize=$false; $logLabel.Size=[Drawing.Size]::new(660,20)
    $log = New-Object Windows.Forms.ListView
    $log.View=[Windows.Forms.View]::Details; $log.FullRowSelect=$true; $log.MultiSelect=$false
    $log.HeaderStyle=[Windows.Forms.ColumnHeaderStyle]::Nonclickable
    $log.Location=[Drawing.Point]::new(20,450); $log.Size=[Drawing.Size]::new(660,215)
    $log.Anchor=[Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    [void]$log.Columns.Add('เวลา',80)
    [void]$log.Columns.Add('ขั้นตอน',560)
    $form.Controls.Add($log)
    $ui = @{LoginBlockInput=$loginBlockInput;LoginBlockHint=$loginBlockHint;
        Unc=$unc;UncExample=$uncExample;Auth=$auth;Letter=$letter;Reconnect=$reconnect;Open=$open;Map=$map;
        WindowsAccount=$account;WindowsAccountLabel=$accountLabel;AccountHint=$accountHint;
        PasswordInput=$passwordInput;PasswordLabel=$passwordLabel;ShowPassword=$showPassword;
        OpenDrive=$openDrive;Unmap=$unmap;GuestConfig=$guestConfig;Status=$status;CurrentMap=$null;
        SavedMaps=$savedMaps;MapEntries=@();RestoreGuest=$restoreGuest;AutoReconnect=$autoReconnect;Tools=$tools;WatchToggle=$watchToggle;
        Log=$log;LogLines=$null;LogTimer=$null;
        Root=(Split-Path -Parent $PSScriptRoot)}
    $form.Tag=$ui
    Set-LanModernClientPage $form
    if (-not $WireEvents) { return $form }
    # The adapter travels inside the hashtable the handlers already close over. Referring to a
    # function variable from a click handler does not work: GetNewClosure captures the scriptblock's
    # own locals, so $adapter resolved to $null at click time and every button on this tab failed
    # with "Cannot bind argument to parameter 'Adapter' because it is null."
    $ui.Adapter = New-LanClientAdapter
    $readClientText=${function:Get-LanUiText}
    $openClientUnc=${function:Open-LanUnc}
    $mapClientDrive=${function:Add-LanClientMap}
    $removeClientMap=${function:Remove-LanClientMap}
    $testMappingWatch=${function:Test-LanMappingWatched}
    $setMappingWatch=${function:Set-LanMappingWatch}
    $parseLoginBlock=${function:Set-LanClientFromLoginBlock}
    $clientLog=${function:Write-LanClientLogSafe}
    $getUserStartup=${function:Get-LanUserStartupSettings}
    $setUserStartup=${function:Set-LanUserStartupSettings}
    $newUserStartupAdapter=${function:New-LanUserStartupAdapter}
    $passwordInput.Add_TextChanged({if(-not $ui.RestoringClientFields){$ui.CredentialWasRemembered=$false;$ui.RememberedCredentialHost=''}}.GetNewClosure())
    $updateCredentialFields = ${function:Update-LanClientCredentialFields}
    $auth.Add_SelectedIndexChanged({
        & $updateCredentialFields -Ui $ui
    }.GetNewClosure())
    $showPassword.Add_Click({
        $ui.PasswordInput.UseSystemPasswordChar = -not $ui.PasswordInput.UseSystemPasswordChar
        $ui.ShowPassword.Text = if ($ui.PasswordInput.UseSystemPasswordChar) { 'แสดง' } else { 'ซ่อน' }
    }.GetNewClosure())
    $loginBlockInput.Add_TextChanged({
        if($ui.ImportingLoginBlock){return}
        $text=$ui.LoginBlockInput.Text
        if([string]::IsNullOrWhiteSpace($text)){return}
        try {
            $ui.ImportingLoginBlock=$true
            if(& $parseLoginBlock -Ui $ui -Text $text){
                # The detected password now lives only in the masked password control and the app's
                # protected credential flow; do not leave the original plain-text block visible.
                $ui.LoginBlockInput.Clear()
            } elseif($text -match "`r?`n" -or $text.Length -ge 32) {
                $ui.Status.Text='ยังตรวจไม่พบข้อมูลเข้าใช้ครบชุด — ต้องมี ผู้ใช้, รหัสผ่าน และ UNC หรือกรอกช่องด้านล่างเองได้'
            }
        } catch {
            $ui.Status.Text=$_.Exception.Message
        } finally {
            $ui.ImportingLoginBlock=$false
        }
    }.GetNewClosure())
    # The fields are created with the password controls shown, so bring them in line with the mode
    # the form actually starts on rather than leaving a field visible that does not apply.
    & $updateCredentialFields -Ui $ui
    $toAuthMode = ${function:ConvertTo-LanAuthMode}
    $updateMapList = ${function:Update-LanClientMapList}
    $form.Add_Shown({try{& $updateMapList -Ui $ui -Adapter $ui.Adapter}catch{$ui.Status.Text='เรียกคืนการเชื่อมต่อไม่สำเร็จ: '+$_.Exception.Message}}.GetNewClosure())
    # Reconnect the saved drives shortly after the window appears, when the preference is on. It runs on
    # a one-shot timer rather than during construction so a slow or unreachable share cannot hold up the
    # window, and it is the answer to a reboot that left the drives missing: Windows restores a
    # persistent mapping only if the sharing machine happens to be reachable at logon.
    # A standing health check, not a one-shot attempt.
    #
    # It used to run once, two seconds after the window opened, and dispose itself. A laptop changes network
    # at any moment, and when it does the share becomes unreachable while nothing is watching — the drive then
    # sits broken until the user notices. This timer keeps running for the life of the window so a network
    # change is noticed and repaired on its own, which is what the owner asked for.
    #
    # The first pass is quick (2 s) so a machine that is already connected says so immediately; later passes are
    # spaced out so an idle window costs almost nothing.
    $reconnectTimer = New-Object Windows.Forms.Timer
    $reconnectTimer.Interval = 2000
    $ui.ReconnectChecks = 0
    $removeStaleMappings=${function:Remove-LanStaleMappings}
    $repairWatchedMappings=${function:Repair-LanMonitoredMappings}
    $reconnectTimer.Add_Tick({
        if (-not $ui.AutoReconnect.Checked) { return }
        $ui.ReconnectChecks = [int]$ui.ReconnectChecks + 1
        # Settle into the standing interval after the first few passes.
        if ($ui.ReconnectChecks -ge 3 -and $reconnectTimer.Interval -ne 20000) { $reconnectTimer.Interval = 20000 }
        try {
            # Drives Windows no longer holds at all are dropped from the list, so the window never shows a
            # drive that is not there. Nothing else is removed: an unreachable share is a connection to keep
            # working on, not a reason to delete anything.
            $cleared = @(& $removeStaleMappings -Adapter $ui.Adapter)
            if ($cleared.Count -gt 0) { & $updateMapList -Ui $ui -Adapter $ui.Adapter }
            # Every watched drive that is not connected is tried again, and this keeps running until it works.
            # One machine not ready, neither ready, the network not ready, a different SSID or VLAN on each side
            # — none of that is an error here; the check comes back and tries again, which is exactly what the
            # owner asked for. Nothing is deleted and nothing is reported as a failure.
            $summary = & $repairWatchedMappings -Adapter $ui.Adapter
            if (@($summary.Connected).Count -gt 0) {
                & $updateMapList -Ui $ui -Adapter $ui.Adapter
                $ui.Status.Text = ('เชื่อมต่อไดรฟ์อัตโนมัติแล้ว: {0}' -f (@($summary.Connected) -join ', '))
                return
            }
            if (@($summary.Waiting).Count -gt 0) {
                # Quietly waiting, not failing: the drive is kept and retried on the next pass.
                $ui.Status.Text = ('รอเชื่อมต่อ: {0} — จะลองใหม่เรื่อย ๆ จนสำเร็จ' -f (@($summary.Waiting) -join ', '))
                return
            }
            # No broad host repair here: the monitored operation owns only watched profiles.
            # Manual repair remains available through the Tools button with its confirmation.
        } catch {
            # The catch must not call the logging helper directly: if that helper is what is missing, the
            # handler throws again and WinForms shows its "Unhandled exception" dialog. Every step here is
            # optional, so a failure is reported in the status line and nothing escapes.
            try { $ui.Status.Text = "เชื่อมต่ออัตโนมัติไม่สำเร็จ: $($_.Exception.Message)" } catch { }
        }
    }.GetNewClosure())
    $ui.ReconnectTimer = $reconnectTimer
    $reconnectTimer.Start()
    # A network change can happen while the window is open, so the check is triggered at once when Windows
    # reports a different address rather than waiting for the next pass.
    try {
        [System.Net.NetworkInformation.NetworkChange]::NetworkAddressChanged += {
            try {
                if ($ui.ReconnectTimer) { $ui.ReconnectTimer.Interval = 2000 }
                $ui.Status.Text = 'ตรวจพบการเปลี่ยนเครือข่าย — กำลังตรวจสอบการเชื่อมต่อ...'
            } catch { }
        }
    } catch { }
    $restoreClientFields=${function:Restore-LanClientFields}
    $completeRemembered=${function:Complete-LanClientRememberedConnection}
    $savedMaps.Add_SelectedIndexChanged({
        try {
            if($ui.RefreshingConnections){return}
            if ($ui.SavedMaps.SelectedIndex -lt 0) { return }
            $ui.CurrentMap = $ui.MapEntries[$ui.SavedMaps.SelectedIndex]
            if (-not $ui.CurrentMap) { return }
            & $restoreClientFields $ui $ui.CurrentMap
            return
        } catch {
            try { $ui.Status.Text = "เรียกคืนค่าไม่สำเร็จ: $($_.Exception.Message)" } catch { }
        }
    }.GetNewClosure())
    # Pasting the block from the sharing machine fills every field, so the client never has to work
    # out which account belongs to which password. Ordinary paths are left completely alone.
    $ui.Unc.Add_TextChanged({
        if($ui.RestoringClientFields){return}
        if($ui.CredentialWasRemembered -and $ui.Unc.Text -match '^\\\\([^\\]+)\\' -and $Matches[1] -ine $ui.RememberedCredentialHost){
            $ui.WindowsAccount.Clear();$ui.PasswordInput.Clear();$ui.CredentialWasRemembered=$false;$ui.RememberedCredentialHost=''
        }
        try { & $parseLoginBlock -Ui $ui | Out-Null }
        catch { $ui.Status.Text = $_.Exception.Message }
    }.GetNewClosure())
    $open.Add_Click({
        try {
            $uncValue = & $readClientText $ui.Unc
            if (-not $uncValue) {
                $ui.Status.Text = 'ใส่เส้นทาง UNC ของเครื่องผู้แชร์ก่อน เช่น \\ชื่อเครื่อง\ชื่อแชร์ (กดปุ่ม ตัวอย่าง เพื่อดูรูปแบบ)'
                return
            }
            & $clientLog "เปิด UNC: $uncValue (โหมด $($ui.Auth.Text))"
            $password=if($ui.CredentialWasRemembered){''}else{$ui.PasswordInput.Text}
            $ui.CurrentMap=& $openClientUnc -Path $uncValue -AuthMode (& $toAuthMode -Label $ui.Auth.Text) -WindowsAccount $ui.WindowsAccount.Text -Password $password -Adapter $ui.Adapter
            & $clientLog "เปิดเส้นทาง UNC สำเร็จ: $uncValue"
            $ui.Status.Text='เปิดเส้นทาง UNC แล้ว'
            & $completeRemembered $ui $ui.CurrentMap
            & $updateMapList -Ui $ui -Adapter $ui.Adapter
        } catch {
            & $clientLog "เปิด UNC ไม่สำเร็จ: $($_.Exception.Message)"
            $ui.Status.Text=$_.Exception.Message
        }
    }.GetNewClosure())
    $map.Add_Click({
        try {
            # A blank field must produce a sentence the user can act on. Passing it straight to the mapping
            # function surfaced PowerShell's own wording ("Cannot bind argument to parameter 'Unc' because it
            # is an empty string"), which reads like a program fault rather than a missing value.
            $uncValue = & $readClientText $ui.Unc
            if (-not $uncValue) {
                $ui.Status.Text = 'ใส่เส้นทาง UNC ของเครื่องผู้แชร์ก่อน เช่น \\ชื่อเครื่อง\ชื่อแชร์ (กดปุ่ม ตัวอย่าง เพื่อดูรูปแบบ)'
                return
            }
            & $clientLog "Map Drive: $uncValue (โหมด $($ui.Auth.Text), ไดรฟ์ $($ui.Letter.Text))"
            $password=if($ui.CredentialWasRemembered){''}else{$ui.PasswordInput.Text}
            $ui.CurrentMap = & $mapClientDrive -Unc $uncValue -Letter $ui.Letter.Text -Persistent $ui.Reconnect.Checked -AuthMode (& $toAuthMode -Label $ui.Auth.Text) -WindowsAccount $ui.WindowsAccount.Text -Password $password -Adapter $ui.Adapter
            & $updateMapList -Ui $ui -Adapter $ui.Adapter
            & $clientLog "Map Drive สำเร็จ: $($ui.CurrentMap.Letter): → $($ui.CurrentMap.Unc)"
            # Say which account was used when it is not the one in the box. Windows keeps one credential per
            # machine, so every share on a machine uses the same account; naming it removes the question of why
            # the typed one appears to have been ignored.
            $usedAccount = [string]$ui.CurrentMap.WindowsAccount
            $typedName = if ($ui.WindowsAccount.Text) { ([string]$ui.WindowsAccount.Text) -replace '^[^\\]+\\','' } else { '' }
            $usedName = if ($usedAccount) { $usedAccount -replace '^[^\\]+\\','' } else { '' }
            $ui.Status.Text = if ($usedAccount -and $typedName -and $typedName -ine $usedName) {
                ('Map Drive สำเร็จ: {0}: → {1}  (ใช้บัญชี {2} — Windows ใช้บัญชีเดียวต่อหนึ่งเครื่อง)' -f $ui.CurrentMap.Letter, $ui.CurrentMap.Unc, $usedAccount)
            } else {
                "Map Drive สำเร็จ: $($ui.CurrentMap.Letter): → $($ui.CurrentMap.Unc)"
            }
            & $completeRemembered $ui $ui.CurrentMap
        } catch {
            & $clientLog "Map Drive ไม่สำเร็จ: $($_.Exception.Message)"
            $ui.Status.Text=$_.Exception.Message
        }
    }.GetNewClosure())
    $openDrive.Add_Click({
        if (-not $ui.CurrentMap) { $ui.Status.Text='ยังไม่มีไดรฟ์ที่ Map ด้วยโปรแกรม'; return }
        if($ui.CurrentMap.Letter){Start-Process explorer.exe -ArgumentList ($ui.CurrentMap.Letter + ':') | Out-Null}
        else{& $restoreClientFields $ui $ui.CurrentMap;$ui.Open.PerformClick()}
    }.GetNewClosure())
    # The preference is stored with the other per-user startup settings, so it survives a reboot.
    try {
        $startupSettings = Get-LanUserStartupSettings
        $ui.AutoReconnect.Checked = [bool]$startupSettings.AutoReconnect
    } catch { }
    $ui.AutoReconnect.Add_CheckedChanged({
        try {
            $startupAdapter=if($ui.StartupAdapter){$ui.StartupAdapter}else{& $newUserStartupAdapter}
            $current = & $getUserStartup -Adapter $startupAdapter
            $launcherPath = Join-Path $ui.Root 'LanFileSharing.exe'
            & $setUserStartup -StartWithHost ([bool]$current.StartWithHost) `
                -StartMinimized ([bool]$current.StartMinimized) -LauncherPath $launcherPath `
                -ShowAfterSeconds ([int]$current.ShowAfterSeconds) `
                -AutoReconnect ([bool]$ui.AutoReconnect.Checked) -Adapter $startupAdapter | Out-Null
            $ui.Status.Text = if ($ui.AutoReconnect.Checked) { 'จะเชื่อมต่อไดรฟ์ที่เคย Map ให้อัตโนมัติเมื่อเปิดโปรแกรม' }
                              else { 'จะไม่เชื่อมต่อไดรฟ์อัตโนมัติ — ต้องกด Map Drive เอง' }
        } catch { $ui.Status.Text = $_.Exception.Message }
    }.GetNewClosure())
    $unmap.Add_Click({
        if (-not $ui.CurrentMap) { $ui.Status.Text='ยังไม่มีไดรฟ์ที่ Map ด้วยโปรแกรม'; return }
        try {
            Write-LanClientLogSafe "ยกเลิก Map: $($ui.CurrentMap.Letter):"
            $target=if(-not $ui.CurrentMap.Letter -and $ui.CurrentMap.Path){[string]$ui.CurrentMap.Path}else{[string]$ui.CurrentMap.Unc}
            & $removeClientMap -Letter $ui.CurrentMap.Letter -ExpectedUnc $target -Adapter $ui.Adapter | Out-Null
            Write-LanClientLogSafe "ยกเลิก Map แล้ว: $($ui.CurrentMap.Letter):"
            $ui.Status.Text=if($ui.CurrentMap.Letter){'ยกเลิก Map Drive แล้ว'}else{'ลืม UNC นี้แล้ว'}; $ui.CurrentMap=$null
            $ui.Unc.Clear();$ui.WindowsAccount.Clear();$ui.PasswordInput.Clear();$ui.ClientFieldsRestored=$false
            & $updateMapList -Ui $ui -Adapter $ui.Adapter
        } catch { $ui.Status.Text=$_.Exception.Message }
    }.GetNewClosure())
    $guestConfig.Add_Click({
        try {
            $check = Get-LanGuestCompatibility -Role Client -Adapter $ui.Adapter
            if (-not $check.Supported) { $ui.Status.Text=($check.BlockedReasons -join '; '); return }
            if (@($check.RequiredChanges).Count -eq 0) { $ui.Status.Text='Guest client policy พร้อมใช้งาน'; return }
            $launcher = Join-Path $ui.Root 'LanShare.ps1'
            $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $launcher + '" -ConfigureGuestClient'
            $child = Start-Process -FilePath powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            $ui.Status.Text = if ($child.ExitCode -eq 0) { 'ตั้งค่า Guest client แล้ว' } else { 'ตั้งค่า Guest client ไม่สำเร็จ' }
        } catch { $ui.Status.Text=$_.Exception.Message }
    }.GetNewClosure())
    $restoreGuest.Add_Click({
        try {
            $launcher = Join-Path $ui.Root 'LanShare.ps1'
            $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $launcher + '" -RestoreGuestClient'
            $child = Start-Process -FilePath powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            $ui.Status.Text = if ($child.ExitCode -eq 0) { 'คืนค่าการตั้งค่า Guest แล้ว' } else { 'คืนค่า Guest ไม่สำเร็จ โปรดตรวจนโยบาย Windows' }
        } catch { $ui.Status.Text=$_.Exception.Message }
    }.GetNewClosure())
    $tools.Add_Click({
        try {
            # One button that answers "make my drives work again". It covers everything a network change
            # breaks: drive letters held by unreachable mappings, a stale session holding a different
            # credential, and the reconnect itself. The user is shown what will be closed first, because
            # losing connections should be an informed choice rather than a surprise.
            $unc = (Get-LanUiText $ui.Unc)
            $hostName = ''
            if ($unc -match '^\\\\[^\\]+') { $hostName = ($unc -replace '^\\\\','').Split('\')[0] }
            $lines = New-Object System.Collections.ArrayList
            foreach ($letter in @(Get-LanNetworkDriveLetters)) {
                try {
                    $target = [string](& $ui.Adapter.GetMapping $letter)
                    if ($target) { [void]$lines.Add("  $letter`:  ->  $target") }
                    else { [void]$lines.Add("  $letter`:  ->  (เชื่อมต่อไม่ได้ — จะปล่อยไดรฟ์นี้)") }
                } catch { }
            }
            $saved = @(Read-LanClientMappings -Path (Get-LanClientStatePath $ui.Adapter))
            foreach ($entry in $saved) {
                if ("$($entry.Letter)" -notin @($lines | ForEach-Object { ($_ -replace '^\s+(\w):.*','$1') })) {
                    [void]$lines.Add("  $($entry.Letter):  ->  $($entry.Unc) (จะเชื่อมใหม่)")
                }
            }
            if (-not $hostName -and $saved.Count -gt 0) { $hostName = ([string]$saved[0].Unc -replace '^\\\\','').Split('\')[0] }
            if (-not $hostName) { $ui.Status.Text = 'ใส่เส้นทาง UNC ของเครื่องผู้แชร์ก่อน แล้วกดซ่อมการเชื่อมต่อ'; return }
            $detail = if ($lines.Count -gt 0) { "สิ่งที่พบ:`r`n" + ($lines -join "`r`n") } else { '  (ไม่พบการเชื่อมต่อหรือไดรฟ์ที่บันทึกไว้)' }
            $choice = [Windows.Forms.MessageBox]::Show(
                ("ซ่อมการเชื่อมต่อไปที่ $hostName`r`n`r`n$detail`r`n`r`n" +
                 'โปรแกรมจะ: ปล่อยไดรฟ์ที่ค้างอยู่ → ปิดการเชื่อมต่อเดิม → เชื่อมต่อกลับด้วยรหัสที่บันทึกไว้' +
                 "`r`n`r`n" + 'ดำเนินการต่อหรือไม่?'),
                'ซ่อมการเชื่อมต่อ', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
            if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
            $ui.Status.Text = 'กำลังซ่อมการเชื่อมต่อ...'
            [Windows.Forms.Application]::DoEvents()
            $repair = Repair-LanClientConnection -Adapter $ui.Adapter -Unc $unc
            & $updateMapList -Ui $ui -Adapter $ui.Adapter
            $ui.Status.Text = $repair.Message
        } catch {
            # Every step is optional, so the handler never lets a failure escape into the event loop.
            try { $ui.Status.Text = "ซ่อมการเชื่อมต่อไม่สำเร็จ: $($_.Exception.Message)" } catch { }
        }
    }.GetNewClosure())
    $watchToggle.Add_Click({
        try {
            # Works on the drive selected in the saved-drive list, which is also what "ยกเลิก Map" uses.
            if (-not $ui.CurrentMap) {
                $ui.Status.Text = 'เลือกไดรฟ์ที่เคย Map ในรายการก่อน แล้วกดปุ่มนี้'
                return
            }
            $letter = [string]$ui.CurrentMap.Letter
            $target=if(-not $letter -and $ui.CurrentMap.Path){[string]$ui.CurrentMap.Path}else{[string]$ui.CurrentMap.Unc}
            $label=if($letter){$letter+':'}else{$target}
            $watching = & $testMappingWatch -Entry $ui.CurrentMap
            if ($watching) {
                & $setMappingWatch -Letter $letter -Unc $target -Watching $false -Adapter $ui.Adapter | Out-Null
                $ui.Status.Text = ("หยุดตรวจ {0} แล้ว — บันทึกยังอยู่ แต่โปรแกรมจะไม่เชื่อมต่อให้อีก" -f $label)
                Write-LanClientLogSafe "หยุดตรวจไดรฟ์อัตโนมัติ: $letter`:"
            } else {
                & $setMappingWatch -Letter $letter -Unc $target -Watching $true -Adapter $ui.Adapter | Out-Null
                $ui.Status.Text = ("กลับมาตรวจ {0} แล้ว — จะเชื่อมต่อให้อัตโนมัติจนสำเร็จ" -f $label)
                Write-LanClientLogSafe "กลับมาตรวจไดรฟ์อัตโนมัติ: $letter`:"
            }
            & $updateMapList -Ui $ui -Adapter $ui.Adapter
        } catch {
            try { $ui.Status.Text = "เปลี่ยนการตรวจไดรฟ์ไม่สำเร็จ: $($_.Exception.Message)" } catch { }
        }
    }.GetNewClosure())
    # The pane is filled on a timer, the same way the sharing tab does it, and the timer is stopped when the
    # form closes so it cannot outlive the window.
    $logTimer = New-Object Windows.Forms.Timer
    $logTimer.Interval = 500
    # A timer callback is an event handler: an exception inside it is unhandled and WinForms shows a
    # .NET crash dialog. The pane is only a convenience, so a failure is recorded and the window keeps
    # working — that is what turned a missing function into an unhandled exception before.
    $logTimer.Add_Tick({
        try { Update-LanClientLogPane -State $ui }
        catch { try { Write-LanClientLogSafe "แสดงบันทึกไม่สำเร็จ: $($_.Exception.Message)" } catch { } }
    }.GetNewClosure())
    $ui.LogTimer = $logTimer
    Update-LanClientLogPane -State $ui
    $logTimer.Start()
    $form.Add_FormClosed({ if ($ui.LogTimer) { $ui.LogTimer.Stop(); $ui.LogTimer.Dispose() } }.GetNewClosure())
    return $form
}

function Assert-LanCodeMatchesDisk {
    # The running window keeps its functions in memory, so replacing files underneath it leaves the two
    # out of step: a timer can call a function that the loaded code does not have yet and WinForms
    # reports "The term 'X' is not recognized" as an unhandled exception. This check turns that into a
    # plain message that names the file, so it never looks like a random crash.
    # The scan itself lives in Get-LanDefinedFunction. It used to be written here as well, with rules
    # that differed from the deploy script's copy, and that difference raised a warning about
    # "Add-Trace" and "Set-Result" — functions inside a here-string that is written out as a helper
    # process and never loaded here. A false alarm cannot be told apart from a real one, so the rule
    # now has one definition and both callers use it.
    param([Parameter(Mandatory)][string]$SourceRoot)
    try {
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($module in (Get-LanLoadedModuleNames)) {
            $name = "$module.ps1"
            $path = Join-Path $SourceRoot $name
            if (-not [IO.File]::Exists($path)) { continue }
            foreach ($functionName in (Get-LanDefinedFunction -Path $path)) {
                if (-not (Get-Command $functionName -ErrorAction SilentlyContinue)) { $missing.Add("$name : $functionName") }
            }
        }
        if ($missing.Count -gt 0) {
            return ('โค้ดที่โปรแกรมกำลังใช้ไม่ตรงกับไฟล์ใน ' + $SourceRoot + ' — กรุณาปิดโปรแกรมแล้วเปิดใหม่ ' +
                '(ฟังก์ชันที่ยังไม่ถูกโหลด: ' + (@($missing | Select-Object -First 5) -join ', ') + ')')
        }
        return $null
    } catch { return $null }
}
function Show-LanMainWindow {
    # Brings the main window back from the notification area. Kept as a module-level function
    # because a script block held in a local variable is not reachable from inside an event
    # handler's scope, which is exactly how the delayed automatic start used to fail.
    param([Parameter(Mandatory)]$Form)
    try {
        if ($null -eq $Form -or $Form.IsDisposed) { return }
        $Form.ShowInTaskbar=$true
        $Form.Visible=$true
        $Form.WindowState=[Windows.Forms.FormWindowState]::Normal
        $Form.Activate() | Out-Null
    } catch { }
}

function New-LanMainForm {
    param([bool]$WireEvents=$true,[bool]$AutoLaunch=$false,[bool]$SelectHost=$false,$StartupSettings)
    # Give the process and this window the Tiger Tech taskbar identity before anything else, so
    # the taskbar groups and relaunches under the application's own name and icon.
    [LanTaskbarIdentityNative]::SetProcess('TigerTech.LanFileSharing')
    $form=New-Object Windows.Forms.Form
    Set-LanFormIcon -Form $form
    Set-LanTaskbarIdentity -Form $form
    $form.Text=('LAN File Sharing' + (Get-LanVersionSuffix)); $form.Size=[Drawing.Size]::new(990,914)
    # The window may be shrunk a long way: both tabs stretch with it and the log panes inside them shrink
    # too. A tall fixed minimum would push the pane below the visible area on a small screen, which is
    # exactly how the log disappeared after it was added.
    $form.MinimumSize=[Drawing.Size]::new(900,700)
    $form.StartPosition=[Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $tabs=New-Object LanModernTabs
    $tabs.Location=[Drawing.Point]::new(8,8); $tabs.Size=[Drawing.Size]::new(960,664)
    $tabs.Anchor=[Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    $clientPage=New-Object Windows.Forms.TabPage('เครื่องผู้ใช้ไฟล์')
    $hostPage=New-Object Windows.Forms.TabPage('เครื่องผู้แชร์')
    # A scroll bar, so nothing can be pushed out of reach.
    #
    # The share page needs more height than the tab gives it: the log pane at the bottom is its most useful part
    # and it was the first thing to be cut off at a display scale above 100% or with one row of controls too
    # many. Rather than trimming rows and losing the log, the page scrolls. AutoScroll only shows the bar when
    # the content is actually taller than the page, so it costs nothing on a large screen.
    $clientPage.AutoScroll = $true
    $hostPage.AutoScroll = $true
    [void]$tabs.TabPages.Add($clientPage); [void]$tabs.TabPages.Add($hostPage)
    $form.Controls.Add($tabs)
    $clientForm=New-LanClientForm -WireEvents:$WireEvents
    $hostForm=New-LanHostForm -WireEvents:$WireEvents -UseBridge:$WireEvents
    foreach ($embedded in @($clientForm,$hostForm)) {
        $embedded.TopLevel=$false
        $embedded.FormBorderStyle=[Windows.Forms.FormBorderStyle]::None
        $embedded.Dock=[Windows.Forms.DockStyle]::Fill
    }
    $clientPage.Controls.Add($clientForm); $hostPage.Controls.Add($hostForm)
    $onlinePage=New-Object Windows.Forms.TabPage('Online')
    $onlinePage.AutoScroll=$true
    $onlineForm=New-LanOnlineForm -WireEvents:$WireEvents
    $onlineForm.TopLevel=$false; $onlineForm.FormBorderStyle='None'; $onlineForm.Dock='Fill'
    $onlinePage.Controls.Add($onlineForm); [void]$tabs.TabPages.Add($onlinePage)
    $hostForm.Tag.GetOnlineStatus={
        if($onlineForm.Tag.LastStatusAt -and ([DateTime]::UtcNow-$onlineForm.Tag.LastStatusAt).TotalSeconds -lt 15){return $onlineForm.Tag.LastStatus}
        return $null
    }.GetNewClosure()
    if(-not $clientForm.Tag.Adapter){$clientForm.Tag.Adapter=New-LanClientAdapter}
    $pendingOnlineStatus=New-LanOnlineStatusModel
    $pendingOnlineStatus.ConnectionState='Connecting'
    $clientForm.Tag.Adapter.GetOnlineStatus={
        if($onlineForm.Tag.LastStatusAt -and ([DateTime]::UtcNow-$onlineForm.Tag.LastStatusAt).TotalSeconds -lt 15){return $onlineForm.Tag.LastStatus}
        return $pendingOnlineStatus
    }.GetNewClosure()
    $onlineForm.Show()
    if ($SelectHost) { $tabs.SelectedTab=$hostPage }
    $startWithHost=New-Object Windows.Forms.CheckBox
    $startWithHost.Text='เปิดโปรแกรมอัตโนมัติเมื่อเข้าสู่ Windows'
    $startWithHost.AutoSize=$true
    $startWithHost.Location=[Drawing.Point]::new(30,689)
    $startWithHost.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $form.Controls.Add($startWithHost)
    $startMinimized=New-Object Windows.Forms.CheckBox
    $startMinimized.Text='เปิดอัตโนมัติแล้วอยู่ในถาดระบบก่อน'
    $startMinimized.AutoSize=$true
    $startMinimized.Location=[Drawing.Point]::new(30,718)
    $startMinimized.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $form.Controls.Add($startMinimized)
    $showAfterLabel=Add-LanUiLabel $form 'แล้วเด้งหน้าต่างภายใน (วินาที)' 300 722 215
    $showAfterLabel.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $showAfter=New-Object Windows.Forms.NumericUpDown
    $showAfter.Location=[Drawing.Point]::new(520,718); $showAfter.Size=[Drawing.Size]::new(70,28)
    $showAfter.Minimum=0; $showAfter.Maximum=600; $showAfter.Value=15
    $showAfter.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $form.Controls.Add($showAfter)
    $showAfterNote=Add-LanUiLabel $form '0 = อยู่ในถาดระบบเท่านั้น' 600 722 320
    $showAfterNote.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    # One button that answers "is it registered, and can I change it now?" without leaving the
    # window, and that reports the exact login command Windows stores.
    $startupButton=Add-LanUiButton $form 'Startup อัตโนมัติ...' 30 748 190
    $startupButton.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $startupStatus=Add-LanUiLabel $form '' 232 752 690
    $startupStatus.AutoSize=$false; $startupStatus.Size=[Drawing.Size]::new(690,24)
    $startupStatus.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $startupHelp=Add-LanUiLabel $form 'เปิดโปรแกรมหลังลงชื่อเข้า Windows สำหรับบัญชีนี้; การแชร์ที่เปิดเมื่อบูตตั้งค่าในแท็บผู้แชร์' 30 780 880
    $startupHelp.AutoSize=$false; $startupHelp.Size=[Drawing.Size]::new(880,24)
    $startupHelp.Anchor=[Windows.Forms.AnchorStyles]'Left,Bottom'
    $trayMenu=New-Object Windows.Forms.ContextMenuStrip
    $trayOpen=$trayMenu.Items.Add('Open')
    $trayExit=$trayMenu.Items.Add('Exit')
    $tray=New-Object Windows.Forms.NotifyIcon
    $trayIcon=Get-LanUiIcon
    $tray.Icon=if($trayIcon){$trayIcon}else{[Drawing.SystemIcons]::Application}
    # NotifyIcon.Text is limited to 63 characters and throws above that, which would break the
    # window at startup. Keep it short; the balloon tip carries the rest of the instruction.
    $tray.Text=('LAN File Sharing' + (Get-LanVersionSuffix) + ' — คลิกขวา > Exit'); $tray.ContextMenuStrip=$trayMenu
    $ui=@{Tabs=$tabs;ClientForm=$clientForm;HostForm=$hostForm;StartWithHost=$startWithHost;
        StartMinimized=$startMinimized;ShowAfter=$showAfter;ShowAfterNote=$showAfterNote;
        Tray=$tray;TrayOpen=$trayOpen;TrayExit=$trayExit;
        StartupButton=$startupButton;StartupStatus=$startupStatus;
        AutoLaunch=$AutoLaunch;StartupHelp=$startupHelp}
    $form.Tag=$ui
    Set-LanModernShell $form $showAfterLabel
    $clientForm.Tag.OwnerStartupUi=$ui
    $form.Add_Disposed({
        $tray.Visible=$false
        $tray.Dispose()
        $trayMenu.Dispose()
        if ($trayIcon) { $trayIcon.Dispose() }
    }.GetNewClosure())
    if (-not $WireEvents) { return $form }
    $ui.StartupAdapter=New-LanUserStartupAdapter
    $clientForm.Tag.StartupAdapter=$ui.StartupAdapter
    $getStartupSettings=${function:Get-LanUserStartupSettings}
    $setStartupSettings=${function:Set-LanUserStartupSettings}
    $getStartupState=${function:Get-LanUserStartupState}
    $testStartupRegistered=${function:Test-LanUserStartupRegistered}
    $settings=if ($StartupSettings) { $StartupSettings } else { & $getStartupSettings -Adapter $ui.StartupAdapter }
    $startWithHost.Checked=[bool]$settings.StartWithHost
    $startMinimized.Checked=[bool]$settings.StartMinimized
    if ($settings.PSObject.Properties.Name -contains 'ShowAfterSeconds') { $showAfter.Value=[decimal][int]$settings.ShowAfterSeconds }
    $ui.StartHidden=Test-LanStartHidden -AutoLaunch $AutoLaunch -Settings $settings
    $launcher=Join-Path (Split-Path -Parent $PSScriptRoot) 'LanFileSharing.exe'
    $changing=$false
    # The delay control only means something for an automatic start that stays in the tray.
    $refreshStartup={
        $startMinimized.Enabled=$startWithHost.Checked
        $showAfter.Enabled=($startWithHost.Checked -and $startMinimized.Checked)
        $showAfterNote.Enabled=$showAfter.Enabled
        if (-not $startWithHost.Checked) {
            $startupStatus.Text='ยังไม่เปิดอัตโนมัติ — โปรแกรมจะไม่เปิดเองหลังลงชื่อเข้า Windows'
        } elseif (-not $startMinimized.Checked) {
            $startupStatus.Text='เปิดอัตโนมัติแล้ว และจะแสดงหน้าต่างทันทีเมื่อลงชื่อเข้า Windows บัญชีนี้'
        } elseif ([int]$showAfter.Value -gt 0) {
            $startupStatus.Text=('เปิดอัตโนมัติแล้ว อยู่ในถาดระบบก่อน แล้วเด้งหน้าต่างภายใน {0} วินาที' -f [int]$showAfter.Value)
        } else {
            $startupStatus.Text='เปิดอัตโนมัติแล้ว และจะอยู่ในถาดระบบเท่านั้น (ดับเบิลคลิกไอคอนเพื่อเปิดหน้าต่าง)'
        }
    }.GetNewClosure()
    $savePreferences={
        if ($ui.ChangingStartup) { return }
        try {
            if ($startWithHost.Checked -and -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
                throw 'ยังไม่พบโปรแกรมที่ติดตั้ง กรุณาติดตั้งใหม่ก่อนเปิดอัตโนมัติ'
            }
            $latestPreferences=& $getStartupSettings -Adapter $ui.StartupAdapter
            & $setStartupSettings -StartWithHost $startWithHost.Checked -StartMinimized $startMinimized.Checked -LauncherPath $launcher -ShowAfterSeconds ([int]$showAfter.Value) -AutoReconnect $latestPreferences.AutoReconnect -Adapter $ui.StartupAdapter | Out-Null
            $startupHelp.Text='บันทึกการเริ่มโปรแกรมสำหรับบัญชี Windows นี้แล้ว'
        } catch {
            $startupHelp.Text=$_.Exception.Message
            $ui.ChangingStartup=$true
            $latest=& $getStartupSettings -Adapter $ui.StartupAdapter
            $startWithHost.Checked=[bool]$latest.StartWithHost
            $startMinimized.Checked=[bool]$latest.StartMinimized
            $ui.ChangingStartup=$false
        }
        & $refreshStartup
    }.GetNewClosure()
    $startWithHost.Add_CheckedChanged($savePreferences)
    $startMinimized.Add_CheckedChanged($savePreferences)
    $showAfter.Add_ValueChanged($savePreferences)
    $startupButton.Add_Click({
        # The button reports the live registration and offers to change it, so a user who is
        # unsure whether the program will start can find out without reading the registry.
        try {
            $state=& $getStartupState -Adapter $ui.StartupAdapter
            $registered=& $testStartupRegistered -LauncherPath $launcher -Adapter $ui.StartupAdapter
            $lines=@(
                ('สถานะ: {0}' -f $state.Description)
                ('คำสั่งที่ Windows ใช้: {0}' -f $(if ($state.LoginCommand) { $state.LoginCommand } else { '(ไม่มี)' }))
                ('Launcher ที่ติดตั้ง: {0} ({1})' -f $launcher, $(if (Test-Path -LiteralPath $launcher) { 'พบไฟล์' } else { 'ไม่พบไฟล์' }))
                ('ตรงกับการติดตั้งปัจจุบัน: {0}' -f $(if ($registered) { 'ใช่' } else { 'ไม่' }))
            )
            $choice=[Windows.Forms.MessageBox]::Show(
                (($lines -join "`r`n") + "`r`n`r`n" + $(if ($state.Enabled) { 'ต้องการปิดการเปิดอัตโนมัติหรือไม่?' } else { 'ต้องการเปิดโปรแกรมอัตโนมัติเมื่อเข้าสู่ Windows หรือไม่?' })),
                'Startup อัตโนมัติ',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
            if ($choice -eq [Windows.Forms.DialogResult]::Yes) {
                $startWithHost.Checked=-not $state.Enabled
                & $savePreferences
            }
        } catch { $startupHelp.Text=$_.Exception.Message }
    }.GetNewClosure())
    & $refreshStartup
    $showWindow={
        # We are showing the main window again.
        try {
            if ($form.IsDisposed) { return }
            $form.ShowInTaskbar=$true
            $form.Visible=$true
            $form.WindowState=[Windows.Forms.FormWindowState]::Normal
            $form.Activate() | Out-Null
        } catch { }
    }.GetNewClosure()
    $trayOpen.Add_Click($showWindow)
    $tray.Add_DoubleClick($showWindow)
    # Only the tray's Exit really closes the program. Every other way of dismissing the window —
    # the title bar X, Alt+F4, the system menu — hides it to the notification area instead, so a
    # share that is running keeps running. Closing by accident used to stop sharing altogether,
    # which is the opposite of what a background file server should do.
    $ui.ExitRequested=$false
    $form.Add_FormClosing({
        param($sender,$eventArgs)
        if ($ui.ExitRequested) { return }
        if ($eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::WindowsShutDown -or
            $eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::TaskManagerClosing) { return }
        # Cancel the close and stay resident in the notification area.
        $eventArgs.Cancel=$true
        $form.Hide()
        $form.ShowInTaskbar=$false
        try {
            $ui.Tray.Visible=$true
            $ui.Tray.ShowBalloonTip(3000,'LAN File Sharing',
                'โปรแกรมยังทำงานอยู่ที่ถาดระบบ — ดับเบิลคลิกไอคอนเพื่อเปิดหน้าต่าง หรือคลิกขวาแล้วเลือก Exit เพื่อปิดโปรแกรม',
                [Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    }.GetNewClosure())
    $trayExit.Add_Click({
        # The one path that really exits. The flag lets the FormClosing handler above stand aside.
        $ui.ExitRequested=$true
        $form.Close()
    }.GetNewClosure())
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedTab -eq $hostPage -and -not $hostForm.Visible) { $hostForm.Show() }
        if ($tabs.SelectedTab -eq $clientPage -and -not $clientForm.Visible) { $clientForm.Show() }
    }.GetNewClosure())
    $form.Add_Shown({
        $tray.Visible=$true
        if ($tabs.SelectedTab -eq $hostPage) { $hostForm.Show() } else { $clientForm.Show() }
        # Read the state from the form: this closure is built before $ui exists, so a captured
        # $ui would be $null and the delayed show would never be scheduled.
        $state=$form.Tag
        # Log with plain file calls: calling a helper from inside this handler proved unreliable
        # (it once hung the whole test run), so the handler stays self-contained.
        try {
            [IO.File]::AppendAllText((Join-Path $env:LOCALAPPDATA 'LanFileSharing\launcher.log'), ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ui: window shown; startHidden=' + $state.StartHidden + "`r`n"), [Text.Encoding]::UTF8)
        } catch { }
        if (-not $state.StartHidden) { return }
        $form.Hide(); $form.ShowInTaskbar=$false
        $delay=[int]$state.ShowAfter.Value
        try {
            [IO.File]::AppendAllText((Join-Path $env:LOCALAPPDATA 'LanFileSharing\launcher.log'), ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ('  ui: stayed in the notification area; will show the window in {0}s' -f $delay) + "`r`n"), [Text.Encoding]::UTF8)
        } catch { }
        # Say so once, otherwise an automatic start that hides itself looks like a program that
        # never started.
        try {
            $tray.BalloonTipTitle='LAN File Sharing กำลังทำงาน'
            $tray.BalloonTipText=if ($delay -gt 0) {
                ('โปรแกรมเปิดอัตโนมัติและอยู่ในถาดระบบ จะเปิดหน้าต่างให้ภายใน {0} วินาที (หรือดับเบิลคลิกไอคอนนี้)' -f $delay)
            } else {
                'โปรแกรมเปิดอัตโนมัติและอยู่ในถาดระบบ ดับเบิลคลิกไอคอนนี้เพื่อเปิดหน้าต่าง'
            }
            $tray.ShowBalloonTip(10000)
        } catch { }
        # Show the window after the configured wait so the user can see that the program is
        # running, unless they asked it to stay in the notification area.
        if ($delay -le 0) { return }
        $showTimer=New-Object Windows.Forms.Timer
        $showTimer.Interval=[Math]::Min(600000,[Math]::Max(1000,$delay * 1000))
        # Reach the window through the timer ($this) rather than a captured variable: inside an
        # event handler a captured local can resolve to $null, which is how the delayed automatic
        # start silently did nothing.
        $showTimer.Tag=$form
        $form.Tag.ShowTimer=$showTimer
        $showTimer.Add_Tick({
            $timer=$this
            $timer.Stop(); $timer.Dispose()
            $logPath = Join-Path $env:LOCALAPPDATA 'LanFileSharing\launcher.log'
            try {
                Show-LanMainWindow -Form $timer.Tag
                [IO.File]::AppendAllText($logPath, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ui: window shown by the automatic start; visible=' + $timer.Tag.Visible + "`r`n"), [Text.Encoding]::UTF8)
            } catch {
                try { [IO.File]::AppendAllText($logPath, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ui: automatic show FAILED ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message + "`r`n"), [Text.Encoding]::UTF8) } catch { }
            }
        })
        $showTimer.Start()
    }.GetNewClosure())
    return $form
}

function Start-LanShareGui {
    param([bool]$HostMode=$false,[bool]$AutoLaunch=$false)
    [Windows.Forms.Application]::EnableVisualStyles()
    # Record why the window started or stopped. The launcher writes the first line, so together
    # they show whether Windows actually ran the login entry.
    try {
        [IO.File]::AppendAllText((Join-Path $env:LOCALAPPDATA 'LanFileSharing\launcher.log'), ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ('  ui: Start-LanShareGui autoLaunch={0} pid={1}' -f $AutoLaunch, $PID) + "`r`n"), [Text.Encoding]::UTF8)
    } catch { }
    # WinForms turns an exception raised inside an event handler into a modal "Unhandled exception"
    # dialog, which looks like the program is broken even when the failure is in an optional extra such
    # as renewing a drive mapping. Recording it and continuing keeps the window usable; the log says what
    # happened, so nothing is hidden.
    try {
        [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
        [Windows.Forms.Application]::add_ThreadException({
            param($sender,$eventArgs)
            try { Write-LanClientLogSafe "ข้อผิดพลาดที่ไม่ได้คาดคิด: $($eventArgs.Exception.Message)" } catch { }
        })
    } catch { }
    $instance=New-LanSingleInstance
    if (-not $instance.IsFirst) { return }
    # Before anything else, make sure the functions in memory match the files on disk. Replacing files
    # underneath a running window leaves the two out of step, and the symptom is an unhandled exception
    # from a timer calling a function that was never loaded — which reads as a random crash rather than
    # "the program is running an older copy of itself".
    $mismatch = Assert-LanCodeMatchesDisk -SourceRoot $PSScriptRoot
    if ($mismatch) {
        try {
            [Windows.Forms.MessageBox]::Show($mismatch,'LAN File Sharing',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch { }
        return
    }
    $restoreTimer=$null
    try {
        $form=New-LanMainForm -AutoLaunch:$AutoLaunch -SelectHost:$HostMode
        $restoreTimer=New-Object Windows.Forms.Timer
        $restoreTimer.Interval=250
        $restoreTimer.Add_Tick({
            # A second launch asks the first window to come back. Reach the form through the timer
            # ($this): a captured local can resolve to $null inside an event handler.
            $timer=$this
            if ($instance.Wake.WaitOne(0)) { Show-LanMainWindow -Form $timer.Tag }
        }.GetNewClosure())
        $restoreTimer.Tag=$form
        $restoreTimer.Start()
        [Windows.Forms.Application]::Run($form)
    } finally {
        try {
            [IO.File]::AppendAllText((Join-Path $env:LOCALAPPDATA 'LanFileSharing\launcher.log'), ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ui: window closed' + "`r`n"), [Text.Encoding]::UTF8)
        } catch { }
        if ($restoreTimer) { $restoreTimer.Stop(); $restoreTimer.Dispose() }
        Close-LanSingleInstance -Instance $instance
    }
}
