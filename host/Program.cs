// 电脑体检台 原生薄壳 v1.2.0（片1 形态片 · WinForms + WebView2）
// 职责：单实例锁 → 隐藏起 server.ps1 -NoBrowser -PortFile <tmp> → 端口就绪后 WebView2 导航
//       → 窗口标题「电脑体检台」→ 关窗先 /api/bye 优雅退、超时 taskkill 杀 server 进程树。
// 编译：build.ps1 调 csc.exe（.NET Framework 4.x 免 SDK），详见 build.ps1 新形态出口。
// 判定层零依赖：壳只起进程+导航，不碰 engine/checks/trees 语义。

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DiagHost
{
    internal static class Program
    {
        internal const string AppTitle = "电脑体检台";
        private static Mutex _mutex;

        [STAThread]
        private static void Main()
        {
            bool createdNew;
            _mutex = new Mutex(true, @"Local\DiagHealthHost_SingleInstance", out createdNew);
            if (!createdNew)
            {
                // 已在跑：把已有窗口提到前台，不开第二个 server
                IntPtr hwnd = Native.FindWindow(null, AppTitle);
                if (hwnd != IntPtr.Zero)
                {
                    Native.ShowWindow(hwnd, Native.SW_RESTORE);
                    Native.SetForegroundWindow(hwnd);
                }
                else
                {
                    MessageBox.Show("电脑体检台已经在运行，请看任务栏。", AppTitle,
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                return;
            }
            try
            {
                Native.SetProcessDPIAware();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                RunApp();
            }
            finally
            {
                try { _mutex.ReleaseMutex(); } catch { }
                _mutex.Dispose();
            }
        }

        private static void RunApp()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string serverPs1 = Path.Combine(baseDir, "server.ps1");
            if (!File.Exists(serverPs1))
            {
                MessageBox.Show("程序文件不完整（缺 server.ps1），请重新安装电脑体检台。\r\n位置：" + baseDir,
                    AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // WebView2 运行库探测（缺=开官方下载页引导，片5 真机样本再验异机分支）
            string wv2Ver = null;
            try { wv2Ver = CoreWebView2Environment.GetAvailableBrowserVersionString(null); } catch { }
            if (string.IsNullOrEmpty(wv2Ver))
            {
                DialogResult dr = MessageBox.Show(
                    "本机缺少网页内核（Edge WebView2），电脑体检台需要它来显示界面。\r\n\r\n点「是」打开官方下载页，装完后再双击体检台图标即可。",
                    AppTitle, MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (dr == DialogResult.Yes)
                {
                    try { Process.Start(new ProcessStartInfo("https://go.microsoft.com/fwlink/p/?LinkId=2124703") { UseShellExecute = true }); } catch { }
                }
                return;
            }

            // 隐藏起 server.ps1（随机端口写 PortFile；CreateNoWindow 不闪黑框）
            string portFile = Path.Combine(Path.GetTempPath(),
                "diag-host-port-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp");
            try { if (File.Exists(portFile)) File.Delete(portFile); } catch { }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + serverPs1 +
                            "\" -NoBrowser -PortFile \"" + portFile + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = baseDir,
            };
            Process server = null;
            try { server = Process.Start(psi); }
            catch (Exception ex)
            {
                MessageBox.Show("启动体检引擎失败：" + ex.Message, AppTitle,
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                CleanupPortFile(portFile);
                return;
            }

            MainForm form = new MainForm(server, portFile);
            try
            {
                Application.Run(form);
            }
            finally
            {
                ShutdownServer(server, form.BaseUrl);
                CleanupPortFile(portFile);
            }
        }

        // 关窗收尾：先 /api/bye 让 server 自杀（宽限后），超时 taskkill /T /F 杀整棵进程树（3 秒闸兜底）
        private static void ShutdownServer(Process server, string baseUrl)
        {
            if (baseUrl != null)
            {
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create(baseUrl + "api/bye");
                    req.Method = "GET";
                    req.Timeout = 1200;
                    using (req.GetResponse()) { }
                }
                catch { }
            }
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < 2200)
            {
                try { if (server.HasExited) return; } catch { return; }
                Thread.Sleep(150);
            }
            try
            {
                var tk = Process.Start(new ProcessStartInfo("taskkill",
                    "/PID " + server.Id + " /T /F")
                { UseShellExecute = false, CreateNoWindow = true });
                tk.WaitForExit(3000);
            }
            catch { }
        }

        private static void CleanupPortFile(string portFile)
        {
            try { if (File.Exists(portFile)) File.Delete(portFile); } catch { }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly Process _server;
        private readonly string _portFile;
        private readonly WebView2 _web;
        private string _baseUrl;                 // 探测成功后的 baseUrl（关窗 bye 用）
        private bool _webReady;
        private bool _portReady;
        private string _pendingUrl;
        private bool _dead;

        public string BaseUrl { get { return _baseUrl; } }

        public MainForm(Process server, string portFile)
        {
            _server = server;
            _portFile = portFile;

            Text = Program.AppTitle;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            ClientSize = new Size(1000, 740);
            MinimumSize = new Size(820, 600);
            StartPosition = FormStartPosition.CenterScreen;
            // 1024 用户反馈：打开就是全屏，省一次最大化点击；最小尺寸兜底小屏
            WindowState = FormWindowState.Maximized;

            _web = new WebView2
            {
                Dock = DockStyle.Fill,
                CreationProperties = new CoreWebView2CreationProperties
                {
                    UserDataFolder = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "电脑体检台", "webview2-data")
                }
            };
            _web.CoreWebView2InitializationCompleted += (s, e) =>
            {
                if (!e.IsSuccess) { ShowFatal("初始化网页内核失败：" + e.InitializationException.Message); return; }
                _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                // 网页自己 requestAnimationFrame 适配窗口，禁掉双指缩放防误触模糊
                _web.CoreWebView2.Settings.IsZoomControlEnabled = false;
                _webReady = true;
                TryNavigate();
            };
            Controls.Add(_web);

            _web.EnsureCoreWebView2Async(null);

            Shown += (s, e) => Task.Run((Action)WaitForServer);
            FormClosed += (s, e) => { try { _web.Dispose(); } catch { } };
        }

        // 轮询 PortFile → 探测可用 host 前缀（server 先绑 127.0.0.1、被拒降级 localhost）
        private void WaitForServer()
        {
            var sw = Stopwatch.StartNew();
            int port = 0;
            while (sw.ElapsedMilliseconds < 90000)
            {
                if (_dead || IsDisposed) return;
                try { if (_server.HasExited) { ShowFatal("体检引擎意外退出。可把问题反馈给开发者：\r\n" + Path.Combine(Path.GetTempPath(), "diag-web-server-crash.log")); return; } } catch { }
                try
                {
                    if (File.Exists(_portFile))
                    {
                        string txt = File.ReadAllText(_portFile).Trim();
                        if (int.TryParse(txt, out port) && port > 0) break;
                    }
                }
                catch { }
                Thread.Sleep(120);
            }
            if (port <= 0)
            {
                ShowFatal("体检引擎 90 秒内没有就绪（可能被杀毒软件拦截）。请稍后再试或重新安装。");
                return;
            }
            foreach (string host in new[] { "127.0.0.1", "localhost" })
            {
                string cand = "http://" + host + ":" + port + "/";
                if (Probe(cand))
                {
                    _baseUrl = cand;
                    break;
                }
            }
            if (_baseUrl == null) { ShowFatal("体检引擎端口已开但访问不通（端口 " + port + "）。"); return; }
            _portReady = true;
            BeginInvoke((Action)TryNavigate);
        }

        private static bool Probe(string baseUrl)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(baseUrl + "api/meta");
                req.Method = "GET";
                req.Timeout = 3000;
                using (req.GetResponse()) { }
                return true;
            }
            catch { return false; }
        }

        private void TryNavigate()
        {
            if (InvokeRequired) { BeginInvoke((Action)TryNavigate); return; }
            if (!_webReady || !_portReady || _pendingUrl != null) return;
            _pendingUrl = _baseUrl;
            _web.CoreWebView2.Navigate(_baseUrl);
        }

        private void ShowFatal(string msg)
        {
            if (InvokeRequired) { BeginInvoke((Action)(() => ShowFatal(msg))); return; }
            _dead = true;
            string html = "<html><head><meta charset=\"utf-8\"><body style=\"background:#1a2240;color:#e8ecf8;" +
                "font-family:'Microsoft YaHei',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0\">" +
                "<div style=\"max-width:560px;padding:32px;line-height:1.8;font-size:15px\">" +
                "<div style=\"font-size:20px;margin-bottom:12px\">电脑体检台没能启动</div>" +
                msg.Replace("\r\n", "<br>") + "</div></body></html>";
            try { _web.NavigateToString(html); } catch { }
        }
    }

    internal static class Native
    {
        public const int SW_RESTORE = 9;
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
