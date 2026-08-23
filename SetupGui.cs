// movie-mode セットアップ
//
// 実処理は install-autostart.ps1 に任せ、この exe は GUI と昇格だけを担当する。
// 同じ処理を二重に実装すると片方が腐るため、スクリプト側を唯一の実装としている。
//
// ビルド:
//   csc.exe /target:winexe /out:Setup.exe /win32icon:movie-mode.ico
//           /win32manifest:setup.manifest
//           /reference:System.dll /reference:System.Drawing.dll
//           /reference:System.Windows.Forms.dll SetupGui.cs

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

class SetupForm : Form
{
    static readonly Color BG     = Color.FromArgb(20, 22, 26);
    static readonly Color PANEL  = Color.FromArgb(28, 31, 38);
    static readonly Color LINE   = Color.FromArgb(44, 49, 59);
    static readonly Color FG     = Color.FromArgb(230, 232, 236);
    static readonly Color DIM    = Color.FromArgb(154, 163, 178);
    static readonly Color ACCENT = Color.FromArgb(91, 157, 255);

    readonly string dir;
    CheckBox cbTask, cbFirewall, cbShortcut;
    Button btnInstall, btnUninstall, btnCopyUrl;
    TextBox log;

    public SetupForm()
    {
        dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        Text = "映画モード セットアップ";
        ClientSize = new Size(560, 540);
        MinimumSize = new Size(520, 480);
        BackColor = BG;
        ForeColor = FG;
        Font = new Font("Yu Gothic UI", 9F);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.Sizable;
        try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

        var head = new Label {
            Location = new Point(16, 14), Size = new Size(528, 44),
            ForeColor = DIM,
            Text = "別の端末のブラウザから映画モードに切り替えられるようにします。\n" +
                   "リモコンを昇格状態で常駐させ、通信を許可し、ショートカットを作成します。"
        };
        Controls.Add(head);

        var box = new Panel {
            Location = new Point(16, 66), Size = new Size(528, 106),
            BackColor = PANEL, BorderStyle = BorderStyle.FixedSingle
        };
        Controls.Add(box);

        cbTask = MakeCheck(box, "リモコンを常駐登録する（ログオン時・最上位の特権）", 12);
        cbFirewall = MakeCheck(box, "ファイアウォールで TCP 8900 の受信を許可する", 42);
        cbShortcut = MakeCheck(box, "デスクトップとスタートメニューにショートカットを作る", 72);

        btnInstall = MakeButton("インストール", new Point(16, 186), new Size(250, 46), true);
        btnInstall.Click += (s, e) => Run(false);
        Controls.Add(btnInstall);

        btnUninstall = MakeButton("アンインストール", new Point(274, 186), new Size(150, 46), false);
        btnUninstall.Click += (s, e) => {
            var r = MessageBox.Show(
                "常駐タスク・ファイアウォール規則・ショートカットを削除します。\n" +
                "プログラム本体のファイルは残ります。\n\n実行しますか?",
                "アンインストール", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (r == DialogResult.OK) Run(true);
        };
        Controls.Add(btnUninstall);

        btnCopyUrl = MakeButton("リモコンURLをコピー", new Point(432, 186), new Size(112, 46), false);
        btnCopyUrl.Click += (s, e) => CopyUrl();
        Controls.Add(btnCopyUrl);

        var lblLog = new Label {
            Location = new Point(16, 242), Size = new Size(200, 18),
            ForeColor = DIM, Text = "ログ"
        };
        Controls.Add(lblLog);

        log = new TextBox {
            Location = new Point(16, 262), Size = new Size(528, 258),
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
            BackColor = Color.FromArgb(16, 18, 22), ForeColor = DIM,
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Consolas", 8.5F)
        };
        Controls.Add(log);

        Resize += (s, e) => {
            int w = ClientSize.Width - 32;
            head.Width = w; box.Width = w; log.Width = w;
            log.Height = ClientSize.Height - 282;
            btnCopyUrl.Left = ClientSize.Width - 16 - btnCopyUrl.Width;
            btnUninstall.Left = btnCopyUrl.Left - 8 - btnUninstall.Width;
            btnInstall.Width = btnUninstall.Left - 24;
        };

        Shown += (s, e) => {
            Say("インストール先: " + dir);
            if (!File.Exists(Path.Combine(dir, "install-autostart.ps1")))
                Say("! install-autostart.ps1 が見つかりません。展開先を確認してください。");
        };
    }

    CheckBox MakeCheck(Control parent, string text, int y)
    {
        var c = new CheckBox {
            Text = text, Checked = true,
            Location = new Point(14, y), Size = new Size(500, 24),
            ForeColor = FG, FlatStyle = FlatStyle.Flat
        };
        parent.Controls.Add(c);
        return c;
    }

    Button MakeButton(string text, Point p, Size s, bool primary)
    {
        var b = new Button {
            Text = text, Location = p, Size = s,
            FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Color.FromArgb(31, 47, 69) : PANEL,
            ForeColor = FG,
            Font = new Font("Yu Gothic UI", primary ? 11F : 9F,
                            primary ? FontStyle.Bold : FontStyle.Regular)
        };
        b.FlatAppearance.BorderColor = primary ? ACCENT : LINE;
        b.FlatAppearance.BorderSize = 1;
        return b;
    }

    void Say(string line)
    {
        if (log.InvokeRequired) { log.BeginInvoke((Action)(() => Say(line))); return; }
        log.AppendText(line + Environment.NewLine);
    }

    void Run(bool uninstall)
    {
        string ps1 = Path.Combine(dir, "install-autostart.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("install-autostart.ps1 が見つかりません。\n\n" + ps1,
                "セットアップ", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var args = new StringBuilder();
        args.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(ps1).Append("\"");
        if (uninstall) args.Append(" -Uninstall");
        else
        {
            if (!cbTask.Checked)     args.Append(" -SkipTask");
            if (!cbFirewall.Checked) args.Append(" -SkipFirewall");
            if (!cbShortcut.Checked) args.Append(" -SkipShortcuts");
        }

        btnInstall.Enabled = btnUninstall.Enabled = false;
        Say("");
        Say("---- " + DateTime.Now.ToString("HH:mm:ss") + (uninstall ? " アンインストール" : " インストール") + " ----");

        var psi = new ProcessStartInfo("powershell.exe", args.ToString())
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = dir,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        proc.OutputDataReceived += (s, e) => { if (e.Data != null) Say(e.Data); };
        proc.ErrorDataReceived  += (s, e) => { if (e.Data != null) Say("! " + e.Data); };
        proc.Exited += (s, e) => BeginInvoke((Action)(() => {
            btnInstall.Enabled = btnUninstall.Enabled = true;
            Say("---- 終了 ----");
        }));

        try
        {
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            btnInstall.Enabled = btnUninstall.Enabled = true;
            Say("起動に失敗: " + ex.Message);
        }
    }

    static string LanIPv4()
    {
        try
        {
            using (var s = new System.Net.Sockets.Socket(
                       System.Net.Sockets.AddressFamily.InterNetwork,
                       System.Net.Sockets.SocketType.Dgram, 0))
            {
                // UDPのconnectは実際にはパケットを出さない
                s.Connect("8.8.8.8", 65530);
                var ep = s.LocalEndPoint as System.Net.IPEndPoint;
                if (ep != null) return ep.Address.ToString();
            }
        }
        catch { }
        return "127.0.0.1";
    }

    void CopyUrl()
    {
        string tokenFile = Path.Combine(dir, "remote-token.txt");
        if (!File.Exists(tokenFile))
        {
            Say("トークンがまだありません。先にインストールしてリモコンを起動してください。");
            return;
        }
        string token = File.ReadAllText(tokenFile).Trim();
        string url = "http://" + LanIPv4() + ":8900/" + (token.Length > 0 ? "?t=" + token : "");
        try
        {
            Clipboard.SetText(url);
            Say("クリップボードにコピーしました:");
            Say("  " + url);
            Say("(RDPのクリップボード共有経由で手元のPCに貼り付けられます)");
        }
        catch (Exception ex) { Say("コピーに失敗: " + ex.Message); }
    }
}

static class SetupProgram
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new SetupForm());
    }
}
