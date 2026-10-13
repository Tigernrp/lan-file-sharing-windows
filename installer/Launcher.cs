using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Launcher
{
    /// <summary>
    /// Appends one line to %LOCALAPPDATA%\LanFileSharing\launcher.log. Logging must never stop
    /// the application from starting, so every failure here is swallowed.
    /// </summary>
    private static void Log(string message)
    {
        try
        {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanFileSharing");
            Directory.CreateDirectory(directory);
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine;
            File.AppendAllText(Path.Combine(directory, "launcher.log"), line, new UTF8Encoding(false));
        }
        catch { }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = Path.GetDirectoryName(typeof(Launcher).Assembly.Location);
            string script = Path.Combine(root, "LanShare.ps1");
            bool automatic = args.Length == 1 && string.Equals(args[0], "--auto", StringComparison.OrdinalIgnoreCase);
            Log("start args=[" + string.Join(",", args) + "] automatic=" + automatic + " root=" + root);
            if (!File.Exists(script)) throw new FileNotFoundException("LanShare.ps1 is missing from the installed application.");
            if (args.Length > 0 && !automatic) throw new ArgumentException("Unknown launcher argument.");
            var start = new ProcessStartInfo();
            start.FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            start.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\"" + (automatic ? " -AutoLaunch" : "");
            start.WorkingDirectory = root;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            // Windows PowerShell must load its own built-ins even when launched
            // from an application whose environment contains PowerShell 7 modules.
            start.EnvironmentVariables["PSModulePath"] =
                Path.Combine(Path.GetDirectoryName(start.FileName), "Modules") + ";" +
                (Environment.GetEnvironmentVariable("PSModulePath") ?? "");
            using (var process = Process.Start(start))
                Log("started powershell pid=" + process.Id);
            return 0;
        }
        catch (Exception error)
        {
            Log("FAILED " + error.GetType().Name + ": " + error.Message);
            MessageBox.Show(error.Message, "LAN File Sharing", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
