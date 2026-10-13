using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

internal sealed class SetupForm : Form
{
    private readonly TextBox destination;
    private readonly CheckBox cleanReset;
    private readonly CheckBox desktopShortcut;
    private readonly Label status;
    private readonly Button install;
    private readonly CheckBox launchAfter;
    private readonly bool uninstallMode;

    internal SetupForm(bool uninstall = false)
    {
        uninstallMode = uninstall;
        Text = (uninstall ? "LAN File Sharing — Uninstall" : "LAN File Sharing — Setup") + " v" + InstallEngine.Version;
        // Tall enough for every control with a clear margin. The button used to sit far enough down that a
        // display scale above 100% cut it off, and the option rows were close enough together that one was
        // drawn over the note belonging to the row above.
        ClientSize = new Size(690, 458);
        MinimumSize = new Size(650, 474);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10f);
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        var logo = new PictureBox { Location = new Point(22, 14), Size = new Size(44, 44), SizeMode = PictureBoxSizeMode.Zoom };
        using (Stream stream = typeof(SetupForm).Assembly.GetManifestResourceStream("LanFileSharing.Brand.png")) {
            if (stream == null) throw new IOException("The setup logo is missing from this installer.");
            using (Image image = Image.FromStream(stream)) logo.Image = new Bitmap(image);
        }
        logo.Disposed += delegate { logo.Image.Dispose(); };
        Controls.Add(logo);

        var title = new Label { Text = uninstall ? "ถอนการติดตั้ง LAN File Sharing และล้างค่าของโปรแกรม" : "ติดตั้ง LAN File Sharing ทั้งเครื่องผู้แชร์และเครื่องผู้ใช้ไฟล์", AutoSize = true, Location = new Point(76, 23) };
        Controls.Add(title);
        var pathLabel = new Label { Text = "ตำแหน่งติดตั้ง", AutoSize = true, Location = new Point(22, 68) };
        Controls.Add(pathLabel);
        destination = new TextBox { Location = new Point(22, 92), Width = 545, Text = InstallEngine.DefaultInstallRoot };
        Controls.Add(destination);
        var browse = new Button { Text = "เลือก...", Location = new Point(580, 90), Size = new Size(88, 29) };
        browse.Click += delegate {
            using (var dialog = new FolderBrowserDialog()) {
                dialog.Description = "เลือกโฟลเดอร์แม่สำหรับ LanFileSharing";
                if (dialog.ShowDialog(this) == DialogResult.OK) {
                    destination.Text = string.Equals(Path.GetFileName(dialog.SelectedPath.TrimEnd('\\')), "LanFileSharing", StringComparison.OrdinalIgnoreCase)
                        ? dialog.SelectedPath : Path.Combine(dialog.SelectedPath, "LanFileSharing");
                }
            }
        };
        Controls.Add(browse);

