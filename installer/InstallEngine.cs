using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class InstallEngine
{
    private const string ResourceName = "LanFileSharing.Payload.zip";
    private const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LanFileSharing";
    // Replaced with the real number by installer/Build-Release.ps1 at build time.
    internal const string Version = "@VERSION@";
    private static string elevationSource;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string existing, string replacement, int flags);
    internal static string DefaultInstallRoot { get { return Environment.Is64BitOperatingSystem
        ? @"C:\Program Files\LanFileSharing" : @"C:\Program Files (x86)\LanFileSharing"; } }

    internal static string DetectExistingInstallRoot()
    {
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\LanFileSharing")) {
            if (key != null) {
                string value = key.GetValue("InstallRoot") as string;
                if (!string.IsNullOrWhiteSpace(value)) return value;
            }
        }
        string legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LanFileSharing");
        return File.Exists(Path.Combine(legacy, "HostWorker.ps1")) ? legacy : null;
    }

    internal static string NormalizeInstallRoot(string input)
    {
        if (string.IsNullOrWhiteSpace(input) || input.IndexOf('"') >= 0) throw new ArgumentException("กรุณาเลือกโฟลเดอร์ติดตั้งในไดรฟ์ภายในเครื่อง");
        string full = Path.GetFullPath(input.Trim()).TrimEnd('\\');
        if (full.Length < 4 || !char.IsLetter(full[0]) || full[1] != ':' || full[2] != '\\' ||
            !string.Equals(Path.GetFileName(full), "LanFileSharing", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("โฟลเดอร์ติดตั้งต้องอยู่ในไดรฟ์ภายในและลงท้ายด้วย LanFileSharing");
        return full;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try {
            if (args.Length == 1 && args[0] == "--verify") return 2;
            if (args.Length == 2 && args[0] == "--verify") {
                string stage = CreateStage(false);
                try { int count = VerifyAndExtract(stage); File.WriteAllText(args[1], "OK files=" + count, Encoding.UTF8); }
                finally { CleanupStage(stage, false); }
                return 0;
            }
            if (args.Length == 2 && args[0] == "--inspect") {
                File.WriteAllText(args[1], "Default=" + DefaultInstallRoot + "\r\nExisting=" + (DetectExistingInstallRoot() ?? ""), Encoding.UTF8);
                return 0;
            }
            if (args.Length == 2 && args[0] == "--audit") {
                if (!Path.IsPathRooted(args[1])) throw new ArgumentException("Audit report path must be absolute.");
                string report = Path.GetFullPath(args[1]);
                string reportDirectory = Path.GetDirectoryName(report);
                if (string.IsNullOrEmpty(reportDirectory) || !Directory.Exists(reportDirectory)) throw new DirectoryNotFoundException("Audit report directory does not exist.");
                string stage = CreateStage(false);
                try { VerifyAndExtract(stage); WriteAuditReport(stage, report); }
                finally { CleanupStage(stage, false); }
                return 0;
            }
            if (args.Length >= 5 && args[0] == "--elevated")
                return ElevatedInstall(args[1], args[2], args[3] == "1", args[4], args.Length > 5 ? args[5] : null,
                    args.Length > 6 ? int.Parse(args[6]) : 0, Array.IndexOf(args, "nodesktop") < 0);
            if (args.Length >= 5 && args[0] == "--elevated-bootstrap")
                return ElevatedBootstrap(args[1], args[2], args[3], args[4]);
            if (args.Length == 1 && args[0] == "--uninstall") {
                if (IsInstalledSetup(Assembly.GetExecutingAssembly().Location)) return LaunchTemporaryCopy("--uninstall-temp");
                Application.EnableVisualStyles(); Application.Run(new SetupForm(true)); return 0;
            }
            if (args.Length == 2 && (args[0] == "--uninstall-temp" || args[0] == "--setup-temp")) {
                if (!IsInstalledSetup(args[1])) throw new InvalidOperationException("The protected setup source no longer matches the installed application.");
                elevationSource = Path.GetFullPath(args[1]);
                try { Application.EnableVisualStyles(); Application.Run(new SetupForm(args[0] == "--uninstall-temp")); }
                finally { ScheduleUserTempCleanup(); }
                return 0;
            }
            if (args.Length != 0) throw new ArgumentException("Unknown setup argument.");
            if (IsInstalledSetup(Assembly.GetExecutingAssembly().Location)) return LaunchTemporaryCopy("--setup-temp");
            Application.EnableVisualStyles(); Application.Run(new SetupForm()); return 0;
        }
        catch (Exception error) {
            if (args.Length == 0 || (args.Length > 0 && (args[0] == "--uninstall" || args[0] == "--uninstall-temp" || args[0] == "--setup-temp")))
                MessageBox.Show(error.Message, "LAN File Sharing Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static int LaunchTemporaryCopy(string argument)
    {
        string temporary = Path.Combine(Path.GetTempPath(), "LanFileSharingSetup-" + Guid.NewGuid().ToString("N") + ".exe");
        File.Copy(Assembly.GetExecutingAssembly().Location, temporary);
        try { Process.Start(new ProcessStartInfo(temporary, argument + " \"" + Assembly.GetExecutingAssembly().Location + "\"") { UseShellExecute = true }); }
        catch { File.Delete(temporary); throw; }
        return 0;
    }

    private static bool IsInstalledSetup(string path)
    {
        string root = null;
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\LanFileSharing"))
            if (key != null) root = key.GetValue("InstallRoot") as string;
        return root != null && string.Equals(Path.GetFullPath(path),
            Path.GetFullPath(Path.Combine(root, "LanFileSharing-Setup.exe")), StringComparison.OrdinalIgnoreCase);
    }

    private static int ElevatedBootstrap(string pipeName, string target, string clean, string marker)
    {
        if (pipeName.Length < 20 || !pipeName.StartsWith("LanFileSharing-Setup-", StringComparison.Ordinal) ||
            (clean != "0" && clean != "1") || (marker != "setup" && marker != "uninstall")) return 2;
        if (!IsInstalledSetup(Assembly.GetExecutingAssembly().Location) ||
            !new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 3;
        string normalized = NormalizeInstallRoot(target);
        if (marker == "uninstall" && !string.Equals(normalized, DetectExistingInstallRoot(), StringComparison.OrdinalIgnoreCase)) return 2;
        string protectedStage = null;
        try {
            protectedStage = CreateStage(true);
            string protectedExe = Path.Combine(protectedStage, "bootstrap.exe");
            File.Copy(Assembly.GetExecutingAssembly().Location, protectedExe);
            var start = new ProcessStartInfo(protectedExe,
                "--elevated " + pipeName + " \"" + target + "\" " + clean + " " + marker + " \"" + protectedStage + "\" " + Process.GetCurrentProcess().Id);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process child = Process.Start(start)) {
                if (child == null) throw new IOException("Protected installer helper did not start.");
            }
            return 0;
        }
        catch (Exception error) {
            SendElevatedError(pipeName, error.Message);
            if (protectedStage != null) CleanupStage(protectedStage, true);
            return 1;
        }
    }

    private static void ScheduleUserTempCleanup()
    {
        string self = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
        string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\');
        if (!string.Equals(Path.GetDirectoryName(self), temp, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(self).StartsWith("LanFileSharingSetup-", StringComparison.Ordinal)) return;
        string command = "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '" + self.Replace("'", "''") + "' -Force -ErrorAction SilentlyContinue";
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -WindowStyle Hidden -EncodedCommand " + encoded);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
        using (Process cleanup = Process.Start(start)) { }
    }

    internal static string RunInteractiveInstall(string target, bool clean, bool desktopShortcut, Func<string, bool> confirm)
    {
        return RunInteractiveOperation(target, clean, false, desktopShortcut, confirm);
    }

    internal static string RunInteractiveUninstall(string target, Func<string, bool> confirm)
    {
        return RunInteractiveOperation(target, true, true, false, confirm);
    }

    private static string RunInteractiveOperation(string target, bool clean, bool uninstall, bool desktopShortcut, Func<string, bool> confirm)
    {
        target = NormalizeInstallRoot(target);
        string stage = CreateStage(false);
        Process child = null;
        try {
            VerifyAndExtract(stage);
            string pipeName = "LanFileSharing-Setup-" + Guid.NewGuid().ToString("N");
            using (var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, NewPipeSecurity())) {
                var start = new ProcessStartInfo();
                bool protectedBootstrap = elevationSource != null;
                start.FileName = protectedBootstrap ? elevationSource : Assembly.GetExecutingAssembly().Location;
                start.Arguments = (protectedBootstrap ? "--elevated-bootstrap " : "--elevated ") + pipeName + " \"" + target + "\" " + (clean ? "1" : "0") + (uninstall ? " uninstall" : " setup") + (desktopShortcut ? "" : " nodesktop");                start.UseShellExecute = true;
                start.Verb = "runas";
                start.WindowStyle = ProcessWindowStyle.Hidden;
                try { child = Process.Start(start); }
                catch (Win32Exception error) {
                    if (error.NativeErrorCode == 1223) throw new InvalidOperationException("ยกเลิก UAC แล้ว ไม่มีการล้างหรือเปลี่ยนการติดตั้ง", error);
                    throw;
                }
                IAsyncResult pending = pipe.BeginWaitForConnection(null, null);
                DateTime deadline = DateTime.UtcNow.AddMinutes(2);
                while (!pending.AsyncWaitHandle.WaitOne(200)) {
                    if (child.HasExited && (!protectedBootstrap || child.ExitCode != 0))
                        throw new InvalidOperationException("ตัวช่วยติดตั้งสิ้นสุดก่อนเชื่อมต่อ (รหัส " + child.ExitCode + ")");
                    if (DateTime.UtcNow > deadline) throw new TimeoutException("รอการเชื่อมต่อจากตัวช่วยติดตั้งนานเกินไป");
                }
                pipe.EndWaitForConnection(pending);
                using (var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, true))
                using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true }) {
                    string first = reader.ReadLine();
                    if (first == null) throw new IOException("ตัวช่วยติดตั้งปิดการเชื่อมต่อ");
                    if (first.StartsWith("ERROR|", StringComparison.Ordinal)) throw new InvalidOperationException(Decode(first.Substring(6)));
                    if (!first.StartsWith("READY|", StringComparison.Ordinal)) throw new IOException("ตัวช่วยติดตั้งส่งข้อมูลไม่ถูกต้อง");
                    string preview = Decode(first.Substring(6));
                    string userPreviewPath = null;
                    if (clean) {
                        string resetScript = Path.Combine(stage, "Reset-LanShare.ps1");
                        string userPreview = RunPowerShell(resetScript, "-Phase PreviewUser");
                        userPreviewPath = Path.Combine(stage, "current-user-preview.json");
                        File.WriteAllText(userPreviewPath, userPreview, new UTF8Encoding(false));
                        string userSummary = RunPowerShell(resetScript, "-Phase PreviewUserSummary");
                        preview += "\r\n" + userSummary + "\r\nCurrent-user startup preferences will be removed.";
                    }
                    if (!confirm(preview)) {
                        writer.WriteLine("ABORT");
                        child.WaitForExit(10000);
                        return "ยกเลิกก่อนเปลี่ยนการติดตั้ง";
                    }
                    try {
                        if (clean) RunCurrentUserReset(stage, userPreviewPath);
                    } catch {
                        writer.WriteLine("ABORT");
                        throw;
                    }
                    writer.WriteLine("GO");
                    string last = reader.ReadLine();
                    if (last == null) throw new IOException("ตัวช่วยติดตั้งสิ้นสุดโดยไม่ส่งผลลัพธ์");
                    if (last.StartsWith("ERROR|", StringComparison.Ordinal)) throw new InvalidOperationException(Decode(last.Substring(6)));
                    if (!last.StartsWith("DONE|", StringComparison.Ordinal)) throw new IOException("ผลลัพธ์จากตัวช่วยติดตั้งไม่ถูกต้อง");
                    if (!child.WaitForExit(30000) || child.ExitCode != 0) throw new InvalidOperationException("ตัวช่วยติดตั้งไม่จบสมบูรณ์");
                    return Decode(last.Substring(5));
                }
            }
        }
        finally {
            if (child != null) child.Dispose();
            CleanupStage(stage, false);
        }
    }

    private static int ElevatedInstall(string pipeName, string target, bool clean, string marker, string protectedSelfStage, int bootstrapPid, bool desktopShortcut)
    {
        if ((marker != "setup" && marker != "uninstall") || pipeName.Length < 20 || !pipeName.StartsWith("LanFileSharing-Setup-", StringComparison.Ordinal)) return 2;
        var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) return 3;
        string stage = null;
        NamedPipeClientStream pipe = null;
        StreamWriter writer = null;
        try {
            target = NormalizeInstallRoot(target);
            if (bootstrapPid > 0) {
                try {
                    using (Process bootstrap = Process.GetProcessById(bootstrapPid))
                        if (!bootstrap.WaitForExit(10000)) throw new TimeoutException("Protected setup launcher did not exit.");
                } catch (ArgumentException) { }
            }
            stage = CreateStage(true);
            VerifyAndExtract(stage);
            pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut);
            pipe.Connect(30000);
            var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, true);
            writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
            string preview = RunPowerShell(Path.Combine(stage, "Installer-Action.ps1"),
                "-Phase Preview -InstallRoot \"" + target + "\"" + (clean ? " -CleanReset" : "") + (marker == "uninstall" ? " -Uninstall" : ""));
            writer.WriteLine("READY|" + Encode(preview));
            string instruction = reader.ReadLine();
            if (instruction == "ABORT") return 4;
            if (instruction != "GO") throw new InvalidOperationException("Installer handshake was interrupted.");
            string result = RunPowerShell(Path.Combine(stage, "Installer-Action.ps1"),
                "-Phase " + (marker == "uninstall" ? "Uninstall" : "Apply") + " -InstallRoot \"" + target + "\"" + (clean ? " -CleanReset" : "") + (desktopShortcut ? "" : " -NoDesktopShortcut"));
            if (marker == "uninstall") RemoveUninstallRegistration(target);
            else RegisterUninstall(target);
            writer.WriteLine("DONE|" + Encode(result));
            return 0;
        }
        catch (Exception error) {
            if (writer != null) { try { writer.WriteLine("ERROR|" + Encode(error.Message)); } catch { } }
            else SendElevatedError(pipeName, error.Message);
            return 1;
        }
        finally {
            if (writer != null) writer.Dispose();
            if (pipe != null) pipe.Dispose();
            if (stage != null) CleanupStage(stage, true);
            if (protectedSelfStage != null) ScheduleProtectedSelfCleanup(protectedSelfStage);
        }
    }

    private static void SendElevatedError(string pipeName, string message)
    {
        try {
            using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut)) {
                pipe.Connect(2000);
                using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true })
                    writer.WriteLine("ERROR|" + Encode(message));
            }
        } catch { }
    }

    private static void ScheduleProtectedSelfCleanup(string protectedStage)
    {
        string self = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
        string full = Path.GetFullPath(protectedStage).TrimEnd('\\');
        string windowsTemp = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp")).TrimEnd('\\');
        if (!string.Equals(Path.GetDirectoryName(full), windowsTemp, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(full).StartsWith("LanFileSharingSetup-", StringComparison.Ordinal) ||
            !string.Equals(self, Path.Combine(full, "bootstrap.exe"), StringComparison.OrdinalIgnoreCase)) return;
        MoveFileEx(self, null, 4);
        MoveFileEx(full, null, 4);
    }

    private static void RegisterUninstall(string target)
    {
        string installedSetup = Path.Combine(target, "LanFileSharing-Setup.exe");
        if (!string.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location), Path.GetFullPath(installedSetup), StringComparison.OrdinalIgnoreCase))
            File.Copy(Assembly.GetExecutingAssembly().Location, installedSetup, true);
        var acl = new FileSecurity();
        acl.SetAccessRuleProtection(true, false);
        var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        acl.SetOwner(administrators);
        foreach (SecurityIdentifier sid in new[] { administrators, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
            FileSystemRights.ReadAndExecute, AccessControlType.Allow));
        File.SetAccessControl(installedSetup, acl);
        using (RegistryKey key = Registry.LocalMachine.CreateSubKey(UninstallKey)) {
            if (key == null) throw new IOException("Could not register the Windows uninstaller.");
            key.SetValue("DisplayName", "LAN File Sharing", RegistryValueKind.String);
            key.SetValue("DisplayVersion", Version, RegistryValueKind.String);
            key.SetValue("Publisher", "LAN File Sharing", RegistryValueKind.String);
            key.SetValue("InstallLocation", target, RegistryValueKind.String);
            key.SetValue("UninstallString", "\"" + installedSetup + "\" --uninstall", RegistryValueKind.String);
            key.SetValue("DisplayIcon", Path.Combine(target, @"icon\Tiger_Tech_Share_File.ico"), RegistryValueKind.String);
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
    }

    private static void RemoveUninstallRegistration(string expectedTarget)
    {
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(UninstallKey)) {
            if (key == null) return;
            string registered = key.GetValue("InstallLocation") as string;
            if (!string.Equals(NormalizeInstallRoot(registered), expectedTarget, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Windows uninstall entry points to another installation.");
        }
        Registry.LocalMachine.DeleteSubKeyTree(UninstallKey, false);
    }

    private static void RunCurrentUserReset(string stage, string previewPath)
    {
        string script = Path.Combine(stage, "Reset-LanShare.ps1");
        RunPowerShell(script, "-Phase CurrentUser -PreviewFile \"" + previewPath + "\"");
    }

    private static string RunPowerShell(string script, string arguments)
    {
        return RunPowerShell(script, arguments, 600000);
    }

    private static string RunPowerShell(string script, string arguments, int timeoutMilliseconds)
    {
        var start = new ProcessStartInfo();
        start.FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + arguments;
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.WorkingDirectory = Path.GetDirectoryName(script);
        using (var process = Process.Start(start)) {
            // Drain both pipes concurrently: reading stdout first can deadlock when
            // PowerShell fills stderr, before the old timeout is even reached.
            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeoutMilliseconds)) {
                try { process.Kill(); } catch (InvalidOperationException) { }
                throw new TimeoutException("PowerShell installation timed out.");
            }
            if (!System.Threading.Tasks.Task.WaitAll(new System.Threading.Tasks.Task[] { outputTask, errorTask }, 5000))
                throw new TimeoutException("PowerShell output did not close after installation.");
            string output = outputTask.Result;
            string errors = errorTask.Result;
            if (process.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(errors) ? "Installation command failed: " + output : errors.Trim());
            return output.Trim();
        }
    }

    private static string CreateStage(bool elevated)
    {
        string basePath = elevated ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp") : Path.GetTempPath();
        string stage = Path.Combine(basePath, "LanFileSharingSetup-" + Guid.NewGuid().ToString("N"));
        if (Directory.Exists(stage) || File.Exists(stage)) throw new IOException("A setup staging directory already exists.");
        if (elevated) {
            var acl = new DirectorySecurity();
            acl.SetAccessRuleProtection(true, false);
            var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            foreach (SecurityIdentifier sid in new SecurityIdentifier[] {
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }) {
                acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    inheritance, PropagationFlags.None, AccessControlType.Allow));
            }
            Directory.CreateDirectory(stage, acl);
        } else Directory.CreateDirectory(stage);
        if ((new DirectoryInfo(stage).Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Setup staging path is a reparse point.");
        return stage;
    }

    private static void CleanupStage(string stage, bool elevated)
    {
        string basePath = Path.GetFullPath(elevated ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp") : Path.GetTempPath()).TrimEnd('\\');
        string full = Path.GetFullPath(stage).TrimEnd('\\');
        if (!string.Equals(Path.GetDirectoryName(full).TrimEnd('\\'), basePath, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(full).StartsWith("LanFileSharingSetup-", StringComparison.Ordinal)) return;
        if (Directory.Exists(full) && (new DirectoryInfo(full).Attributes & FileAttributes.ReparsePoint) == 0)
            Directory.Delete(full, true);
    }

    private static int VerifyAndExtract(string stage)
    {
        using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName)) {
            if (resource == null) throw new InvalidDataException("Embedded application payload is missing.");
            using (var zip = new ZipArchive(resource, ZipArchiveMode.Read)) {
                var manifest = zip.GetEntry("manifest.sha256");
                if (manifest == null) throw new InvalidDataException("Payload checksum manifest is missing.");
                var expected = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                using (var reader = new StreamReader(manifest.Open(), Encoding.UTF8)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        if (line.Length < 67 || line[64] != ' ' || line[65] != ' ') throw new InvalidDataException("Invalid payload manifest line.");
                        string name = line.Substring(66);
                        ValidateRelativeName(name);
                        if (expected.ContainsKey(name)) throw new InvalidDataException("Duplicate payload name.");
                        expected.Add(name, line.Substring(0, 64).ToLowerInvariant());
                    }
                }
                int count = 0;
                foreach (ZipArchiveEntry entry in zip.Entries) {
                    if (entry.FullName == "manifest.sha256") continue;
                    ValidateRelativeName(entry.FullName);
                    string hash;
                    if (!expected.TryGetValue(entry.FullName, out hash)) throw new InvalidDataException("Unexpected payload file: " + entry.FullName);
                    byte[] content;
                    using (var memory = new MemoryStream()) { using (var input = entry.Open()) input.CopyTo(memory); content = memory.ToArray(); }
                    using (var sha = SHA256.Create()) {
                        string actual = BitConverter.ToString(sha.ComputeHash(content)).Replace("-", "").ToLowerInvariant();
                        if (!string.Equals(actual, hash, StringComparison.Ordinal)) throw new InvalidDataException("Payload checksum mismatch: " + entry.FullName);
                    }
                    string destination = Path.GetFullPath(Path.Combine(stage, entry.FullName.Replace('/', '\\')));
                    if (!destination.StartsWith(Path.GetFullPath(stage).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Payload path escapes staging directory.");
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.Write(content, 0, content.Length);
                    count++;
                }
                if (count != expected.Count) throw new InvalidDataException("Payload has missing files.");
                return count;
            }
        }
    }

    private static string JsonEscape(string value)
    {
        if (value == null) return "";
        var output = new StringBuilder();
        foreach (char character in value) {
            switch (character) {
                case '\\': output.Append("\\\\"); break;
                case '"': output.Append("\\\""); break;
                case '\r': output.Append("\\r"); break;
                case '\n': output.Append("\\n"); break;
                case '\t': output.Append("\\t"); break;
                default:
                    if (character < 32) output.Append("\\u" + ((int)character).ToString("x4"));
                    else output.Append(character);
                    break;
            }
        }
        return output.ToString();
    }

    private sealed class SignatureAuditResult
    {
        internal string Status;
        internal string Signer;
        internal bool TimestampPresent;
        internal bool TimestampValid;
    }

    private static Dictionary<string, SignatureAuditResult> ReadSignatureAudit(string stage)
    {
        string quoted = stage.Replace("'", "''");
        string command = "$root='" + quoted + "'; Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Extension -in @('.exe','.ps1','.psm1') } | ForEach-Object { " +
            "$s=Get-AuthenticodeSignature -LiteralPath $_.FullName; $r=$_.FullName.Substring($root.Length+1).Replace('\\','/'); " +
            "$rb=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($r)); $sb=if($s.SignerCertificate){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$s.SignerCertificate.Subject))}else{''}; " +
            "$tp=($null -ne $s.TimeStamperCertificate); $tv=([string]$s.Status -eq 'Valid' -and $tp); $rb+'|'+[string]$s.Status+'|'+$sb+'|'+$tp+'|'+$tv }";
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
        var results = new Dictionary<string, SignatureAuditResult>(StringComparer.OrdinalIgnoreCase);
        using (Process process = Process.Start(start)) {
            string stdout = process.StandardOutput.ReadToEnd();
            string stderr = process.StandardError.ReadToEnd();
            if (!process.WaitForExit(30000)) { process.Kill(); throw new TimeoutException("Payload signature audit timed out."); }
            if (process.ExitCode != 0) throw new InvalidDataException("Payload signature audit failed.");
            foreach (string raw in stdout.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)) {
                string[] parts = raw.Split('|');
                if (parts.Length != 5) throw new InvalidDataException("Payload signature audit returned malformed data.");
                string relative = Encoding.UTF8.GetString(Convert.FromBase64String(parts[0]));
                string signer = parts[2].Length == 0 ? "" : Encoding.UTF8.GetString(Convert.FromBase64String(parts[2]));
                results.Add(relative, new SignatureAuditResult {
                    Status=parts[1], Signer=signer,
                    TimestampPresent=string.Equals(parts[3], "True", StringComparison.OrdinalIgnoreCase),
                    TimestampValid=string.Equals(parts[4], "True", StringComparison.OrdinalIgnoreCase)
                });
            }
        }
        return results;
    }

    private static void WriteAuditReport(string stage, string reportPath)
    {
        string root = Path.GetFullPath(stage).TrimEnd('\\') + "\\";
        string[] files = Directory.GetFiles(stage, "*", SearchOption.AllDirectories);
        Array.Sort(files, StringComparer.OrdinalIgnoreCase);
        Dictionary<string, SignatureAuditResult> signatures = ReadSignatureAudit(stage);
        var json = new StringBuilder();
        json.Append("{\n  \"version\": \"").Append(JsonEscape(Version)).Append("\",\n  \"payloadInventoryVerified\": true,\n  \"files\": [\n");
        for (int index = 0; index < files.Length; index++) {
            string file = files[index];
            string relative = Path.GetFullPath(file).Substring(root.Length).Replace('\\', '/');
            string hash;
            using (var input = File.OpenRead(file))
            using (var sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
            SignatureAuditResult signature;
            bool signable = signatures.TryGetValue(relative, out signature);
            bool signed = signable && string.Equals(signature.Status, "Valid", StringComparison.Ordinal);
            string signer = signable ? signature.Signer : "";
            string signatureStatus = signable ? signature.Status : "NotApplicable";
            bool timestampPresent = signable && signature.TimestampPresent;
            bool timestampValid = signable && signature.TimestampValid;
            json.Append("    {\"path\":\"").Append(JsonEscape(relative)).Append("\",\"sha256\":\"").Append(hash)
                .Append("\",\"signed\":").Append(signed ? "true" : "false").Append(",\"signatureStatus\":\"").Append(JsonEscape(signatureStatus))
                .Append("\",\"signer\":\"").Append(JsonEscape(signer)).Append("\",\"timestampPresent\":").Append(timestampPresent ? "true" : "false")
                .Append(",\"timestampValid\":").Append(timestampValid ? "true" : "false").Append("}");
            if (index + 1 < files.Length) json.Append(',');
            json.Append('\n');
        }
        json.Append("  ]\n}\n");
        File.WriteAllText(reportPath, json.ToString(), new UTF8Encoding(false));
    }

    private static void ValidateRelativeName(string name)
    {
        if (string.IsNullOrEmpty(name) || name.StartsWith("/", StringComparison.Ordinal) || name.IndexOf('\\') >= 0 ||
            name.IndexOf(':') >= 0 || name.EndsWith("/", StringComparison.Ordinal) ||
            name.Split('/').Length == 0) throw new InvalidDataException("Invalid payload file name.");
        foreach (string part in name.Split('/')) if (part == "" || part == "." || part == "..") throw new InvalidDataException("Invalid payload path.");
    }

    private static PipeSecurity NewPipeSecurity()
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
        SecurityIdentifier admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(admins, PipeAccessRights.FullControl, AccessControlType.Allow));
        return security;
    }

    private static string Encode(string value) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? "")); }
    private static string Decode(string value) { return Encoding.UTF8.GetString(Convert.FromBase64String(value)); }
}
