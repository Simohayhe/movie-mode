// movie-mode GUI
//
// コンソールセッションへの切り替えと状態確認をひとつのウィンドウにまとめたもの。
// マニフェストで requireAdministrator を要求しているため、起動時点でUACが出る。
// 以降 tscon 用のSYSTEMタスク作成も追加のプロンプトなしで行える。
//
// ビルド:
//   csc.exe /target:winexe /out:MovieMode.exe /win32icon:movie-mode.ico
//           /win32manifest:movie-mode.manifest
//           /reference:System.dll /reference:System.Drawing.dll
//           /reference:System.Windows.Forms.dll MovieModeGui.cs

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class Native
{
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("kernel32.dll")]
    public static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentProcessId();

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum,
                                                 ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
}

class MainForm : Form
{
    static readonly Color BG     = Color.FromArgb(20, 22, 26);
    static readonly Color PANEL  = Color.FromArgb(28, 31, 38);
    static readonly Color LINE   = Color.FromArgb(44, 49, 59);
    static readonly Color FG     = Color.FromArgb(230, 232, 236);
    static readonly Color DIM    = Color.FromArgb(154, 163, 178);
    static readonly Color ACCENT = Color.FromArgb(91, 157, 255);
    static readonly Color OK     = Color.FromArgb(108, 196, 139);
    static readonly Color WARN   = Color.FromArgb(224, 164, 88);

    readonly string dir;
    Label lblSession, lblRes, lblAdapter, lblNvenc, lblVerdict;
    TextBox log;
    Button btnGo, btnDry, btnRefresh, btnRemote;

    public MainForm()
    {
        dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        Text = "映画モード";
        ClientSize = new Size(560, 540);
        MinimumSize = new Size(500, 460);
        BackColor = BG;
        ForeColor = FG;
        Font = new Font("Yu Gothic UI", 9F);
        StartPosition = FormStartPosition.CenterScreen;
        try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

        var status = new Panel {
            Location = new Point(16, 16), Size = new Size(528, 132),
            BackColor = PANEL, BorderStyle = BorderStyle.FixedSingle
        };
        Controls.Add(status);

        lblSession = AddRow(status, "セッション", 12);
        lblRes     = AddRow(status, "解像度",     34);
        lblAdapter = AddRow(status, "描画アダプタ", 56);
        lblNvenc   = AddRow(status, "NVENC",      78);

        lblVerdict = new Label {
            Location = new Point(14, 104), Size = new Size(500, 20),
            ForeColor = DIM, Text = ""
        };
        status.Controls.Add(lblVerdict);

        btnGo = MakeButton("映画モードにする", new Point(16, 162), new Size(340, 54), true);
        btnGo.Click += (s, e) => RunScript("-Yes", true);
        Controls.Add(btnGo);

        btnRefresh = MakeButton("状態を更新", new Point(364, 162), new Size(180, 54), false);
        btnRefresh.Click += (s, e) => Refresh2();
        Controls.Add(btnRefresh);

        btnDry = MakeButton("事前チェック（移動しない）", new Point(16, 226), new Size(264, 40), false);
        btnDry.Click += (s, e) => RunScript("-Yes -DryRun", false);
        Controls.Add(btnDry);

        btnRemote = MakeButton("リモコンを開く", new Point(288, 226), new Size(256, 40), false);
        btnRemote.Click += (s, e) => OpenRemote();
        Controls.Add(btnRemote);

        var lblLog = new Label {
            Location = new Point(16, 276), Size = new Size(200, 18),
            ForeColor = DIM, Text = "ログ"
        };
        Controls.Add(lblLog);

        log = new TextBox {
            Location = new Point(16, 296), Size = new Size(528, 224),
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
            BackColor = Color.FromArgb(16, 18, 22), ForeColor = DIM,
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Consolas", 8.5F)
        };
        Controls.Add(log);

        Resize += (s, e) => {
            status.Width = ClientSize.Width - 32;
            log.Width = ClientSize.Width - 32;
            log.Height = ClientSize.Height - 316;
            btnRemote.Left = ClientSize.Width - 16 - btnRemote.Width;
            btnRefresh.Left = ClientSize.Width - 16 - btnRefresh.Width;
            btnGo.Width = btnRefresh.Left - 24;
        };

        Shown += (s, e) => Refresh2();
    }