        var existing = new Label { AutoSize = false, Location = new Point(22, 136), Size = new Size(640, 44) };
        string found = InstallEngine.DetectExistingInstallRoot();
        existing.Text = found == null ? "ไม่พบตำแหน่งติดตั้งเดิมที่บันทึกไว้" : "พบการติดตั้งเดิม: " + found;
        Controls.Add(existing);
        if (!uninstall && found != null) destination.Text = found;
        if (uninstall) {
            destination.Text = found ?? InstallEngine.DefaultInstallRoot;
            destination.ReadOnly = true;
            browse.Enabled = false;
        }
        cleanReset = new CheckBox { Text = "ล้างการตั้งค่าของโปรแกรมเดิมก่อนติดตั้ง (Set zero)", Location = new Point(22, 190), AutoSize = true, Checked = true };
        if (uninstall) {
            // During an uninstall this choice is not a choice: the state in ProgramData and the settings this
            // program created are removed as part of removing the program. Saying so plainly is better than a
            // disabled box whose meaning the user has to guess.
            cleanReset.Text = "ลบการตั้งค่าของโปรแกรมในเครื่องนี้และบัญชี Windows ปัจจุบัน (ทำอัตโนมัติ)";
            cleanReset.Enabled = false;
        }
        Controls.Add(cleanReset);
        var note = new Label {
            Text = "ลบเฉพาะแชร์, Map Drive และค่าที่โปรแกรมสร้าง  ไฟล์ต้นฉบับที่แชร์จะไม่ถูกลบ",
            Location = new Point(42, 219), Size = new Size(620, 31)
        };
        Controls.Add(note);
        desktopShortcut = new CheckBox {
            Text = "สร้าง Shortcut ของโปรแกรมที่หน้า Desktop",
            Location = new Point(22, 248), AutoSize = true, Checked = !uninstall
        };
        if (uninstall) { desktopShortcut.Text = "ลบ Shortcut ที่หน้า Desktop ด้วย"; desktopShortcut.Enabled = false; }
        Controls.Add(desktopShortcut);
        // This note belongs to the shortcut box directly above it, so it sits between that box and the next
        // one. It used to be placed at the same height as the box below it: the two overlapped by sixteen
        // pixels and the checkbox was drawn over the note, which is why the third line of the uninstall page
        // read as clipped, unrelated text.
        var shortcutNote = new Label {
            Text = "Shortcut นี้สร้างไว้สำหรับทุกบัญชี Windows บนเครื่องนี้",
            Location = new Point(42, 272), Size = new Size(620, 24)
        };
        if (uninstall) { shortcutNote.Text = ""; }
        Controls.Add(shortcutNote);
        // Starting the program straight after setup is what most people want, so the box is ticked by default.
        // There is nothing to start after an uninstall, so that box is not shown at all rather than shown
        // disabled — a disabled control invites the question this form should not have to answer.
        if (!uninstall) {
            launchAfter = new CheckBox {
                Text = "เปิดโปรแกรม LAN File Sharing หลังจากกด Finish",
                Location = new Point(22, 302), AutoSize = true, Checked = true
            };
            Controls.Add(launchAfter);
        }
        // English wording for the action button, as requested: Install first, Finish once the work is done.
        // The button sits higher than the window needs so it keeps a clear margin at the bottom: with a long
        // status message and a display scale above 100% it was the one control that could be cut off.
        install = new Button { Text = uninstall ? "Uninstall" : "Install", Location = new Point(22, 336), Size = new Size(125, 38) };
        install.Click += OnInstall;
        Controls.Add(install);
        status = new Label { Text = uninstall ? "พร้อมถอนการติดตั้ง" : "พร้อมติดตั้ง", Location = new Point(165, 336), Size = new Size(500, 90) };
        Controls.Add(status);
        // No preview panel.
        //
        // The list of what would change used to appear in a Yes/No box before the work started. Removing the box
        // was right — pressing the button is the confirmation — but replacing it with a panel on the form put a
        // wall of internal detail beside the options, which the owner asked to be taken away. The page already
        // states the install location and the options, and the outcome is reported in the status line.
    }

    private bool completed;

    private void OnInstall(object sender, EventArgs e)
    {
        // After the work is done the same button closes the window, and it says Finish. Before that it
        // starts the work and says Install. Both are full sentences the user can act on, instead of one
        // button whose meaning changes silently.
        if (completed)
        {
            // The program is started on the way out, not before: it has to run after setup has finished
            // touching the files, and the choice belongs to the button that says Finish. The box does not exist
            // on the uninstall page, so it is checked for null rather than assumed.
            if (!uninstallMode && launchAfter != null && launchAfter.Checked) { StartApplication(); }
            Close();
            return;
        }
        string target;
        try { target = InstallEngine.NormalizeInstallRoot(destination.Text); }
        catch (Exception error) { MessageBox.Show(this, error.Message, "ตำแหน่งติดตั้ง", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        bool clean = cleanReset.Checked;
        bool desktop = desktopShortcut.Checked;
        install.Enabled = false;
        install.Text = uninstallMode ? "Uninstalling..." : "Installing...";
        status.Text = uninstallMode ? "กำลังตรวจรายการและขอสิทธิ์ผู้ดูแลระบบ..." : "กำลังตรวจไฟล์และขอสิทธิ์ผู้ดูแลระบบ...";
        ThreadPool.QueueUserWorkItem(delegate {
            string result;
            try {
                // Pressing the button is the confirmation.
                //
                // Pressing the button is the confirmation.
                //
                // A Yes/No box used to appear with a list of what would change, which the owner asked to be
                // removed: the page already shows the install location and the options, and the button says
                // Install or Uninstall. Asking again made a deliberate press feel like it had not registered.
                // The list itself is not shown either — it was internal detail (existing code, task state,
                // mapped drives) that does not belong on a page the user is trying to finish.
                Func<string, bool> confirm = delegate(string preview) {
                    return true;
                };
                result = uninstallMode ? InstallEngine.RunInteractiveUninstall(target, confirm)
                    : InstallEngine.RunInteractiveInstall(target, clean, desktop, confirm);
                BeginInvoke((MethodInvoker)delegate {
                    status.Text = result;
                    MessageBox.Show(this, result, "LAN File Sharing", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    completed = true;
                    install.Text = "Finish";
                    install.Enabled = true;
                });
            }
            catch (Exception error) {
                result = error.Message;
                BeginInvoke((MethodInvoker)delegate {
                    status.Text = result;
                    MessageBox.Show(this, result, uninstallMode ? "ถอนการติดตั้งไม่สำเร็จ" : "ติดตั้งไม่สำเร็จ", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    // Disabled after a failure? No: the button is enabled again in finally below so the
                    // user can fix the reason and press Install once more.
                });
            }
            finally { BeginInvoke((MethodInvoker)delegate { if (!completed) { install.Enabled = true; install.Text = uninstallMode ? "Uninstall" : "Install"; } }); }
        });
    }

    private void StartApplication()
    {
        // Starts the installed launcher the way the shortcut does. A failure here is reported but never
        // prevents the setup from being finished: the program is already installed and can be opened from
        // the Desktop shortcut or the Start menu.
        try
        {
            string launcher = Path.Combine(destination.Text.Trim(), "LanFileSharing.exe");
            if (!File.Exists(launcher)) {
                MessageBox.Show(this, "ไม่พบโปรแกรมที่ติดตั้งไว้: " + launcher, "เปิดโปรแกรม",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(launcher) {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(launcher)
            });
        }
        catch (Exception error) {
            MessageBox.Show(this, error.Message, "เปิดโปรแกรมไม่สำเร็จ", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }
}