    Label AddRow(Control parent, string caption, int y)
    {
        parent.Controls.Add(new Label {
            Location = new Point(14, y), Size = new Size(96, 18),
            ForeColor = DIM, Text = caption
        });
        var v = new Label {
            Location = new Point(116, y), Size = new Size(392, 18),
            ForeColor = FG, Text = "..."
        };
        parent.Controls.Add(v);
        return v;
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

    // ------------------------------------------------------------- 状態取得
    void Refresh2()
    {
        uint sid;
        Native.ProcessIdToSessionId(Native.GetCurrentProcessId(), out sid);
        uint console = Native.WTSGetActiveConsoleSessionId();
        bool onConsole = sid == console;

        int w = Native.GetSystemMetrics(0), h = Native.GetSystemMetrics(1);
        string res = w + "x" + h;

        var dd = new Native.DISPLAY_DEVICE();
        dd.cb = Marshal.SizeOf(dd);
        string adapter = Native.EnumDisplayDevices(null, 0, ref dd, 0) ? dd.DeviceString : "(不明)";

        int enc = NvencSessions();

        lblSession.Text = onConsole
            ? "コンソール (id " + sid + ")"
            : "RDP (id " + sid + " / コンソールは " + console + ")";
        lblSession.ForeColor = onConsole ? OK : WARN;

        lblRes.Text = res;
        lblRes.ForeColor = (res == "1920x1080") ? OK : WARN;

        lblAdapter.Text = adapter;
        lblAdapter.ForeColor = adapter.Contains("Remote Display") ? WARN : OK;

        lblNvenc.Text = enc < 0 ? "不明 (nvidia-smi なし)" : "Active Sessions = " + enc;
        lblNvenc.ForeColor = enc > 0 ? OK : DIM;

        if (onConsole && res == "1920x1080")
        {
            lblVerdict.Text = "理想状態です。";
            lblVerdict.ForeColor = OK;
            btnGo.Enabled = false;
            btnGo.Text = "既にコンソールセッション";
        }
        else
        {
            lblVerdict.Text = onConsole
                ? "コンソールですが解像度が 1920x1080 ではありません。"
                : "RDPセッションです。キャプチャ元が劣化しています。";
            lblVerdict.ForeColor = WARN;
            btnGo.Enabled = true;
            btnGo.Text = "映画モードにする";
        }
    }

    int NvencSessions()
    {
        try
        {
            var psi = new ProcessStartInfo("nvidia-smi", "-q -d ENCODER_STATS") {
                UseShellExecute = false, RedirectStandardOutput = true,
                CreateNoWindow = true
            };
            using (var p = Process.Start(psi))
            {
                string outp = p.StandardOutput.ReadToEnd();
                p.WaitForExit(5000);
                foreach (var line in outp.Split('\n'))
                    if (line.Contains("Active Sessions"))
                    {
                        var parts = line.Split(':');
                        int n;
                        if (parts.Length > 1 && int.TryParse(parts[1].Trim(), out n)) return n;
                    }
            }
        }
        catch { }
        return -1;
    }

    // ------------------------------------------------------------- 実行
    void RunScript(string args, bool warnDisconnect)
    {
        string ps1 = Path.Combine(dir, "movie-mode.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("movie-mode.ps1 が見つかりません。\n\n" + ps1, "映画モード",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        if (warnDisconnect)
        {
            var r = MessageBox.Show(
                "コンソールセッションへ移動します。\n\n" +
                "・RDP接続は切断されます\n" +
                "・Discordの画面共有は継続します\n" +
                "・配信を開始してから実行してください\n\n" +
                "実行しますか?",
                "映画モード", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (r != DialogResult.OK) return;
        }

        btnGo.Enabled = btnDry.Enabled = false;
        Say("---- " + DateTime.Now.ToString("HH:mm:ss") + " 実行: " + args + " ----");

        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -File \"" + ps1 + "\" " + args)
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
            btnGo.Enabled = btnDry.Enabled = true;
            Say("---- 終了 ----");
            Refresh2();
        }));

        try
        {
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            btnGo.Enabled = btnDry.Enabled = true;
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
                // UDPのconnectは実際にはパケットを出さない。
                // 外向きに使われるインターフェースのアドレスを得るための定石。
                s.Connect("8.8.8.8", 65530);
                var ep = s.LocalEndPoint as System.Net.IPEndPoint;
                if (ep != null) return ep.Address.ToString();
            }
        }
        catch { }
        return "127.0.0.1";
    }

    static bool RemoteRunning()
    {
        try
        {
            var props = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties();
            foreach (var ep in props.GetActiveTcpListeners())
                if (ep.Port == 8900) return true;
        }
        catch { }
        return false;
    }

    void OpenRemote()
    {
        string localUrl = "http://127.0.0.1:8900/";
        string lanUrl = "http://" + LanIPv4() + ":8900/";

        if (!RemoteRunning())
        {
            Say("リモコンが起動していません。");
            Say("Movie-Remote.cmd で単発起動するか、install-autostart.ps1 で常駐登録してください。");
            MessageBox.Show(
                "リモコンが起動していません。\n\n" +
                "他の端末のブラウザから操作するには、常駐登録が必要です:\n" +
                "  install-autostart.ps1 を実行\n\n" +
                "これによりログオン時に昇格状態で自動起動し、\n" +
                "ファイアウォール(TCP 8900)も開きます。",
                "映画モード", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        try { Process.Start(localUrl); Say("リモコンを開きました。"); }
        catch (Exception ex) { Say("ブラウザを開けません: " + ex.Message); }

        Say("他の端末からは次のURLでアクセスします:");
        Say("  " + lanUrl);
        try
        {
            Clipboard.SetText(lanUrl);
            Say("(このURLをクリップボードにコピーしました。RDPのクリップボード共有経由で");
            Say(" 手元のPCに貼り付けられます)");
        }
        catch { }
    }
}

static class Program
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}
