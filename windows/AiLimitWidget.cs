// Виджет «Лимиты ИИ» для Windows 10 / 11 — лимиты Claude Code, Antigravity CLI, Codex и других ИИ (класс Extra) в одном окне.
// Claude: те же данные, что /usage в Claude Code; токен из %USERPROFILE%\.claude\.credentials.json (только читаем).
// Antigravity: «agy -p /quota --output-format json» — бесплатная команда, без обращения к модели и без расхода квоты.
// Вырос из ClaudeLimitWidget. Сборка: build.cmd (компилятор C# из .NET Framework 4). Код на C# 5.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;
using Gdi = System.Drawing;

namespace AiLimitWidget
{
    sealed class Settings
    {
        public string Position = "TR";   // BR, TR, BL, TL — угол экрана; Free — куда перетащили (Left/Top)
        public int Transparency = 1;     // 0 — низкая … 3 — максимальная
        public int RefreshMinutes = 2;
        public double? Left, Top;
        public bool KeepOpen, Notify = true, ClockLabel = true;   // KeepOpen — не скрывать окно при нажатии мимо; ClockLabel — «Сессия: 27%» у часов
        public bool ShowClaude = true, ShowAgy = true, ShowCodex = true;   // какие сервисы показывать
        public bool ShowDetails;                                   // развёрнуты ли подробности (аккаунт, на что ушла неделя)
        public string ClockItems = "claude,gemini,3p,codex,geminicli,copilot,cursor";   // что показывать у часов: claude, gemini (Antigravity), 3p (Claude и GPT в Antigravity), codex, другие ИИ
        public int ClockVersion;                                   // 2 — в ClockItems уже учтён столбец codex, 3 — столбцы других ИИ
        public string HiddenExtras = "";                           // другие ИИ (Gemini CLI, Copilot, Cursor), которые выключили в «Показывать»
        public string LoggedOut = "";                              // сервисы, скрытые из-за выхода: вернутся сами, когда в них снова войдут
    }

    sealed class Limit
    {
        public string Key, Title;
        public double Percent;           // израсходовано, 0…100 (у Antigravity пересчитано из остатка)
        public DateTime? ResetsAt;
        public long WindowSeconds;       // длина окна лимита (у Codex приходит с сервера: 5 ч, неделя или 30 дней)
    }

    // группа моделей Antigravity: у каждой свой 5-часовой и недельный лимит
    sealed class AgyGroup
    {
        public string Key, Title, Models;
        public Limit Session, Week;
        public bool SessionOff;   // 5-часовое окно отключено сервисом (упёрлись в недельный лимит)

        // короткое окно для часов и значка: если 5 часов не действует — упираемся в неделю
        public Limit Short { get { return Session ?? (SessionOff ? Week : null); } }

        // сколько реально доступно: упёрлись в любой из лимитов — группа стоит
        public double Used
        {
            get { return Math.Max(Session == null ? 0 : Session.Percent, Week == null ? 0 : Week.Percent); }
        }
    }

    // «Стекло»: размытие того, что под окном, средствами Windows (как в NamazWidget).
    static class Glass
    {
        [StructLayout(LayoutKind.Sequential)] struct AccentPolicy { public int State, Flags, GradientColor, AnimationId; }
        [StructLayout(LayoutKind.Sequential)] struct CompositionData { public int Attribute; public IntPtr Data; public int Size; }

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref CompositionData data);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        const int GWL_STYLE = -16, WS_SYSMENU = 0x80000;
        const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2;
        const int WCA_ACCENT_POLICY = 19, ACCENT_ENABLE_TRANSPARENTGRADIENT = 2, ACCENT_ENABLE_BLURBEHIND = 3, ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;

        static int WindowsBuild
        {
            get
            {
                try
                {
                    using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                        return key == null ? 0 : int.Parse(Convert.ToString(key.GetValue("CurrentBuildNumber"), CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
                }
                catch (Exception) { return 0; }
            }
        }

        static bool TransparencyEnabled
        {
            get
            {
                try
                {
                    using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    {
                        object v = key == null ? null : key.GetValue("EnableTransparency");
                        return !(v is int) || (int)v != 0;
                    }
                }
                catch (Exception) { return true; }
            }
        }

        public static void SetBlur(Window window, bool blur)
        {
            IntPtr hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero || WindowsBuild < 22000 || !TransparencyEnabled) return;
            SetGlass(hwnd, blur);
        }

        static bool SetGlass(IntPtr hwnd, bool blur)
        {
            return blur ? SetAccent(hwnd, ACCENT_ENABLE_ACRYLICBLURBEHIND, unchecked((int)0x10201E1C))
                        : SetAccent(hwnd, ACCENT_ENABLE_TRANSPARENTGRADIENT, 0);
        }

        static bool SetAccent(IntPtr hwnd, int state, int gradient)
        {
            var accent = new AccentPolicy { State = state, Flags = 2, GradientColor = gradient };
            int size = Marshal.SizeOf(accent);
            IntPtr ptr = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(accent, ptr, false);
                var data = new CompositionData { Attribute = WCA_ACCENT_POLICY, Data = ptr, Size = size };
                return SetWindowCompositionAttribute(hwnd, ref data) != 0;
            }
            finally { Marshal.FreeHGlobal(ptr); }
        }

        public static void Apply(Window window, Border surface, Brush opaque, bool blur)
        {
            window.SourceInitialized += (s, e) =>
            {
                bool ok = false;
                try
                {
                    IntPtr hwnd = new WindowInteropHelper(window).Handle;
                    HwndSource.FromHwnd(hwnd).CompositionTarget.BackgroundColor = Colors.Transparent;
                    SetWindowLong(hwnd, GWL_STYLE, GetWindowLong(hwnd, GWL_STYLE) & ~WS_SYSMENU);
                    int build = WindowsBuild;
                    if (!TransparencyEnabled) ok = false;
                    else if (build >= 22000)
                    {
                        int dark = 1, round = DWMWCP_ROUND;
                        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, 4);
                        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, 4);
                        ok = SetGlass(hwnd, blur);
                    }
                    else if (build >= 10240)
                        ok = SetAccent(hwnd, build >= 17134 ? ACCENT_ENABLE_ACRYLICBLURBEHIND : ACCENT_ENABLE_BLURBEHIND, unchecked((int)0x66201E1C));
                }
                catch (Exception) { ok = false; }
                if (!ok) { surface.Background = opaque; surface.Tag = "opaque"; }
            };
            window.ContentRendered += (s, e) =>
            {
                var mode = window.SizeToContent;
                window.SizeToContent = SizeToContent.Manual;
                window.SizeToContent = mode;
            };
        }
    }

    // Другие ИИ, кроме Claude Code, Antigravity и Codex: появляются в окне сами, как только на компьютере
    // есть вход в них, и пропадают, если входа нет. У каждого свой цвет.
    sealed class ExtraProvider
    {
        public string Key, Name;
        public Color Color;
        public readonly List<Limit> Limits = new List<Limit>();   // по возрастанию окна: у часов сверху — первый, снизу — последний
        public string Plan = "", Email, Status = "";
        public bool StatusIsError, SignedIn, Fetching;              // SignedIn — есть вход, раздел показываем
        public DateTime? UpdatedAt;
        public DateTime NextFetch = DateTime.MinValue;

        public Limit Short { get { return Limits.FirstOrDefault(); } }
        public Limit Long { get { return Limits.Count > 1 ? Limits[Limits.Count - 1] : null; } }
    }

    // результат одного запроса: SignedIn = false — входа нет, раздел прячем
    sealed class ExtraResult
    {
        public bool SignedIn = true;
        public readonly List<Limit> Limits = new List<Limit>();
        public string Plan = "", Email, Problem;
        public int RetryAfterSeconds;
    }

    // Gemini CLI: вход из ~/.gemini/oauth_creds.json, лимиты — тот же запрос, что /stats в самом Gemini CLI.
    // GitHub Copilot: вход Copilot CLI (диспетчер учётных данных или ~/.copilot), плагина Copilot или gh; месячный лимит премиум-запросов.
    // Cursor: вход из базы Cursor (state.vscdb), расход за текущий месяц подписки.
    // Входы только читаем: обновлённый токен Gemini держим в памяти и в файл не пишем. Всё вызывается из фонового потока.
    static class Extra
    {
        public static readonly string[][] All = {
            new[] { "geminicli", "Gemini CLI", "#8AB4F8" },   // голубой
            new[] { "copilot", "GitHub Copilot", "#BF5AF2" }, // фиолетовый
            new[] { "cursor", "Cursor", "#40C8E0" }           // бирюзовый
        };

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static string Home { get { return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile); } }

        public static ExtraResult Fetch(string key)
        {
            switch (key)
            {
                case "geminicli": return Gemini();
                case "copilot": return Copilot();
                case "cursor": return Cursor();
                default: return new ExtraResult { SignedIn = false };
            }
        }

        // ---------- JSON ----------
        static Dictionary<string, object> Parse(string text)
        {
            try { return string.IsNullOrEmpty(text) ? null : new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object>; }
            catch (Exception) { return null; }
        }

        static Dictionary<string, object> File(string path)
        {
            try { return System.IO.File.Exists(path) ? Parse(System.IO.File.ReadAllText(path, Encoding.UTF8)) : null; }
            catch (Exception) { return null; }
        }

        static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) ? v : null;
        }

        static Dictionary<string, object> Obj(Dictionary<string, object> d, string key) { return Get(d, key) as Dictionary<string, object>; }

        static string Str(object v)
        {
            if (v is string) return (string)v;
            if (v is int || v is long || v is decimal || v is double) return Convert.ToString(v, Inv);
            return null;
        }

        static double? Num(object v)
        {
            if (v is int || v is long || v is decimal || v is double) return Convert.ToDouble(v, Inv);
            double d;
            if (v is string && double.TryParse((string)v, NumberStyles.Float, Inv, out d)) return d;
            return null;
        }

        static bool? Bool(object v) { return v is bool ? (bool?)(bool)v : null; }

        static DateTime? Time(object v)
        {
            DateTimeOffset t;
            string s = v as string;
            if (!string.IsNullOrEmpty(s) && DateTimeOffset.TryParse(s, Inv, DateTimeStyles.None, out t)) return t.LocalDateTime;
            return null;
        }

        // «2025-11-01» — дата сброса в UTC
        static DateTime? Day(string s)
        {
            DateTime d;
            if (string.IsNullOrEmpty(s) || s.Length < 10) return null;
            if (!DateTime.TryParseExact(s.Substring(0, 10), "yyyy-MM-dd", Inv, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d)) return null;
            return d.ToLocalTime();
        }

        // средняя часть JWT — там почта, срок и пользователь
        static Dictionary<string, object> Claims(string jwt)
        {
            try
            {
                string[] parts = (jwt ?? "").Split('.');
                if (parts.Length < 2) return null;
                string p = parts[1].Replace('-', '+').Replace('_', '/');
                p = p.PadRight(p.Length + (4 - p.Length % 4) % 4, '=');
                return Parse(Encoding.UTF8.GetString(Convert.FromBase64String(p)));
            }
            catch (Exception) { return null; }
        }

        static string Capital(string s) { return string.IsNullOrEmpty(s) ? "" : char.ToUpper(s[0], Inv) + s.Substring(1); }

        static double Clamp(double v) { return Math.Max(0, Math.Min(100, v)); }

        // ---------- HTTP (в фоне) ----------
        static int Http(string url, string method, Dictionary<string, string> headers, string body, out string text)
        {
            text = null;
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = method;
                req.Timeout = 30000;
                req.ReadWriteTimeout = 30000;
                req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                foreach (var h in headers)
                {
                    if (h.Key == "Content-Type") req.ContentType = h.Value;
                    else if (h.Key == "Accept") req.Accept = h.Value;
                    else if (h.Key == "User-Agent") req.UserAgent = h.Value;
                    else req.Headers[h.Key] = h.Value;
                }
                if (body != null)
                {
                    byte[] bytes = Encoding.UTF8.GetBytes(body);
                    req.ContentLength = bytes.Length;
                    using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
                }
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    text = ReadBody(resp);
                    return (int)resp.StatusCode;
                }
            }
            catch (WebException e)
            {
                var resp = e.Response as HttpWebResponse;
                if (resp == null) return 0;
                using (resp)
                {
                    try { text = ReadBody(resp); } catch (Exception) { }
                    return (int)resp.StatusCode;
                }
            }
            catch (Exception) { return 0; }
        }

        static string ReadBody(HttpWebResponse resp)
        {
            using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
        }

        static bool Ok(int code) { return code >= 200 && code < 300; }

        static ExtraResult Problem(string service, int code)
        {
            var r = new ExtraResult();
            if (code == 401 || code == 403) r.Problem = "Вход " + service + " устарел — откройте " + service + ", он обновит его сам";
            else if (code == 429) { r.Problem = "Сервер просит подождать — повторю через 5 мин"; r.RetryAfterSeconds = 300; }
            else r.Problem = code >= 300 ? "Ошибка сервера " + service + " (" + code + ")" : "Нет соединения — повторю позже";
            return r;
        }

        // выполнить программу без окна и дождаться вывода; null — не запустилась или не ответила
        static string Run(string exe, string args, int timeoutMs)
        {
            try { return Background.Run(exe, args, Home, timeoutMs); }
            catch (Exception) { return null; }
        }

        // ---------- Gemini CLI ----------
        // Открытый клиент OAuth самого Gemini CLI (он опубликован в его исходниках) — нужен, чтобы обновить истёкший вход.
        const string GeminiClientId = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com";
        const string GeminiClientSecret = "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";
        const string CodeAssist = "https://cloudcode-pa.googleapis.com/v1internal:";
        static string geminiToken, geminiProject;
        static DateTime geminiTokenUntil = DateTime.MinValue;

        static string GeminiDir
        {
            get
            {
                string env = Environment.GetEnvironmentVariable("GEMINI_CLI_HOME");
                return Path.Combine(string.IsNullOrEmpty(env) ? Home : env, ".gemini");
            }
        }

        static ExtraResult Gemini()
        {
            var creds = File(Path.Combine(GeminiDir, "oauth_creds.json"));
            if (creds == null) return new ExtraResult { SignedIn = false };
            // вошли по API-ключу или через Vertex — лимитов подписки нет
            string type = Str(Get(Obj(Obj(File(Path.Combine(GeminiDir, "settings.json")), "security"), "auth"), "selectedType"));
            if (!string.IsNullOrEmpty(type) && type != "oauth-personal") return new ExtraResult { SignedIn = false };
            string token = Str(Get(creds, "access_token")) ?? "";
            double? expiryMs = Num(Get(creds, "expiry_date"));
            DateTime expiry = expiryMs.HasValue ? DateTimeOffset.FromUnixTimeMilliseconds((long)expiryMs.Value).LocalDateTime : DateTime.MinValue;
            if (expiry < DateTime.Now.AddSeconds(60))
            {
                if (geminiToken != null && geminiTokenUntil > DateTime.Now.AddSeconds(60)) token = geminiToken;
                else
                {
                    string refresh = Str(Get(creds, "refresh_token"));
                    if (string.IsNullOrEmpty(refresh)) return new ExtraResult { SignedIn = false };
                    string form = "client_id=" + Uri.EscapeDataString(GeminiClientId) + "&client_secret=" + Uri.EscapeDataString(GeminiClientSecret)
                                + "&refresh_token=" + Uri.EscapeDataString(refresh) + "&grant_type=refresh_token";
                    string text;
                    int code = Http("https://oauth2.googleapis.com/token", "POST",
                                    new Dictionary<string, string> { { "Content-Type", "application/x-www-form-urlencoded" } }, form, out text);
                    var d = Ok(code) ? Parse(text) : null;
                    string t = Str(Get(d, "access_token"));
                    if (string.IsNullOrEmpty(t))
                    {
                        if (code == 400 || code == 401) return new ExtraResult { Problem = "Вход Gemini CLI устарел — запустите gemini и войдите снова" };
                        return Problem("Gemini CLI", code);
                    }
                    token = t;
                    geminiToken = t;
                    geminiTokenUntil = DateTime.Now.AddSeconds(Num(Get(d, "expires_in")) ?? 3000);
                }
            }
            var headers = new Dictionary<string, string> {
                { "Authorization", "Bearer " + token }, { "Content-Type", "application/json" }, { "User-Agent", "GeminiCLI AiLimitWidget/1.0" } };
            var r = new ExtraResult();
            r.Email = Str(Get(Claims(Str(Get(creds, "id_token"))), "email"));
            // проект и тариф — как при запуске Gemini CLI
            string lt;
            int lc = Http(CodeAssist + "loadCodeAssist", "POST", headers,
                          "{\"metadata\":{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}}", out lt);
            var load = Ok(lc) ? Parse(lt) : null;
            if (load == null) return Problem("Gemini CLI", lc);
            var tier = Obj(load, "paidTier") ?? Obj(load, "currentTier");
            r.Plan = (Str(Get(tier, "name")) ?? Str(Get(tier, "id")) ?? "").Replace("Gemini Code Assist ", "");
            string project = Str(Get(load, "cloudaicompanionProject")) ?? Str(Get(Obj(load, "cloudaicompanionProject"), "id")) ?? geminiProject;
            geminiProject = project;
            var q = new Dictionary<string, object>();
            if (project != null) q["project"] = project;
            string qt;
            int qc = Http(CodeAssist + "retrieveUserQuota", "POST", headers, new JavaScriptSerializer().Serialize(q), out qt);
            var quota = Ok(qc) ? Parse(qt) : null;
            if (quota == null) return Problem("Gemini CLI", qc);
            // по модели — остаток запросов на сутки; показываем Pro и Flash, остальные модели делят те же лимиты
            var byModel = new Dictionary<string, Limit>();
            var buckets = Get(quota, "buckets") as System.Collections.IEnumerable;
            if (buckets != null)
                foreach (var b in buckets.OfType<Dictionary<string, object>>())
                {
                    string model = Str(Get(b, "modelId"));
                    double? left = Num(Get(b, "remainingFraction"));
                    if (model == null || !left.HasValue || model.Contains("lite") || model.Contains("embedding")) continue;
                    double used = Clamp((1 - left.Value) * 100);
                    string title = model.Contains("pro") ? "Сутки · Pro" : model.Contains("flash") ? "Сутки · Flash" : "Сутки · " + model;
                    Limit old;
                    if (byModel.TryGetValue(title, out old) && old.Percent >= used) continue;
                    byModel[title] = new Limit { Key = "geminicli-" + title, Title = title, Percent = used, ResetsAt = Time(Get(b, "resetTime")), WindowSeconds = 86400 };
                }
            r.Limits.AddRange(byModel.Values.OrderByDescending(l => l.Percent));
            if (r.Limits.Count == 0) r.Problem = "Сервер не сообщил лимиты";
            return r;
        }

        // ---------- GitHub Copilot ----------
        static IEnumerable<string> CopilotDirs
        {
            get
            {
                string xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
                string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                yield return Path.Combine(Home, ".copilot");
                yield return Path.Combine(string.IsNullOrEmpty(xdg) ? Path.Combine(Home, ".config") : xdg, "github-copilot");
                if (!string.IsNullOrEmpty(local)) yield return Path.Combine(local, "github-copilot");
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Credential
        {
            public int Flags, Type;
            public string TargetName, Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist, AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias, UserName;
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredEnumerate(string filter, int flags, out int count, out IntPtr list);
        [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);

        // Copilot CLI хранит вход в диспетчере учётных данных Windows (как в связке ключей на Mac)
        static string CredentialToken()
        {
            IntPtr list;
            int count;
            if (!CredEnumerate("*copilot*", 0, out count, out list)) return null;
            try
            {
                for (int i = 0; i < count; i++)
                {
                    var c = (Credential)Marshal.PtrToStructure(Marshal.ReadIntPtr(list, i * IntPtr.Size), typeof(Credential));
                    if (c.CredentialBlob == IntPtr.Zero || c.CredentialBlobSize <= 0) continue;
                    var bytes = new byte[c.CredentialBlobSize];
                    Marshal.Copy(c.CredentialBlob, bytes, 0, bytes.Length);
                    // строка бывает в UTF-8 или UTF-16 — пробуем обе
                    foreach (var enc in new[] { Encoding.UTF8, Encoding.Unicode })
                    {
                        string s = enc.GetString(bytes).Trim().Trim('\0');
                        string t = FirstToken(s) ?? FirstToken(Parse(s));
                        if (t != null) return t;
                    }
                }
            }
            catch (Exception) { }
            finally { CredFree(list); }
            return null;
        }

        // вход: Copilot CLI (диспетчер учётных данных или его config.json), плагин Copilot (apps.json / hosts.json), затем gh
        static string CopilotToken()
        {
            string t = CredentialToken();
            if (t != null) return t;
            foreach (string dir in CopilotDirs)
                foreach (string f in new[] { "config.json", "apps.json", "hosts.json" })
                {
                    t = FirstToken(File(Path.Combine(dir, f)));
                    if (t != null) return t;
                }
            string pf = Environment.GetEnvironmentVariable("ProgramFiles");
            string installed = string.IsNullOrEmpty(pf) ? null : Path.Combine(pf, "GitHub CLI", "gh.exe");
            string gh = installed != null && System.IO.File.Exists(installed) ? installed : "gh";
            string out1 = (Run(gh, "auth token", 10000) ?? "").Trim();
            return out1.StartsWith("gh", StringComparison.Ordinal) ? out1 : null;
        }

        // токены GitHub начинаются с gho_ / ghu_ / github_pat_ — ищем по всему файлу, где бы он ни лежал
        static string FirstToken(object v)
        {
            var s = v as string;
            if (s != null) return s.StartsWith("gho_", StringComparison.Ordinal) || s.StartsWith("ghu_", StringComparison.Ordinal)
                                  || s.StartsWith("github_pat_", StringComparison.Ordinal) ? s : null;
            var d = v as Dictionary<string, object>;
            if (d != null)
            {
                foreach (string key in new[] { "oauth_token", "token", "copilot_tokens" })
                {
                    string t = FirstToken(Get(d, key));
                    if (t != null) return t;
                }
                foreach (var x in d.Values)
                {
                    string t = FirstToken(x);
                    if (t != null) return t;
                }
                return null;
            }
            var a = v as System.Collections.IEnumerable;
            if (a != null)
                foreach (var x in a)
                {
                    string t = FirstToken(x);
                    if (t != null) return t;
                }
            return null;
        }

        static ExtraResult Copilot()
        {
            // папок Copilot может не быть (VS Code хранит вход у себя) — тогда вход берём из gh
            string token = CopilotToken();
            if (token == null) return new ExtraResult { SignedIn = false };
            string text;
            int code = Http("https://api.github.com/copilot_internal/user", "GET", new Dictionary<string, string> {
                { "Authorization", "token " + token }, { "Accept", "application/json" },
                { "Editor-Version", "vscode/1.99.0" }, { "Editor-Plugin-Version", "copilot-chat/0.26.0" },
                { "User-Agent", "GitHubCopilotChat/0.26.0" }, { "X-Github-Api-Version", "2025-04-01" } }, null, out text);
            if (code == 404) return new ExtraResult { SignedIn = false };   // у аккаунта нет Copilot
            var d = Ok(code) ? Parse(text) : null;
            if (d == null) return Problem("Copilot", code);
            var r = new ExtraResult();
            r.Plan = Capital((Str(Get(d, "copilot_plan")) ?? Str(Get(d, "access_type_sku")) ?? "").Replace("_", " "));
            r.Email = Str(Get(d, "login"));
            DateTime? resetAt = Time(Get(d, "quota_reset_date_utc")) ?? Day(Str(Get(d, "quota_reset_date")) ?? Str(Get(d, "limited_user_reset_date")));
            const long month = 30 * 86400;
            var names = new Dictionary<string, string> { { "premium_interactions", "Премиум-запросы · месяц" }, { "chat", "Чат · месяц" }, { "completions", "Дополнения · месяц" } };
            var snaps = Obj(d, "quota_snapshots");
            var leftQuotas = Obj(d, "limited_user_quotas");
            var totalQuotas = Obj(d, "monthly_quotas");
            if (snaps != null)
            {
                foreach (string key in new[] { "premium_interactions", "chat", "completions" })
                {
                    var s = Obj(snaps, key);
                    if (s == null || Bool(Get(s, "unlimited")) == true) continue;
                    double? left = Num(Get(s, "percent_remaining"));
                    if (!left.HasValue)
                    {
                        double? e = Num(Get(s, "entitlement")), rem = Num(Get(s, "remaining"));
                        if (e.HasValue && e.Value > 0 && rem.HasValue) left = rem.Value / e.Value * 100;
                    }
                    if (!left.HasValue) continue;
                    r.Limits.Add(new Limit { Key = "copilot-" + key, Title = names[key], Percent = Clamp(100 - left.Value), ResetsAt = resetAt, WindowSeconds = month });
                }
            }
            else if (leftQuotas != null && totalQuotas != null)
            {
                // бесплатный Copilot: сколько осталось из месячной нормы
                foreach (string key in new[] { "chat", "completions" })
                {
                    double? t = Num(Get(totalQuotas, key)), rem = Num(Get(leftQuotas, key));
                    if (!t.HasValue || t.Value <= 0 || !rem.HasValue) continue;
                    r.Limits.Add(new Limit { Key = "copilot-" + key, Title = names[key], Percent = Clamp((t.Value - rem.Value) / t.Value * 100), ResetsAt = resetAt, WindowSeconds = month });
                }
            }
            if (r.Limits.Count == 0) r.Problem = "Без ограничений по тарифу";
            return r;
        }

        // ---------- Cursor ----------
        // В Windows нет sqlite3, поэтому значения из базы Cursor (SQLite) достаём сами: ищем запись «ключ → значение»
        // в файле базы и в её журнале (-wal, там самые свежие страницы). Токен читаем заново, только когда он
        // истекает, сервер его не принял или база менялась больше 10 минут назад — файл бывает большим.
        static string CursorDb
        {
            get
            {
                string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                return Path.Combine(appData, "Cursor", "User", "globalStorage", "state.vscdb");
            }
        }

        static string cursorToken, cursorEmail;
        static DateTime cursorStamp = DateTime.MinValue, cursorReadAt = DateTime.MinValue, cursorTokenUntil = DateTime.MinValue;

        static void ReadCursor(bool force)
        {
            string db = CursorDb, wal = db + "-wal";
            DateTime stamp = System.IO.File.GetLastWriteTimeUtc(db);
            if (System.IO.File.Exists(wal)) { DateTime w = System.IO.File.GetLastWriteTimeUtc(wal); if (w > stamp) stamp = w; }
            bool fresh = cursorToken != null && cursorTokenUntil > DateTime.Now.AddMinutes(1)
                         && (stamp == cursorStamp || DateTime.Now - cursorReadAt < TimeSpan.FromMinutes(10));
            if (fresh && !force) return;
            string token = null, email = null;
            double bestExp = double.MinValue;
            foreach (string path in new[] { db, wal })
            {
                byte[] data = ReadShared(path);
                if (data == null) continue;
                foreach (string t in SqliteValues(data, "cursorAuth/accessToken"))
                {
                    if (!t.StartsWith("eyJ", StringComparison.Ordinal)) continue;
                    // старые копии записи могут остаться в свободных страницах — берём токен с самым поздним сроком
                    double exp = Num(Get(Claims(t), "exp")) ?? 0;
                    if (exp >= bestExp) { bestExp = exp; token = t; }
                }
                foreach (string e in SqliteValues(data, "cursorAuth/cachedEmail"))
                    if (e.Contains("@")) email = e;
            }
            cursorToken = token;
            cursorEmail = email;
            cursorStamp = stamp;
            cursorReadAt = DateTime.Now;
            cursorTokenUntil = token != null && bestExp > 0 ? DateTimeOffset.FromUnixTimeSeconds((long)bestExp).LocalDateTime : DateTime.Now.AddHours(1);
        }

        static byte[] ReadShared(string path)
        {
            try
            {
                if (!System.IO.File.Exists(path)) return null;
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var data = new byte[fs.Length];
                    int read = 0, n;
                    while (read < data.Length && (n = fs.Read(data, read, data.Length - read)) > 0) read += n;
                    return data;
                }
            }
            catch (Exception) { return null; }
        }

        // запись таблицы ItemTable(key, value) в SQLite: [размер заголовка][тип key][тип value][key][value];
        // тип текста — 2·N+13, двоичных данных — 2·N+12 (N — длина в байтах), числа — varint
        static IEnumerable<string> SqliteValues(byte[] data, string key)
        {
            byte[] k = Encoding.UTF8.GetBytes(key);
            long keyType = 2L * k.Length + 13;
            for (int p = IndexOf(data, k, 0); p >= 0; p = IndexOf(data, k, p + 1))
            {
                // заголовок стоит прямо перед ключом: пробуем все длины поля типа value (1–4 байта)
                for (int h = 3; h <= 6; h++)
                {
                    int start = p - h;
                    if (start < 0 || data[start] != h) continue;
                    int pos = start + 1;
                    long t1 = Varint(data, ref pos);
                    if (t1 != keyType) continue;
                    long t2 = Varint(data, ref pos);
                    if (pos != p || t2 < 12) continue;
                    long len = (t2 - 12) / 2;
                    int from = p + k.Length;
                    if (len <= 0 || from + len > data.Length) continue;
                    yield return Encoding.UTF8.GetString(data, from, (int)len);
                    break;
                }
            }
        }

        static long Varint(byte[] data, ref int pos)
        {
            long v = 0;
            for (int i = 0; i < 9 && pos < data.Length; i++)
            {
                byte b = data[pos++];
                if (i == 8) return (v << 8) | b;
                v = (v << 7) | (long)(b & 0x7F);
                if ((b & 0x80) == 0) return v;
            }
            return -1;
        }

        static int IndexOf(byte[] data, byte[] k, int from)
        {
            for (int i = from; i <= data.Length - k.Length; i++)
            {
                if (data[i] != k[0]) continue;
                int j = 1;
                while (j < k.Length && data[i + j] == k[j]) j++;
                if (j == k.Length) return i;
            }
            return -1;
        }

        static ExtraResult Cursor() { return Cursor(false); }

        static ExtraResult Cursor(bool retried)
        {
            if (!System.IO.File.Exists(CursorDb)) return new ExtraResult { SignedIn = false };
            ReadCursor(retried);
            string token = cursorToken;
            if (token == null) return new ExtraResult { SignedIn = false };
            // сайт Cursor узнаёт пользователя по cookie «id::токен»; id — в самом токене (sub = «auth0|user_…»)
            string sub = Str(Get(Claims(token), "sub")) ?? "";
            string user = sub.Split('|').Last();
            string text;
            int code = Http("https://cursor.com/api/usage-summary", "GET", new Dictionary<string, string> {
                { "Cookie", "WorkosCursorSessionToken=" + user + "%3A%3A" + token }, { "Accept", "application/json" },
                { "Origin", "https://cursor.com" }, { "User-Agent", "Mozilla/5.0 AiLimitWidget/1.0" } }, null, out text);
            // токен в памяти устарел (Cursor уже обновил его в базе) — перечитываем базу один раз
            if ((code == 401 || code == 403) && !retried) return Cursor(true);
            var d = Ok(code) ? Parse(text) : null;
            if (d == null) return Problem("Cursor", code);
            var r = new ExtraResult();
            r.Email = cursorEmail;
            r.Plan = Capital(Str(Get(d, "membershipType")) ?? "");
            DateTime? end = Time(Get(d, "billingCycleEnd")), start = Time(Get(d, "billingCycleStart"));
            long secs = (long)Math.Max(86400, end.HasValue ? (end.Value - (start ?? DateTime.Now)).TotalSeconds : 30 * 86400);
            var individual = Obj(d, "individualUsage");
            var plan = Obj(individual, "plan");
            if (plan != null)
            {
                double? pct = Num(Get(plan, "totalPercentUsed"));
                if (!pct.HasValue)
                {
                    double? used = Num(Get(plan, "used")), limit = Num(Get(plan, "limit"));
                    if (used.HasValue && limit.HasValue && limit.Value > 0) pct = used.Value / limit.Value * 100;
                }
                if (pct.HasValue) r.Limits.Add(new Limit { Key = "cursor-plan", Title = "Тариф · месяц", Percent = Clamp(pct.Value), ResetsAt = end, WindowSeconds = secs });
            }
            var od = Obj(individual, "onDemand");
            if (od != null && Bool(Get(od, "enabled")) == true)
            {
                double? used = Num(Get(od, "used")), limit = Num(Get(od, "limit"));
                if (used.HasValue && limit.HasValue && limit.Value > 0)
                    r.Limits.Add(new Limit { Key = "cursor-ondemand", Title = "Сверх тарифа · месяц", Percent = Clamp(used.Value / limit.Value * 100), ResetsAt = end, WindowSeconds = secs });
            }
            if (r.Limits.Count == 0) r.Problem = "Сервер не сообщил лимиты";
            return r;
        }
    }

    sealed class Widget
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly CultureInfo Ru = CultureInfo.GetCultureInfo("ru-RU");
        const string UsageUrl = "https://api.anthropic.com/api/oauth/usage";
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "AiLimitWidget";
        const double DockMargin = 12;
        static readonly string[] Positions = { "BR", "TR", "BL", "TL", "Free" };
        static readonly int[] RefreshOptions = { 1, 2, 5, 10 };
        static readonly int[] NotifyThresholds = { 80, 95 };

        // недельные лимиты, которые показываем строками под кольцом (остальные поля ответа — служебные)
        static readonly string[][] WeeklyKeys = {
            new[] { "seven_day", "Неделя · все модели" },
            new[] { "seven_day_opus", "Неделя · Opus" },
            new[] { "seven_day_sonnet", "Неделя · Sonnet" }
        };

        // у каждого лимита свой цвет: Claude Code — оранжевый, Gemini — зелёный,
        // Claude и GPT внутри Antigravity — синий, Codex (когда добавится) — жёлтый
        static readonly Color Accent = C("#D97757"), GeminiColor = C("#34C759"), AgyClaudeColor = C("#4C8DF6"), CodexColor = C("#FFD60A"),
                              Warn = C("#FF9F0A"), Danger = C("#FF453A");

        static Color GroupColor(string key)
        {
            switch (key)
            {
                case "claude": return Accent;
                case "gemini": return GeminiColor;
                case "codex": return CodexColor;
                default:
                    var extra = Extra.All.FirstOrDefault(x => x[0] == key);
                    return extra != null ? C(extra[2]) : AgyClaudeColor;   // 3p — Claude и GPT в Antigravity
            }
        }

        // столбцы надписи у часов, слева направо
        static readonly string[][] ClockColumns = new[] { new[] { "claude", "Claude Code" }, new[] { "gemini", "Gemini" }, new[] { "3p", "Claude и GPT (Antigravity)" }, new[] { "codex", "Codex" } }
            .Concat(Extra.All.Select(x => new[] { x[0], x[1] })).ToArray();

        bool ClockShows(string key) { return settings.ClockItems.Split(',').Contains(key); }

        static Color C(string hex) { return (Color)ColorConverter.ConvertFromString(hex); }
        static SolidColorBrush B(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
        static SolidColorBrush B(string hex) { return B(C(hex)); }

        static Color Severity(double pct) { return Severity(pct, Accent); }
        static Color Severity(double pct, Color normal) { return pct >= 90 ? Danger : pct >= 75 ? Warn : normal; }

        readonly string settingsPath, cachePath, agyCachePath;

        // ---------- Antigravity ----------
        readonly List<AgyGroup> agyGroups = new List<AgyGroup>();
        string agyEmail, agyStatus = "";
        bool agyStatusIsError, agyFetching, agyMissing;
        double? agyCredits;
        DateTime? agyUpdatedAt;
        DateTime agyNextFetch = DateTime.MinValue;
        readonly Settings settings = new Settings();
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;

        Limit session;
        readonly List<Limit> weekly = new List<Limit>();
        string plan = "", status = "";
        Dictionary<string, object> account;                 // oauthAccount из ~/.claude.json
        DateTime? tokenExpires;
        readonly List<KeyValuePair<string, double>> breakdown = new List<KeyValuePair<string, double>>();
        bool extraEnabled;
        bool statusIsError;
        DateTime? updatedAt;
        DateTime nextFetch = DateTime.MinValue;
        bool fetching;
        bool loggedOut;   // в Claude Code нет входа по подписке — показываем кнопку «Войти в Claude»
        readonly HashSet<string> notified = new HashSet<string>();

        Window window;
        WinForms.NotifyIcon tray;
        ContextMenu menu;
        IntPtr trayIconHandle = IntPtr.Zero;
        DispatcherTimer timer;
        Storyboard spin;

        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);

        // ---------- «Сессия: 27%» у часов ----------
        // Отдельное окошко поверх панели задач, слева от области уведомлений (TrayNotifyWnd).
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOREDRAW = 0x8, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;
        const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TRANSPARENT = 0x20;
        const double ChevronOverlap = -7.8;   // надпись заходит на пустое поле кнопки ^ (клики проходят насквозь)

        Window clock;
        // две строки, как у часов: «Сессия: ●27% ●7% ●0%» над «Неделя: ●3% ●1% ●34%»;
        // столбцы — ClockColumns, у каждого точка своего цвета
        TextBlock[] clockNames;
        TextBlock[,] clockValues;
        FrameworkElement[,] clockCells;

        void InitClockLabel()
        {
            var text = new Grid { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };   // окно не бывает уже ~133 точек — текст прижат вправо, к стрелке
            int n = ClockColumns.Length;
            for (int c = 0; c <= n; c++) text.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            clockNames = new TextBlock[2];
            clockValues = new TextBlock[2, n];
            clockCells = new FrameworkElement[2, n];
            for (int i = 0; i < 2; i++)
            {
                text.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                clockNames[i] = new TextBlock { Text = i == 0 ? "Сессия:" : "Неделя:", FontSize = 12 };
                Grid.SetRow(clockNames[i], i);
                text.Children.Add(clockNames[i]);
                for (int p = 0; p < n; p++)
                {
                    clockValues[i, p] = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Right, MinWidth = 26 };
                    var cell = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(p == 0 ? 5 : 6, 0, 0, 0) };
                    cell.Children.Add(new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Fill = B(GroupColor(ClockColumns[p][0])), VerticalAlignment = VerticalAlignment.Center,
                                                    Margin = new Thickness(0, 1, 3, 0) });
                    cell.Children.Add(clockValues[i, p]);
                    Grid.SetRow(cell, i);
                    Grid.SetColumn(cell, p + 1);
                    text.Children.Add(cell);
                    clockCells[i, p] = cell;
                }
            }
            // почти прозрачный фон — чтобы по надписи можно было нажать
            var box = new Border { Padding = new Thickness(8, 3, 0, 3), Child = text };
            clock = new Window {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, ResizeMode = ResizeMode.NoResize,
                ShowInTaskbar = false, ShowActivated = false, Topmost = true, SizeToContent = SizeToContent.WidthAndHeight,
                FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI"), Content = box, Title = "AI limits" };
            TextOptions.SetTextFormattingMode(clock, TextFormattingMode.Display);
            clock.SourceInitialized += (s, e) =>
            {
                IntPtr hwnd = new WindowInteropHelper(clock).Handle;
                // надпись только показывает проценты: мышь её «не видит», клики уходят панели задач
                SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT);
            };
            clock.SizeChanged += (s, e) => PlaceClockLabel();

            // надпись пропускает мышь насквозь, поэтому наведение узнаём по положению курсора
            hoverTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
            hoverTimer.Tick += (s, e) => CheckHover();
            hoverTimer.Start();
        }

        static bool TaskbarLightTheme
        {
            get
            {
                try
                {
                    using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    {
                        object v = key == null ? null : key.GetValue("SystemUsesLightTheme");
                        return v is int && (int)v != 0;
                    }
                }
                catch (Exception) { return false; }
            }
        }

        // на весь экран открыто приложение (игра, видео) — панель задач скрыта, надпись тоже прячем
        static bool FullscreenApp(RECT taskbar)
        {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return false;
            var cls = new StringBuilder(64);
            GetClassName(fg, cls, 64);
            string c = cls.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
            RECT r;
            if (!GetWindowRect(fg, out r)) return false;
            var screen = WinForms.Screen.FromHandle(fg).Bounds;
            return r.Left <= screen.Left && r.Top <= screen.Top && r.Right >= screen.Right && r.Bottom >= screen.Bottom
                && screen.Contains(taskbar.Left + 1, taskbar.Top + 1);
        }

        // ---------- наведение на надпись у часов ----------
        // При наведении открывается то же окно полной информации (правый нижний угол, тот же размер,
        // стиль и прозрачность), но без фокуса — только посмотреть. Увели курсор — окно прячется.
        // Навели курсор на само окно — оно остаётся; нажали в нём — остаётся открытым как обычно.
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);

        DispatcherTimer hoverTimer;
        DateTime hoverSince = DateTime.MinValue;
        bool preview;   // окно открыто наведением, а не нажатием
        const double HoverDelayMs = 400;

        static bool Inside(IntPtr hwnd, POINT pt, int slack)
        {
            RECT r;
            return hwnd != IntPtr.Zero && GetWindowRect(hwnd, out r)
                && pt.X >= r.Left - slack && pt.X < r.Right + slack && pt.Y >= r.Top - slack && pt.Y < r.Bottom + slack;
        }

        void CheckHover()
        {
            POINT pt;
            if (!GetCursorPos(out pt)) return;
            bool overLabel = clock != null && clock.IsVisible && Inside(new WindowInteropHelper(clock).Handle, pt, 6);
            bool overWindow = window.IsVisible && Inside(new WindowInteropHelper(window).Handle, pt, 0);

            if (preview)
            {
                if (!overLabel && !overWindow) { preview = false; window.Hide(); }
                return;
            }
            if (!overLabel || window.IsVisible) { hoverSince = DateTime.MinValue; return; }
            if (hoverSince == DateTime.MinValue) hoverSince = DateTime.Now;
            if ((DateTime.Now - hoverSince).TotalMilliseconds < HoverDelayMs) return;
            hoverSince = DateTime.MinValue;
            preview = true;
            UpdateView();
            window.Show();   // ShowActivated = False — фокус не забираем
            window.UpdateLayout();
            Dock();
            UpdateView();
        }

        void UpdateClockLabel(double pct, bool active)
        {
            if (clock == null) return;
            if (!settings.ClockLabel) { if (clock.IsVisible) clock.Hide(); return; }
            bool light = TaskbarLightTheme;
            DateTime now = DateTime.Now;
            Limit week = weekly.Count > 0 ? weekly[0] : null;
            int n = ClockColumns.Length;
            // [строка, столбец]: строка 0 — сессия (5 ч), 1 — неделя
            var limits = new Limit[2, n];
            var shown = new bool[n];
            for (int p = 0; p < n; p++)
            {
                string key = ClockColumns[p][0];
                if (key == "claude")
                {
                    shown[p] = settings.ShowClaude;
                    limits[0, p] = session;
                    limits[1, p] = week;
                }
                else if (key == "codex")
                {
                    shown[p] = settings.ShowCodex && !codexMissing;
                    limits[0, p] = CodexShort;
                    limits[1, p] = CodexLong;
                }
                else if (ExtraFor(key) != null)
                {
                    ExtraProvider x = ExtraFor(key);
                    shown[p] = x.SignedIn && ExtraOn(key) && x.Limits.Count > 0;
                    limits[0, p] = x.Short;
                    limits[1, p] = x.Long;
                }
                else
                {
                    AgyGroup g = agyGroups.FirstOrDefault(x => x.Key == key);
                    // пока данных нет — столбец всё равно показываем («—»), чтобы надпись не прыгала
                    shown[p] = settings.ShowAgy && !agyMissing && (g != null || agyGroups.Count == 0);
                    limits[0, p] = g == null ? null : g.Short;
                    limits[1, p] = g == null ? null : g.Week;
                }
                shown[p] = shown[p] && ClockShows(key);
            }
            if (!shown.Any(x => x)) shown[0] = true;
            // меняем текст и цвет только когда они действительно изменились — иначе надпись перерисовывается каждую секунду
            for (int i = 0; i < 2; i++)
            {
                SetInk(clockNames[i], C(light ? "#3A3A3C" : "#D1D1D6"));
                for (int p = 0; p < n; p++)
                {
                    var vis = shown[p] ? Visibility.Visible : Visibility.Collapsed;
                    if (clockCells[i, p].Visibility != vis) clockCells[i, p].Visibility = vis;
                    Limit l = limits[i, p];
                    double v = Current(l, now);
                    // у другого ИИ один лимит (например, месяц у Copilot) — нижняя строка пустая
                    string text = l != null ? Math.Round(v) + "%" : i == 1 && ExtraFor(ClockColumns[p][0]) != null ? "" : "—";
                    if (clockValues[i, p].Text != text) clockValues[i, p].Text = text;
                    SetInk(clockValues[i, p], v >= 75 ? Severity(v) : C(light ? "#1C1C1E" : "#FFFFFF"));
                }
            }
            PlaceClockLabel();
        }

        // процент с учётом того, что окно лимита уже закончилось (тогда до нового запроса — 0)
        static double Current(Limit l, DateTime now)
        {
            if (l == null || (l.ResetsAt.HasValue && l.ResetsAt.Value <= now)) return 0;
            return Math.Max(0, Math.Min(100, l.Percent));
        }

        // группа Antigravity для значка в трее: первая из показанных у часов (обычно Gemini)
        AgyGroup ClockGroup()
        {
            if (agyGroups.Count == 0) return null;
            return agyGroups.FirstOrDefault(x => ClockShows(x.Key)) ?? agyGroups.FirstOrDefault(x => x.Key == "gemini") ?? agyGroups[0];
        }

        static void SetInk(TextBlock block, Color color)
        {
            var current = block.Foreground as SolidColorBrush;
            if (current == null || current.Color != color) block.Foreground = B(color);
        }

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr64(IntPtr hwnd, int index, IntPtr value);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong32(IntPtr hwnd, int index, int value);
        const int GWLP_HWNDPARENT = -8;
        IntPtr clockOwner = IntPtr.Zero;

        // Владелец надписи — панель задач: Windows всегда держит окно над его владельцем,
        // поэтому нажатие на панель задач больше не прячет надпись (раньше она мигала до следующей секунды)
        void OwnByTaskbar(IntPtr hwnd, IntPtr bar)
        {
            if (hwnd == IntPtr.Zero || bar == clockOwner) return;
            if (IntPtr.Size == 8) SetWindowLongPtr64(hwnd, GWLP_HWNDPARENT, bar);
            else SetWindowLong32(hwnd, GWLP_HWNDPARENT, bar.ToInt32());
            clockOwner = bar;
        }

        void PlaceClockLabel()
        {
            if (clock == null || !settings.ClockLabel) return;
            IntPtr bar = FindWindow("Shell_TrayWnd", null);
            IntPtr notify = bar == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(bar, IntPtr.Zero, "TrayNotifyWnd", null);
            RECT tb = new RECT(), nr = new RECT();
            bool ok = notify != IntPtr.Zero && GetWindowRect(bar, out tb) && GetWindowRect(notify, out nr)
                      && tb.Right - tb.Left > tb.Bottom - tb.Top;   // только горизонтальная панель задач
            if (ok)
            {
                var screen = WinForms.Screen.FromHandle(bar).Bounds;
                ok = tb.Top < screen.Bottom - 4 && !FullscreenApp(tb);   // панель не спрятана и нет полноэкранного приложения
                if (ok)
                {
                    IntPtr hwnd = new WindowInteropHelper(clock).EnsureHandle();
                    OwnByTaskbar(hwnd, bar);
                    var source = PresentationSource.FromVisual(clock);
                    double scale = source != null && source.CompositionTarget != null ? source.CompositionTarget.TransformToDevice.M11 : 1;
                    int labelWidthPx = (int)(clock.ActualWidth * scale);
                    int labelHeightPx = (int)(clock.ActualHeight * scale);
                    int x = (int)(nr.Left - labelWidthPx + ChevronOverlap * scale);
                    int y = (tb.Top + tb.Bottom) / 2 - labelHeightPx / 2;
                    SetWindowPos(hwnd, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOREDRAW | SWP_NOOWNERZORDER);
                    if (!clock.IsVisible) clock.Show();
                    return;
                }
            }
            if (clock.IsVisible) clock.Hide();
            clockOwner = IntPtr.Zero;
        }

        public Widget(string appDir)
        {
            Directory.CreateDirectory(appDir);
            settingsPath = Path.Combine(appDir, "settings.json");
            cachePath = Path.Combine(appDir, "last-usage.json");
            agyCachePath = Path.Combine(appDir, "last-agy.json");
            codexCachePath = Path.Combine(appDir, "last-codex.json");
        }

        // ---------- настройки ----------
        static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) ? v : null;
        }

        void LoadSettings()
        {
            try
            {
                // первый запуск — берём настройки старого ClaudeLimitWidget (прозрачность, интервал, уведомления…)
                string path = settingsPath;
                if (!File.Exists(path))
                    path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClaudeLimitWidget", "settings.json");
                if (!File.Exists(path)) return;
                var d = json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                object v;
                if ((v = Get(d, "Position")) != null) settings.Position = Convert.ToString(v, Inv);
                if ((v = Get(d, "Transparency")) != null) settings.Transparency = Math.Max(0, Math.Min(3, Convert.ToInt32(v, Inv)));
                if ((v = Get(d, "RefreshMinutes")) != null) settings.RefreshMinutes = Convert.ToInt32(v, Inv);
                if ((v = Get(d, "Left")) != null) settings.Left = Convert.ToDouble(v, Inv);
                if ((v = Get(d, "Top")) != null) settings.Top = Convert.ToDouble(v, Inv);
                if (Get(d, "KeepOpen") is bool) settings.KeepOpen = (bool)Get(d, "KeepOpen");
                if (Get(d, "Notify") is bool) settings.Notify = (bool)Get(d, "Notify");
                if (Get(d, "ClockLabel") is bool) settings.ClockLabel = (bool)Get(d, "ClockLabel");
                if (Get(d, "ShowClaude") is bool) settings.ShowClaude = (bool)Get(d, "ShowClaude");
                if (Get(d, "ShowAgy") is bool) settings.ShowAgy = (bool)Get(d, "ShowAgy");
                if (Get(d, "ShowCodex") is bool) settings.ShowCodex = (bool)Get(d, "ShowCodex");
                if ((v = Get(d, "ClockVersion")) != null) settings.ClockVersion = Convert.ToInt32(v, Inv);
                if ((v = Get(d, "LoggedOut")) != null) settings.LoggedOut = Convert.ToString(v, Inv);
                if (Get(d, "ShowDetails") is bool) settings.ShowDetails = (bool)Get(d, "ShowDetails");
                if ((v = Get(d, "ClockItems")) != null) settings.ClockItems = Convert.ToString(v, Inv);
                if ((v = Get(d, "HiddenExtras")) != null) settings.HiddenExtras = Convert.ToString(v, Inv);
            }
            catch (Exception) { }
            if (!Positions.Contains(settings.Position)) settings.Position = "TR";
            if (!RefreshOptions.Contains(settings.RefreshMinutes)) settings.RefreshMinutes = 2;
            if (!ClockColumns.Any(c => ClockShows(c[0]))) settings.ClockItems = "claude,gemini,3p,codex";
            if (!settings.ShowClaude && !settings.ShowAgy && !settings.ShowCodex) settings.ShowClaude = true;
            // столбец Codex у часов появился позже — у тех, кто уже настраивал надпись, добавляем его один раз
            if (settings.ClockVersion < 2)
            {
                if (!ClockShows("codex")) settings.ClockItems += ",codex";
                settings.ClockVersion = 2;
            }
            // столбцы других ИИ у часов появились ещё позже — тоже включаем один раз (видны, только когда есть вход)
            if (settings.ClockVersion < 3)
            {
                foreach (var x in Extra.All) if (!ClockShows(x[0])) settings.ClockItems += "," + x[0];
                settings.ClockVersion = 3;
            }
        }

        void SaveSettings()
        {
            try
            {
                var d = new Dictionary<string, object> {
                    { "Position", settings.Position }, { "Transparency", settings.Transparency }, { "RefreshMinutes", settings.RefreshMinutes },
                    { "Left", settings.Left }, { "Top", settings.Top }, { "KeepOpen", settings.KeepOpen }, { "Notify", settings.Notify }, { "ClockLabel", settings.ClockLabel },
                    { "ShowClaude", settings.ShowClaude }, { "ShowAgy", settings.ShowAgy }, { "ShowCodex", settings.ShowCodex },
                    { "ClockItems", settings.ClockItems }, { "ClockVersion", settings.ClockVersion }, { "LoggedOut", settings.LoggedOut }, { "ShowDetails", settings.ShowDetails },
                    { "HiddenExtras", settings.HiddenExtras } };
                File.WriteAllText(settingsPath, json.Serialize(d), new UTF8Encoding(false));
            }
            catch (Exception) { }
        }

        // ---------- данные ----------
        static string CredentialsPath
        {
            get
            {
                string dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
                if (string.IsNullOrEmpty(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
                return Path.Combine(dir, ".credentials.json");
            }
        }

        // null — токен есть; иначе текст причины
        string ReadToken(out string token)
        {
            token = null;
            try
            {
                if (!File.Exists(CredentialsPath)) return "Claude Code не найден — войдите в него командой claude";
                var d = json.DeserializeObject(File.ReadAllText(CredentialsPath, Encoding.UTF8)) as Dictionary<string, object>;
                var oauth = Get(d, "claudeAiOauth") as Dictionary<string, object>;
                token = Convert.ToString(Get(oauth, "accessToken"), Inv);
                plan = PlanName(Convert.ToString(Get(oauth, "subscriptionType"), Inv), Convert.ToString(Get(oauth, "rateLimitTier"), Inv));
                if (string.IsNullOrEmpty(token)) return "Нет входа по подписке — выполните /login в Claude Code";
                object exp = Get(oauth, "expiresAt");
                tokenExpires = exp == null ? (DateTime?)null : DateTimeOffset.FromUnixTimeMilliseconds(Convert.ToInt64(exp, Inv)).LocalDateTime;
                ReadAccount();
                if (tokenExpires.HasValue && tokenExpires.Value < DateTime.Now)
                    return "Вход истёк — откройте Claude Code, он обновит его сам";
                return null;
            }
            catch (Exception) { return "Не удалось прочитать вход Claude Code"; }
        }

        // сведения об аккаунте Claude Code хранит в ~/.claude.json → oauthAccount
        void ReadAccount()
        {
            try
            {
                string dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
                string path = string.IsNullOrEmpty(dir)
                    ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude.json")
                    : Path.Combine(dir, ".claude.json");
                if (!File.Exists(path)) return;
                var d = json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                var a = Get(d, "oauthAccount") as Dictionary<string, object>;
                if (a != null) account = a;
            }
            catch (Exception) { }
        }

        static string PlanName(string type, string tier)
        {
            if (string.IsNullOrEmpty(type)) return "";
            string name = char.ToUpper(type[0], Inv) + type.Substring(1);
            var m = System.Text.RegularExpressions.Regex.Match(tier ?? "", @"(\d+)x");
            return m.Success ? name + " " + m.Groups[1].Value + "x" : name;
        }

        // обновить всё, что показываем
        void FetchAll()
        {
            Fetch();
            FetchAgy();
            FetchCodex();
            foreach (var x in extras) FetchExtra(x);
            CheckReturn(true);   // заодно — не вошли ли снова в скрытые после выхода сервисы
        }

        void Fetch()
        {
            if (fetching || !settings.ShowClaude) return;
            string token;
            string problem = ReadToken(out token);
            nextFetch = DateTime.Now.AddMinutes(settings.RefreshMinutes);
            loggedOut = string.IsNullOrEmpty(token);
            if (loggedOut)
            {
                // пока не вошли — проверяем файл входа часто: вход в браузере подхватится за секунды
                if (session != null || account != null) ClearData();
                SetStatus("", false);
                nextFetch = DateTime.Now.AddSeconds(5);
                UpdateView();
                return;
            }
            if (problem != null) { SetStatus(problem, updatedAt == null); UpdateView(); return; }

            fetching = true;
            SetSpin(true);
            var wc = new WebClient { Encoding = Encoding.UTF8 };
            wc.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            wc.Headers["anthropic-beta"] = "oauth-2025-04-20";
            wc.Headers[HttpRequestHeader.UserAgent] = "claude-code/2.0 AiLimitWidget/1.0";
            wc.DownloadStringCompleted += (s, e) =>
            {
                Exception error = e.Error;
                string text = error == null && !e.Cancelled ? e.Result : null;
                wc.Dispose();
                dispatcher.BeginInvoke(new Action(() => FetchDone(text, error)));
            };
            wc.DownloadStringAsync(new Uri(UsageUrl));
        }

        void FetchDone(string text, Exception error)
        {
            fetching = false;
            UpdateSpin();
            if (error == null && text != null && Parse(text))
            {
                updatedAt = DateTime.Now;
                SetStatus("", false);
                try { File.WriteAllText(cachePath, json.Serialize(new Dictionary<string, object> { { "At", updatedAt.Value.ToString("o", Inv) }, { "Body", text } }), new UTF8Encoding(false)); }
                catch (Exception) { }
                CheckNotifications();
            }
            else
            {
                int code = 0;
                var we = error as WebException;
                if (we != null && we.Response is HttpWebResponse) code = (int)((HttpWebResponse)we.Response).StatusCode;
                if (code == 401 || code == 403) SetStatus("Вход устарел — откройте Claude Code, он обновит его сам", updatedAt == null);
                else if (code == 429) { SetStatus("Сервер просит подождать — повторю через 5 мин", false); nextFetch = DateTime.Now.AddMinutes(5); }
                else SetStatus(code > 0 ? "Ошибка сервера (" + code + ")" : "Нет соединения — повторю позже", updatedAt == null);
            }
            UpdateView();
        }

        static DateTime? ParseTime(object v)
        {
            DateTimeOffset t;
            string s = v as string;
            if (!string.IsNullOrEmpty(s) && DateTimeOffset.TryParse(s, Inv, DateTimeStyles.None, out t)) return t.LocalDateTime;
            return null;
        }

        static Limit ReadLimit(Dictionary<string, object> d, string key, string title)
        {
            var o = Get(d, key) as Dictionary<string, object>;
            if (o == null || Get(o, "utilization") == null) return null;
            return new Limit { Key = key, Title = title, Percent = Convert.ToDouble(Get(o, "utilization"), Inv), ResetsAt = ParseTime(Get(o, "resets_at")) };
        }

        bool Parse(string text)
        {
            try
            {
                var d = json.DeserializeObject(text) as Dictionary<string, object>;
                if (d == null) return false;
                session = ReadLimit(d, "five_hour", "Сессия (5 ч)") ?? new Limit { Key = "five_hour", Title = "Сессия (5 ч)" };
                weekly.Clear();
                foreach (var w in WeeklyKeys)
                {
                    var l = ReadLimit(d, w[0], w[1]);
                    if (l != null) weekly.Add(l);
                }
                // платные кредиты сверх подписки — только если включены
                breakdown.Clear();
                var bd = Get(d, "seven_day_breakdown") as Dictionary<string, object>;
                var bdRows = Get(bd, "rows") as System.Collections.IEnumerable;
                if (bdRows != null)
                    foreach (var r in bdRows.OfType<Dictionary<string, object>>())
                        if (Get(r, "percent") != null)
                            breakdown.Add(new KeyValuePair<string, double>(Convert.ToString(Get(r, "display_name"), Inv), Convert.ToDouble(Get(r, "percent"), Inv)));
                var extra = Get(d, "extra_usage") as Dictionary<string, object>;
                extraEnabled = extra != null && Get(extra, "is_enabled") is bool && (bool)Get(extra, "is_enabled");
                if (extra != null && Get(extra, "is_enabled") is bool && (bool)Get(extra, "is_enabled") && Get(extra, "utilization") != null)
                    weekly.Add(new Limit { Key = "extra", Title = "Доп. кредиты (месяц)", Percent = Convert.ToDouble(Get(extra, "utilization"), Inv) });
                return true;
            }
            catch (Exception) { return false; }
        }

        void LoadCache()
        {
            try
            {
                if (!File.Exists(cachePath)) return;
                var d = json.DeserializeObject(File.ReadAllText(cachePath, Encoding.UTF8)) as Dictionary<string, object>;
                if (Parse(Convert.ToString(Get(d, "Body"), Inv)))
                    updatedAt = DateTime.Parse(Convert.ToString(Get(d, "At"), Inv), Inv, DateTimeStyles.RoundtripKind);
            }
            catch (Exception) { }
        }

        void SetStatus(string text, bool error) { status = text; statusIsError = error; }

        // ---------- данные Antigravity ----------
        // «agy -p /quota» в режиме печати отвечает сразу, без запуска агента: 0 токенов, квота не тратится
        static string AgyExe
        {
            get
            {
                string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                string exe = string.IsNullOrEmpty(local) ? null : Path.Combine(local, "agy", "bin", "agy.exe");
                return exe != null && File.Exists(exe) ? exe : "agy";
            }
        }

        static string AgyDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini", "antigravity-cli"); } }

        // выполняет «agy -p <команда> --output-format json»; null — agy не найден или не ответил
        static string RunAgy(string command, out bool missing)
        {
            missing = false;
            try
            {
                // своё автообновление agy запускает в новом окне консоли — при опросе выключаем его, обновляем сами (UpdateAgy)
                return Background.Run(AgyExe, "-p " + command + " --output-format json", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), 45000,
                    new Dictionary<string, string> { { "AGY_CLI_DISABLE_AUTO_UPDATE", "true" } });
            }
            catch (System.ComponentModel.Win32Exception) { missing = true; return null; }
            catch (Exception) { return null; }
        }

        // «agy update» в фоне, без окна и отдельно от опроса: лимиты не ждут обновления.
        // Проверяем с тем же интервалом, что и лимиты; пока одно обновление идёт, второе не запускаем.
        static DateTime agyUpdateCheck = DateTime.MinValue;
        static int agyUpdating;

        static void UpdateAgy(int minutes)
        {
            if (DateTime.Now < agyUpdateCheck.AddMinutes(minutes) || Interlocked.CompareExchange(ref agyUpdating, 1, 0) != 0) return;
            agyUpdateCheck = DateTime.Now;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try { Background.Run(AgyExe, "update", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), 600000); }
                catch (Exception) { }
                finally { agyUpdating = 0; }
            });
        }

        // probe — пробный запрос для скрытого после выхода Antigravity: ответил — значит, снова вошли
        void FetchAgy() { FetchAgy(false); }

        void FetchAgy(bool probe)
        {
            if (agyFetching || (!settings.ShowAgy && !probe)) return;
            agyFetching = true;
            agyNextFetch = DateTime.Now.AddMinutes(settings.RefreshMinutes);
            UpdateAgy(settings.RefreshMinutes);
            SetSpin(true);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                bool missing;
                string quota = RunAgy("/quota", out missing);
                bool ignored;
                string credits = quota == null ? null : RunAgy("/credits", out ignored);
                string email = ReadAgyEmail();
                dispatcher.BeginInvoke(new Action(() => FetchAgyDone(quota, credits, email, missing)));
            });
        }

        void FetchAgyDone(string quota, string credits, string email, bool missing)
        {
            agyFetching = false;
            UpdateSpin();
            agyMissing = missing;
            if (email != null) agyEmail = email;
            string problem = null;
            if (missing) { SetAgyStatus("Antigravity CLI не найден — установите agy", true); agyNextFetch = DateTime.Now.AddMinutes(10); }
            else if (quota != null && ParseAgy(quota, out problem))
            {
                agyUpdatedAt = DateTime.Now;
                SetAgyStatus("", false);
                ParseAgyCredits(credits);
                if (IsLoggedOut("agy")) Return("agy");   // пробный запрос прошёл — в Antigravity снова вошли
                try
                {
                    File.WriteAllText(agyCachePath, json.Serialize(new Dictionary<string, object> {
                        { "At", agyUpdatedAt.Value.ToString("o", Inv) }, { "Body", quota }, { "Credits", credits }, { "Email", agyEmail } }), new UTF8Encoding(false));
                }
                catch (Exception) { }
                CheckNotifications();
            }
            else if (quota != null && problem != null) SetAgyStatus(problem, agyUpdatedAt == null);
            else SetAgyStatus("Antigravity не ответил — повторю позже", agyUpdatedAt == null);
            UpdateView();
        }

        void SetAgyStatus(string text, bool error) { agyStatus = text; agyStatusIsError = error; }

        // «Gemini Models» → «Gemini», «Claude and GPT models» → «Claude и GPT»
        static string AgyTitle(string key, string name)
        {
            if (key == "gemini") return "Gemini";
            if (key == "3p") return "Claude и GPT";
            return (name ?? key).Replace(" Models", "").Replace(" models", "").Replace(" and ", " и ");
        }

        bool ParseAgy(string text, out string problem)
        {
            problem = null;
            try
            {
                var d = json.DeserializeObject(text) as Dictionary<string, object>;
                if (d == null) return false;
                if (Convert.ToString(Get(d, "status"), Inv) != "SUCCESS")
                {
                    string r = Convert.ToString(Get(d, "response") ?? Get(d, "error"), Inv) ?? "";
                    problem = r.IndexOf("sign", StringComparison.OrdinalIgnoreCase) >= 0 || r.IndexOf("auth", StringComparison.OrdinalIgnoreCase) >= 0
                        ? "Нет входа в Antigravity — запустите agy и войдите" : "Antigravity вернул ошибку";
                    return false;
                }
                var data = Get(Get(d, "command") as Dictionary<string, object>, "data") as Dictionary<string, object>;
                var groups = Get(data, "groups") as System.Collections.IEnumerable;
                if (groups == null) { problem = "Antigravity не сообщил лимиты"; return false; }
                var list = new List<AgyGroup>();
                foreach (var gr in groups.OfType<Dictionary<string, object>>())
                {
                    var g = new AgyGroup();
                    string models = Convert.ToString(Get(gr, "description"), Inv) ?? "";
                    int colon = models.IndexOf(':');
                    g.Models = colon >= 0 ? models.Substring(colon + 1).Trim() : "";
                    var buckets = Get(gr, "buckets") as System.Collections.IEnumerable;
                    if (buckets == null) continue;
                    foreach (var b in buckets.OfType<Dictionary<string, object>>())
                    {
                        string id = Convert.ToString(Get(b, "id"), Inv) ?? "";
                        int dash = id.LastIndexOf('-');
                        if (g.Key == null && dash > 0) g.Key = id.Substring(0, dash);
                        string window = Convert.ToString(Get(b, "window"), Inv);
                        // окно сейчас не действует: «disabled» приходит вместе с remaining_fraction = 1, это не «0% израсходовано»
                        if (Get(b, "remaining_fraction") == null || Convert.ToBoolean(Get(b, "disabled") ?? false, Inv))
                        {
                            if (window == "5h") g.SessionOff = true;
                            continue;
                        }
                        var l = new Limit { Key = id, Percent = Math.Max(0, Math.Min(100, (1 - Convert.ToDouble(Get(b, "remaining_fraction"), Inv)) * 100)),
                                            ResetsAt = ParseTime(Get(b, "reset_time")) };
                        if (window == "5h") { l.Title = "5 часов"; g.Session = l; }
                        else if (window == "weekly") { l.Title = "Неделя"; g.Week = l; }
                    }
                    if (g.Key == null) g.Key = Convert.ToString(Get(gr, "name"), Inv);
                    g.Title = AgyTitle(g.Key, Convert.ToString(Get(gr, "name"), Inv));
                    if (g.Session != null) g.Session.Title = g.Title + " · 5 ч";
                    if (g.Week != null) g.Week.Title = g.Title + " · неделя";
                    list.Add(g);
                }
                agyGroups.Clear();
                agyGroups.AddRange(list);
                return true;
            }
            catch (Exception) { return false; }
        }

        void ParseAgyCredits(string text)
        {
            try
            {
                var d = text == null ? null : json.DeserializeObject(text) as Dictionary<string, object>;
                var data = Get(Get(d, "command") as Dictionary<string, object>, "data") as Dictionary<string, object>;
                object c = Get(data, "remaining_credits");
                if (c != null) agyCredits = Convert.ToDouble(c, Inv);
            }
            catch (Exception) { }
        }

        // почту Antigravity пишет в свой журнал при входе: «applyAuthResult: email=…»
        static string ReadAgyEmail()
        {
            try
            {
                string log = Path.Combine(AgyDir, "cli.log");
                if (File.Exists(log))
                    using (var fs = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var sr = new StreamReader(fs, Encoding.UTF8))
                    {
                        var ms = System.Text.RegularExpressions.Regex.Matches(sr.ReadToEnd(), @"applyAuthResult: email=([^,\s]+@[^,\s]+)");
                        if (ms.Count > 0) return ms[ms.Count - 1].Groups[1].Value;
                    }
            }
            catch (Exception) { }
            return null;
        }

        void LoadAgyCache()
        {
            try
            {
                if (!File.Exists(agyCachePath)) return;
                var d = json.DeserializeObject(File.ReadAllText(agyCachePath, Encoding.UTF8)) as Dictionary<string, object>;
                string problem;
                if (ParseAgy(Convert.ToString(Get(d, "Body"), Inv), out problem))
                    agyUpdatedAt = DateTime.Parse(Convert.ToString(Get(d, "At"), Inv), Inv, DateTimeStyles.RoundtripKind);
                ParseAgyCredits(Convert.ToString(Get(d, "Credits"), Inv));
                agyEmail = Convert.ToString(Get(d, "Email"), Inv);
            }
            catch (Exception) { }
        }

        // ---------- данные Codex ----------
        // Вход Codex хранит в ~/.codex/auth.json (вход через ChatGPT); виджет его только читает.
        // Лимиты — тот же запрос, что делает /status в самом Codex.
        const string CodexUsageUrl = "https://chatgpt.com/backend-api/wham/usage";
        readonly string codexCachePath;
        readonly List<Limit> codexLimits = new List<Limit>();
        string codexPlan = "", codexEmail, codexStatus = "";
        bool codexStatusIsError, codexFetching, codexMissing;
        DateTime? codexUpdatedAt;
        DateTime codexNextFetch = DateTime.MinValue;

        static string CodexAuthPath
        {
            get
            {
                string dir = Environment.GetEnvironmentVariable("CODEX_HOME");
                if (string.IsNullOrEmpty(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
                return Path.Combine(dir, "auth.json");
            }
        }

        // средняя часть JWT (id_token) — там почта и тариф
        Dictionary<string, object> JwtClaims(string jwt)
        {
            try
            {
                string[] parts = (jwt ?? "").Split('.');
                if (parts.Length < 2) return null;
                string p = parts[1].Replace('-', '+').Replace('_', '/');
                p = p.PadRight(p.Length + (4 - p.Length % 4) % 4, '=');
                return json.DeserializeObject(Encoding.UTF8.GetString(Convert.FromBase64String(p))) as Dictionary<string, object>;
            }
            catch (Exception) { return null; }
        }

        void FetchCodex()
        {
            if (codexFetching || !settings.ShowCodex) return;
            codexNextFetch = DateTime.Now.AddMinutes(settings.RefreshMinutes);
            string token = null, accountId = null;
            try
            {
                codexMissing = !File.Exists(CodexAuthPath);
                if (codexMissing)
                {
                    SetCodexStatus("Нет входа в Codex — выполните codex login", false);
                    codexNextFetch = DateTime.Now.AddMinutes(1);   // вход подхватится вскоре после «codex login»
                    UpdateView();
                    return;
                }
                var d = json.DeserializeObject(File.ReadAllText(CodexAuthPath, Encoding.UTF8)) as Dictionary<string, object>;
                var tokens = Get(d, "tokens") as Dictionary<string, object>;
                token = Convert.ToString(Get(tokens, "access_token"), Inv);
                accountId = Convert.ToString(Get(tokens, "account_id"), Inv);
                string email = Convert.ToString(Get(JwtClaims(Convert.ToString(Get(tokens, "id_token"), Inv)), "email"), Inv);
                if (!string.IsNullOrEmpty(email)) codexEmail = email;
            }
            catch (Exception) { SetCodexStatus("Не удалось прочитать вход Codex", codexUpdatedAt == null); UpdateView(); return; }
            if (string.IsNullOrEmpty(token))
            {
                SetCodexStatus("Codex вошёл по API-ключу — лимитов подписки нет. Для них: codex login", false);
                UpdateView();
                return;
            }

            codexFetching = true;
            SetSpin(true);
            var wc = new WebClient { Encoding = Encoding.UTF8 };
            wc.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            if (!string.IsNullOrEmpty(accountId)) wc.Headers["ChatGPT-Account-Id"] = accountId;
            wc.Headers[HttpRequestHeader.UserAgent] = "codex_cli_rs AiLimitWidget/1.0";
            wc.Headers["originator"] = "codex_cli_rs";
            wc.DownloadStringCompleted += (s, e) =>
            {
                Exception error = e.Error;
                string text = error == null && !e.Cancelled ? e.Result : null;
                wc.Dispose();
                dispatcher.BeginInvoke(new Action(() => FetchCodexDone(text, error)));
            };
            wc.DownloadStringAsync(new Uri(CodexUsageUrl));
        }

        void FetchCodexDone(string text, Exception error)
        {
            codexFetching = false;
            UpdateSpin();
            if (error == null && text != null && ParseCodex(text))
            {
                codexUpdatedAt = DateTime.Now;
                SetCodexStatus("", false);
                try
                {
                    File.WriteAllText(codexCachePath, json.Serialize(new Dictionary<string, object> {
                        { "At", codexUpdatedAt.Value.ToString("o", Inv) }, { "Body", text }, { "Email", codexEmail } }), new UTF8Encoding(false));
                }
                catch (Exception) { }
                CheckNotifications();
            }
            else
            {
                int code = 0;
                var we = error as WebException;
                if (we != null && we.Response is HttpWebResponse) code = (int)((HttpWebResponse)we.Response).StatusCode;
                if (code == 401 || code == 403) SetCodexStatus("Вход Codex устарел — запустите codex, он обновит его сам", codexUpdatedAt == null);
                else if (code == 429) { SetCodexStatus("Сервер просит подождать — повторю через 5 мин", false); codexNextFetch = DateTime.Now.AddMinutes(5); }
                else SetCodexStatus(code > 0 ? "Ошибка сервера Codex (" + code + ")" : "Нет соединения — повторю позже", codexUpdatedAt == null);
            }
            UpdateView();
        }

        void SetCodexStatus(string text, bool error) { codexStatus = text; codexStatusIsError = error; }

        // 18000 с → «Сессия (5 ч)», 604800 → «Неделя», 2592000 → «30 дней»
        static string WindowTitle(long seconds)
        {
            if (seconds <= 0) return "Лимит";
            if (seconds <= 24 * 3600) return "Сессия (" + Math.Round(seconds / 3600.0) + " ч)";
            if (seconds <= 8 * 24 * 3600) return "Неделя";
            return Math.Round(seconds / 86400.0) + " дней";
        }

        bool ParseCodex(string text)
        {
            try
            {
                var d = json.DeserializeObject(text) as Dictionary<string, object>;
                if (d == null) return false;
                string plan = Convert.ToString(Get(d, "plan_type"), Inv);
                codexPlan = string.IsNullOrEmpty(plan) ? "" : char.ToUpper(plan[0], Inv) + plan.Substring(1);
                var rl = Get(d, "rate_limit") as Dictionary<string, object>;
                var list = new List<Limit>();
                foreach (string w in new[] { "primary_window", "secondary_window" })
                {
                    var o = Get(rl, w) as Dictionary<string, object>;
                    if (o == null || Get(o, "used_percent") == null) continue;
                    long secs = Get(o, "limit_window_seconds") == null ? 0 : Convert.ToInt64(Get(o, "limit_window_seconds"), Inv);
                    object at = Get(o, "reset_at");
                    list.Add(new Limit { Key = "codex-" + w, Title = WindowTitle(secs), WindowSeconds = secs,
                                         Percent = Math.Max(0, Math.Min(100, Convert.ToDouble(Get(o, "used_percent"), Inv))),
                                         ResetsAt = at == null ? (DateTime?)null : DateTimeOffset.FromUnixTimeSeconds(Convert.ToInt64(at, Inv)).LocalDateTime });
                }
                codexLimits.Clear();
                codexLimits.AddRange(list.OrderBy(l => l.WindowSeconds));
                return true;
            }
            catch (Exception) { return false; }
        }

        void LoadCodexCache()
        {
            try
            {
                if (!File.Exists(codexCachePath)) return;
                var d = json.DeserializeObject(File.ReadAllText(codexCachePath, Encoding.UTF8)) as Dictionary<string, object>;
                if (ParseCodex(Convert.ToString(Get(d, "Body"), Inv)))
                    codexUpdatedAt = DateTime.Parse(Convert.ToString(Get(d, "At"), Inv), Inv, DateTimeStyles.RoundtripKind);
                codexEmail = Convert.ToString(Get(d, "Email"), Inv);
            }
            catch (Exception) { }
        }

        // у часов: «Сессия» — короткое окно Codex (до суток), «Неделя» — самое длинное из остальных
        Limit CodexShort { get { return codexLimits.FirstOrDefault(l => l.WindowSeconds <= 24 * 3600); } }
        Limit CodexLong { get { return codexLimits.LastOrDefault(l => l.WindowSeconds > 24 * 3600); } }

        // ---------- данные других ИИ ----------
        // Вход не нашли — раздел не показываем и проверяем раз в несколько минут: вдруг войдут.
        readonly List<ExtraProvider> extras = Extra.All.Select(x => new ExtraProvider { Key = x[0], Name = x[1], Color = C(x[2]) }).ToList();

        ExtraProvider ExtraFor(string key) { return extras.FirstOrDefault(x => x.Key == key); }
        bool ExtraOn(string key) { return !settings.HiddenExtras.Split(',').Contains(key); }
        List<ExtraProvider> ShownExtras { get { return extras.Where(x => x.SignedIn && ExtraOn(x.Key)).ToList(); } }

        void FetchExtra(ExtraProvider x)
        {
            if (x.Fetching || !ExtraOn(x.Key)) return;
            x.Fetching = true;
            x.NextFetch = DateTime.Now.AddMinutes(settings.RefreshMinutes);
            UpdateSpin();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                ExtraResult r;
                try { r = Extra.Fetch(x.Key); }
                catch (Exception) { r = new ExtraResult { Problem = "Нет соединения — повторю позже" }; }
                dispatcher.BeginInvoke(new Action(() => FetchExtraDone(x, r)));
            });
        }

        void FetchExtraDone(ExtraProvider x, ExtraResult r)
        {
            x.Fetching = false;
            bool wasShown = x.SignedIn;
            x.SignedIn = r.SignedIn;
            if (!r.SignedIn)
            {
                x.Limits.Clear();
                x.Plan = "";
                x.Email = null;
                x.UpdatedAt = null;
                x.NextFetch = DateTime.Now.AddMinutes(Math.Max(settings.RefreshMinutes, 5));
            }
            else
            {
                if (!string.IsNullOrEmpty(r.Plan)) x.Plan = r.Plan;
                if (!string.IsNullOrEmpty(r.Email)) x.Email = r.Email;
                if (r.Problem == null || r.Limits.Count > 0)
                {
                    x.Limits.Clear();
                    x.Limits.AddRange(r.Limits);
                    x.UpdatedAt = DateTime.Now;
                }
                x.Status = r.Problem ?? "";
                x.StatusIsError = r.Problem != null && x.UpdatedAt == null;
                if (r.RetryAfterSeconds > 0) x.NextFetch = DateTime.Now.AddSeconds(r.RetryAfterSeconds);
                CheckNotifications();
            }
            if (wasShown != x.SignedIn) lastTrayKey = null;
            UpdateSpin();
            UpdateView();
        }

        // уведомление, когда лимит переходит 80% и 95% (один раз на окно лимита)
        void CheckNotifications()
        {
            if (!settings.Notify || tray == null) return;
            var all = new List<KeyValuePair<string, Limit>>();
            if (settings.ShowClaude)
            {
                if (session != null) all.Add(new KeyValuePair<string, Limit>("Claude Code", session));
                foreach (var w in weekly) all.Add(new KeyValuePair<string, Limit>("Claude Code", w));
            }
            if (settings.ShowAgy)
                foreach (var g in agyGroups)
                {
                    if (g.Session != null) all.Add(new KeyValuePair<string, Limit>("Antigravity", g.Session));
                    if (g.Week != null) all.Add(new KeyValuePair<string, Limit>("Antigravity", g.Week));
                }
            if (settings.ShowCodex)
                foreach (var l in codexLimits) all.Add(new KeyValuePair<string, Limit>("Codex", l));
            foreach (var x in ShownExtras)
                foreach (var l in x.Limits) all.Add(new KeyValuePair<string, Limit>(x.Name, l));
            foreach (var pair in all)
                foreach (int t in NotifyThresholds.Reverse())
                {
                    Limit l = pair.Value;
                    if (Current(l, DateTime.Now) < t) continue;
                    string id = pair.Key + "|" + l.Key + "|" + (l.ResetsAt.HasValue ? l.ResetsAt.Value.ToString("o", Inv) : "") + "|" + t;
                    if (notified.Add(id))
                    {
                        string when = l.ResetsAt.HasValue ? "Сброс через " + Duration(l.ResetsAt.Value - DateTime.Now) + "." : "";
                        tray.ShowBalloonTip(8000, pair.Key + ": " + l.Title + " — " + Math.Round(l.Percent) + "%", when,
                                            t >= 95 ? WinForms.ToolTipIcon.Warning : WinForms.ToolTipIcon.Info);
                    }
                    break;
                }
        }

        // ---------- форматирование ----------
        static string Duration(TimeSpan span)
        {
            if (span.TotalSeconds < 60) return "меньше минуты";
            int days = span.Days, hours = span.Hours, minutes = span.Minutes;
            if (days > 0) return days + " д " + hours + " ч";
            if (hours > 0) return hours + " ч " + minutes.ToString("00", Inv) + " мин";
            return minutes + " мин";
        }

        static string ResetMoment(DateTime at)
        {
            if (at.Date == DateTime.Today) return "сегодня в " + at.ToString("HH:mm", Inv);
            if (at.Date == DateTime.Today.AddDays(1)) return "завтра в " + at.ToString("HH:mm", Inv);
            return at.ToString("ddd, d MMM в HH:mm", Ru);
        }

        // ---------- окно ----------
        const string MainXaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='Лимиты ИИ' SizeToContent='WidthAndHeight'
        WindowStyle='SingleBorderWindow' AllowsTransparency='False' Background='Transparent'
        ShowInTaskbar='False' ShowActivated='False' ResizeMode='NoResize' FontFamily='Segoe UI Variable Display, Segoe UI'
        UseLayoutRounding='True' TextOptions.TextFormattingMode='Ideal'>
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight='0' GlassFrameThickness='0' ResizeBorderThickness='0' CornerRadius='0' UseAeroCaptionButtons='False'/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <LinearGradientBrush x:Key='CapsuleRim' StartPoint='0,0' EndPoint='0,1'>
      <GradientStop Color='#8CFFFFFF' Offset='0'/>
      <GradientStop Color='#14FFFFFF' Offset='0.5'/>
      <GradientStop Color='#40FFFFFF' Offset='1'/>
    </LinearGradientBrush>
    <Style x:Key='RoundBtn' TargetType='Border'>
      <Setter Property='Width' Value='26'/>
      <Setter Property='Height' Value='26'/>
      <Setter Property='CornerRadius' Value='13'/>
      <Setter Property='Margin' Value='4,0,0,0'/>
      <Setter Property='Cursor' Value='Hand'/>
      <Setter Property='Background' Value='#01FFFFFF'/>
      <Setter Property='BorderThickness' Value='1'/>
      <Setter Property='BorderBrush' Value='{StaticResource CapsuleRim}'/>
    </Style>
  </Window.Resources>
  <Border x:Name='Surface' CornerRadius='8' BorderThickness='1.5'>
    <Border.Resources>
      <Style TargetType='TextBlock'>
        <Setter Property='Effect'>
          <Setter.Value><DropShadowEffect Color='Black' BlurRadius='6' ShadowDepth='0' Opacity='0.55'/></Setter.Value>
        </Setter>
      </Style>
    </Border.Resources>
    <Border.BorderBrush>
      <LinearGradientBrush StartPoint='0,0' EndPoint='1,1'>
        <GradientStop Color='#B3FFFFFF' Offset='0'/>
        <GradientStop Color='#26FFFFFF' Offset='0.3'/>
        <GradientStop Color='#0DFFFFFF' Offset='0.6'/>
        <GradientStop Color='#59FFFFFF' Offset='1'/>
      </LinearGradientBrush>
    </Border.BorderBrush>
    <Grid x:Name='Root' Width='344.2'>
      <Border x:Name='Shine' VerticalAlignment='Top' Height='70' IsHitTestVisible='False'>
        <Border.Background>
          <LinearGradientBrush StartPoint='0,0' EndPoint='0,1'>
            <GradientStop Color='#2EFFFFFF' Offset='0'/>
            <GradientStop Color='#00FFFFFF' Offset='1'/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>
      <StackPanel x:Name='Body' Margin='14,12,12,14'>
        <Grid x:Name='Header'>
          <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
          <Grid Width='24' Height='24' VerticalAlignment='Center'>
            <Path Width='15' Height='15' Stretch='Uniform' Stroke='#D97757' StrokeThickness='2.4' StrokeStartLineCap='Round' StrokeEndLineCap='Round'
                  HorizontalAlignment='Left' VerticalAlignment='Top' Data='M12,1 L12,23 M1,12 L23,12 M4.2,4.2 L19.8,19.8 M4.2,19.8 L19.8,4.2'/>
            <Path Width='13' Height='13' Stretch='Uniform' Fill='#34C759' HorizontalAlignment='Right' VerticalAlignment='Bottom'
                  Data='M12,0 C12,6.6 17.4,12 24,12 C17.4,12 12,17.4 12,24 C12,17.4 6.6,12 0,12 C6.6,12 12,6.6 12,0 Z'/>
          </Grid>
          <StackPanel Grid.Column='1' Margin='9,0,6,0' VerticalAlignment='Center'>
            <TextBlock Text='Лимиты ИИ' FontSize='15' FontWeight='SemiBold' Foreground='#F5F5F7'/>
            <TextBlock x:Name='SubText' FontSize='11.5' Foreground='#AEAEB2' TextTrimming='CharacterEllipsis'/>
          </StackPanel>
          <StackPanel Grid.Column='2' Orientation='Horizontal' VerticalAlignment='Center'>
            <Border x:Name='RefreshBtn' Style='{StaticResource RoundBtn}' ToolTip='Обновить'>
              <Path Width='12' Height='12' Stretch='Uniform' Stroke='#D1D1D6' StrokeThickness='1.6' StrokeStartLineCap='Round' StrokeEndLineCap='Round'
                    StrokeLineJoin='Round' HorizontalAlignment='Center' VerticalAlignment='Center' RenderTransformOrigin='0.5,0.5'
                    Data='M12.5,4 A6,6 0 1 0 13.8,8.5 M12.8,0.8 L12.6,4.2 L9.2,4'>
                <Path.RenderTransform><RotateTransform x:Name='RefreshRotate' Angle='0'/></Path.RenderTransform>
              </Path>
            </Border>
            <Border x:Name='MenuBtn' Style='{StaticResource RoundBtn}'>
              <StackPanel Orientation='Horizontal' HorizontalAlignment='Center' VerticalAlignment='Center'>
                <Ellipse Width='3.5' Height='3.5' Fill='#D1D1D6' Margin='1.2,0'/>
                <Ellipse Width='3.5' Height='3.5' Fill='#D1D1D6' Margin='1.2,0'/>
                <Ellipse Width='3.5' Height='3.5' Fill='#D1D1D6' Margin='1.2,0'/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Grid>
        <StackPanel x:Name='Rows' Margin='0,4,0,0'/>
        <TextBlock x:Name='StatusText' FontSize='12' TextWrapping='Wrap' Margin='0,8,0,0' Visibility='Collapsed'/>
        <StackPanel x:Name='Details' Visibility='Collapsed'/>
      </StackPanel>
    </Grid>
  </Border>
</Window>";

        T2 Find<T2>(string name) where T2 : class { return window.FindName(name) as T2; }

        public void Init()
        {
            LoadSettings();
            ReadAccount();
            LoadCache();
            LoadAgyCache();
            LoadCodexCache();

            window = (Window)XamlReader.Parse(MainXaml);
            window.Topmost = true;
            var surface = Find<Border>("Surface");
            Glass.Apply(window, surface, B("#F2262628"), settings.Transparency < 3);
            ApplyTint();

            Button(Find<Border>("RefreshBtn"), FetchAll);
            var menuBtn = Find<Border>("MenuBtn");
            Button(menuBtn, () => ShowMenu(menuBtn));

            // окно открывается по нажатию на надпись у часов и прячется, когда нажали в другое место
            // (если не закреплено кнопкой-булавкой)
            window.Activated += (s, e) =>
            {
                activeSinceShow = true;
                if (preview) { preview = false; HookMouse(true); UpdateView(); }
            };
            window.Deactivated += (s, e) =>
            {
                if (!activeSinceShow || settings.KeepOpen || (menu != null && menu.IsOpen)) return;
                HideWidget();
            };
            window.SizeChanged += (s, e) =>
            {
                Dock();
                dispatcher.BeginInvoke(new Action(Dock), DispatcherPriority.Loaded);   // ещё раз — когда WPF уже поменял размер окна
            };
            SystemEvents.DisplaySettingsChanged += (s, e) => dispatcher.BeginInvoke(new Action(Dock));

            menu = new ContextMenu { Style = (Style)MenuStyles["DarkMenu"], Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint };
            menu.Resources.MergedDictionaries.Add(MenuStyles);
            menu.Closed += (s, e) => { if (window.IsVisible) window.Activate(); };
            tray = new WinForms.NotifyIcon { Visible = true };
            InitClockLabel();
            tray.MouseClick += (s, e) =>
            {
                if (e.Button == WinForms.MouseButtons.Left) ToggleWindow();
            };

            spin = new Storyboard { RepeatBehavior = RepeatBehavior.Forever };
            var rot = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9));
            Storyboard.SetTarget(rot, Find<Border>("RefreshBtn").Child);
            Storyboard.SetTargetProperty(rot, new PropertyPath("RenderTransform.Angle"));
            spin.Children.Add(rot);

            timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (s, e) => Tick();
            timer.Start();

            UpdateView();
            uint uptimeMs = unchecked((uint)Environment.TickCount);
            if (uptimeMs < 3 * 60 * 1000)
            {
                int delayMs = Math.Max(60000, (int)(3 * 60 * 1000 - uptimeMs));
                DateTime startAt = DateTime.Now.AddMilliseconds(delayMs);
                startDelayUntil = startAt;
                nextFetch = startAt;
                agyNextFetch = startAt;
                codexNextFetch = startAt;
                foreach (var x in extras) x.NextFetch = startAt;
            }
            else
            {
                FetchAll();
            }
        }

        bool activeSinceShow;
        DateTime hiddenAt = DateTime.MinValue;
        DateTime startDelayUntil = DateTime.MinValue;   // сразу после включения ПК ничего не запускаем — Windows и так загружена

        void Tick()
        {
            if (DateTime.Now < startDelayUntil) { UpdateView(); return; }
            // окно лимита закончилось — сразу спрашиваем новые данные
            bool expired = session != null && session.ResetsAt.HasValue && session.ResetsAt.Value <= DateTime.Now;
            if (!fetching && (DateTime.Now >= nextFetch || (expired && DateTime.Now >= nextFetch.AddMinutes(-settings.RefreshMinutes).AddSeconds(20))))
                Fetch();
            // то же для Antigravity: закончилось окно любой группы — спрашиваем раньше срока
            bool agyExpired = agyGroups.Any(g => (g.Session != null && g.Session.ResetsAt.HasValue && g.Session.ResetsAt.Value <= DateTime.Now && g.Session.Percent > 0)
                                              || (g.Week != null && g.Week.ResetsAt.HasValue && g.Week.ResetsAt.Value <= DateTime.Now && g.Week.Percent > 0));
            if (!agyFetching && (DateTime.Now >= agyNextFetch || (agyExpired && DateTime.Now >= agyNextFetch.AddMinutes(-settings.RefreshMinutes).AddSeconds(20))))
                FetchAgy();
            bool codexExpired = codexLimits.Any(l => l.ResetsAt.HasValue && l.ResetsAt.Value <= DateTime.Now && l.Percent > 0);
            if (!codexFetching && (DateTime.Now >= codexNextFetch || (codexExpired && DateTime.Now >= codexNextFetch.AddMinutes(-settings.RefreshMinutes).AddSeconds(20))))
                FetchCodex();
            foreach (var x in extras.Where(e => !e.Fetching))
            {
                bool extraExpired = x.Limits.Any(l => l.ResetsAt.HasValue && l.ResetsAt.Value <= DateTime.Now && l.Percent > 0);
                if (DateTime.Now >= x.NextFetch || (extraExpired && DateTime.Now >= x.NextFetch.AddMinutes(-settings.RefreshMinutes).AddSeconds(20)))
                    FetchExtra(x);
            }
            CheckReturn(false);
            UpdateView();
        }

        static void Button(Border b, Action click)
        {
            b.MouseEnter += (s, e) => b.Background = B("#26FFFFFF");
            b.MouseLeave += (s, e) => b.Background = B("#01FFFFFF");
            b.MouseLeftButtonDown += (s, e) => { e.Handled = true; b.Background = B("#40FFFFFF"); };
            b.MouseLeftButtonUp += (s, e) => { e.Handled = true; b.Background = B("#26FFFFFF"); click(); };
        }


        // фоновая проверка «не вошли ли» в скрытый другой ИИ кнопку не крутит
        bool AnyFetching { get { return fetching || agyFetching || codexFetching || extras.Any(x => x.Fetching && x.SignedIn); } }

        void UpdateSpin() { SetSpin(AnyFetching); }

        void SetSpin(bool on)
        {
            if (spin == null) return;
            if (on) spin.Begin();
            else spin.Stop();
        }

        static readonly byte[][] TintLevels = { new byte[] { 0x99, 0xB3 }, new byte[] { 0x66, 0x80 }, new byte[] { 0x40, 0x59 }, new byte[] { 0x40, 0x59 } };

        void ApplyTint()
        {
            var surface = Find<Border>("Surface");
            if (surface == null || "opaque".Equals(surface.Tag)) return;
            var level = TintLevels[settings.Transparency];
            surface.Background = new LinearGradientBrush(Color.FromArgb(level[0], 0x30, 0x30, 0x36), Color.FromArgb(level[1], 0x1C, 0x1C, 0x1E), 90);
        }

        void UpdateView()
        {
            if (window == null) return;
            DateTime now = DateTime.Now;
            bool active = session != null && session.ResetsAt.HasValue && session.ResetsAt.Value > now;
            double pct = active ? session.Percent : 0;

            // по разделу на сервис: Claude Code (оранжевый) и Antigravity (синий)
            var rows = Find<StackPanel>("Rows");
            rows.Children.Clear();
            if (confirmLogout || loggingOut)
                rows.Children.Add(LogoutPanel());
            else
            {
                if (settings.ShowClaude)
                {
                    rows.Children.Add(ProviderHeader("Claude Code", new[] { Accent }, plan, rows.Children.Count == 0));
                    if (loggedOut)
                        rows.Children.Add(LoginPanel());
                    else if (session == null)
                        rows.Children.Add(Hint("Загрузка…"));
                    else
                        rows.Children.Add(Row(session, now, active ? null : "Не начата — 5-часовое окно начнётся с первого запроса", Accent));
                    if (!loggedOut)
                        foreach (var l in weekly) rows.Children.Add(Row(l, now, null, Accent));
                    if (!string.IsNullOrEmpty(status)) rows.Children.Add(StatusLine(status, statusIsError));
                }
                if (settings.ShowAgy)
                {
                    string credits = agyCredits.HasValue && agyCredits.Value > 0 ? "кредиты: " + Math.Round(agyCredits.Value) : null;
                    rows.Children.Add(ProviderHeader("Antigravity", new[] { GeminiColor, AgyClaudeColor }, credits, rows.Children.Count == 0));
                    if (agyGroups.Count == 0 && string.IsNullOrEmpty(agyStatus))
                        rows.Children.Add(Hint("Загрузка…"));
                    foreach (var g in agyGroups) rows.Children.Add(AgyRow(g, now));
                    if (!string.IsNullOrEmpty(agyStatus)) rows.Children.Add(StatusLine(agyStatus, agyStatusIsError));
                }
                if (settings.ShowCodex)
                {
                    rows.Children.Add(ProviderHeader("Codex", new[] { CodexColor }, codexPlan, rows.Children.Count == 0));
                    if (codexLimits.Count == 0 && string.IsNullOrEmpty(codexStatus))
                        rows.Children.Add(Hint(codexUpdatedAt.HasValue ? "Сервер не сообщил лимиты" : "Загрузка…"));
                    foreach (var l in codexLimits) rows.Children.Add(Row(l, now, null, CodexColor));
                    if (!string.IsNullOrEmpty(codexStatus)) rows.Children.Add(StatusLine(codexStatus, codexStatusIsError));
                }
                // другие ИИ — только те, в которые вошли; у каждого свой цвет
                foreach (var x in ShownExtras)
                {
                    rows.Children.Add(ProviderHeader(x.Name, new[] { x.Color }, x.Plan, rows.Children.Count == 0));
                    if (x.Limits.Count == 0 && string.IsNullOrEmpty(x.Status)) rows.Children.Add(Hint("Загрузка…"));
                    foreach (var l in x.Limits) rows.Children.Add(Row(l, now, null, x.Color));
                    if (!string.IsNullOrEmpty(x.Status)) rows.Children.Add(StatusLine(x.Status, x.StatusIsError));
                }
            }

            // подпись: когда обновлялось (по самому свежему из сервисов)
            string sub;
            DateTime? last = Max(Max(settings.ShowClaude ? updatedAt : null, settings.ShowAgy ? agyUpdatedAt : null), settings.ShowCodex ? codexUpdatedAt : null);
            foreach (var x in ShownExtras) last = Max(last, x.UpdatedAt);
            if (AnyFetching) sub = "обновление…";
            else if (last.HasValue) sub = "обновлено " + last.Value.ToString(last.Value.Date == now.Date ? "HH:mm" : "d MMM HH:mm", Ru);
            else sub = "";
            Find<TextBlock>("SubText").Text = sub;
            Find<TextBlock>("StatusText").Visibility = Visibility.Collapsed;   // статусы теперь у каждого сервиса свои

            // открыто наведением — только полосы лимитов и время сброса, без шапки и подробностей
            Find<Grid>("Header").Visibility = preview ? Visibility.Collapsed : Visibility.Visible;
            Find<Border>("Shine").Visibility = preview ? Visibility.Collapsed : Visibility.Visible;
            Find<StackPanel>("Body").Margin = preview ? new Thickness(14, 2, 12, 12) : new Thickness(14, 12, 12, 14);
            var details = Find<StackPanel>("Details");
            details.Visibility = preview ? Visibility.Collapsed : Visibility.Visible;
            if (window.IsVisible && !preview && !confirmLogout && !loggingOut) BuildDetails(details, now);
            else details.Children.Clear();

            UpdateTray(pct, active);
            UpdateClockLabel(pct, active);
        }

        static DateTime? Max(DateTime? a, DateTime? b)
        {
            if (!a.HasValue) return b;
            if (!b.HasValue) return a;
            return a.Value > b.Value ? a : b;
        }

        static UIElement Hint(string text)
        {
            return new TextBlock { Text = text, FontSize = 12.5, Foreground = B("#AEAEB2"), Margin = new Thickness(0, 8, 0, 0) };
        }

        static UIElement StatusLine(string text, bool error)
        {
            return new TextBlock { Text = text, FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
                                   Foreground = error ? B("#FF6961") : B("#8E8E93") };
        }

        static System.Windows.Shapes.Ellipse Dot(Color color, double size, Thickness margin)
        {
            return new System.Windows.Shapes.Ellipse { Width = size, Height = size, Fill = B(color), VerticalAlignment = VerticalAlignment.Center, Margin = margin };
        }

        // заголовок раздела: цветные точки его лимитов, название и справа мелкая подпись (план, кредиты)
        static UIElement ProviderHeader(string name, Color[] colors, string note, bool first)
        {
            var panel = new StackPanel { Margin = new Thickness(0, first ? 8 : 14, 0, 0) };
            if (!first) panel.Children.Add(new Border { Height = 1, Background = B("#1FFFFFFF"), Margin = new Thickness(0, 0, 0, 10) });
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 7, 0) };
            for (int i = 0; i < colors.Length; i++) dots.Children.Add(Dot(colors[i], 8, new Thickness(i == 0 ? 0 : -2, 0, 0, 0)));   // точки чуть внахлёст
            g.Children.Add(dots);
            var title = new TextBlock { Text = name, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = B("#F5F5F7") };
            Grid.SetColumn(title, 1);
            g.Children.Add(title);
            if (!string.IsNullOrEmpty(note))
            {
                var right = new TextBlock { Text = note, FontSize = 11, Foreground = B("#8E8E93"), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(right, 2);
                g.Children.Add(right);
            }
            panel.Children.Add(g);
            return panel;
        }

        // группа Antigravity: название и две полосы рядом — 5 часов и неделя
        UIElement AgyRow(AgyGroup g, DateTime now)
        {
            var panel = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            Color color = GroupColor(g.Key);
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition());
            head.Children.Add(Dot(color, 6, new Thickness(0, 1, 6, 0)));
            var title = new TextBlock { Text = g.Title, FontSize = 12.5, Foreground = B("#D1D1D6") };
            Grid.SetColumn(title, 1);
            head.Children.Add(title);
            if (!string.IsNullOrEmpty(g.Models))
            {
                var models = new TextBlock { Text = g.Models, FontSize = 11, Foreground = B("#636366"), Margin = new Thickness(6, 0, 0, 0),
                                             VerticalAlignment = VerticalAlignment.Bottom, TextTrimming = TextTrimming.CharacterEllipsis };
                Grid.SetColumn(models, 2);
                head.Children.Add(models);
            }
            panel.Children.Add(head);

            var cols = new Grid { Margin = new Thickness(0, 3, 0, 0) };
            cols.ColumnDefinitions.Add(new ColumnDefinition());
            cols.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
            cols.ColumnDefinitions.Add(new ColumnDefinition());
            var left = MiniBar("5 часов", g.Session, now, color, g.SessionOff ? "не действует — неделя исчерпана" : null);
            var right = MiniBar("Неделя", g.Week, now, color);
            Grid.SetColumn(right, 2);
            cols.Children.Add(left);
            cols.Children.Add(right);
            panel.Children.Add(cols);

            // упёрлись в лимит — группа стоит до сброса именно этого окна (недельный в это время не действует)
            Limit hit = new[] { g.Session, g.Week }.Where(l => Current(l, now) >= 99.5).OrderByDescending(l => l.ResetsAt ?? DateTime.MaxValue).FirstOrDefault();
            if (hit != null)
                panel.Children.Add(new TextBlock { FontSize = 11, Foreground = B("#FF6961"), Margin = new Thickness(0, 5, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis,
                    Text = hit.ResetsAt.HasValue ? "Лимит исчерпан · откроется " + ResetMoment(hit.ResetsAt.Value) : "Лимит исчерпан" });
            return panel;
        }

        static UIElement MiniBar(string label, Limit l, DateTime now, Color accent, string offText = null)
        {
            var panel = new StackPanel();
            double pct = Current(l, now);
            Color color = Severity(pct, accent);
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition());
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(new TextBlock { Text = label, FontSize = 11.5, Foreground = B("#AEAEB2"), VerticalAlignment = VerticalAlignment.Bottom });
            var value = new TextBlock { Text = l == null ? "—" : Math.Round(pct) + "%", FontSize = 14, FontWeight = FontWeights.SemiBold,
                                        Foreground = B(pct >= 75 ? color : C("#F5F5F7")) };
            Grid.SetColumn(value, 1);
            head.Children.Add(value);
            panel.Children.Add(head);
            panel.Children.Add(Bar(pct, color, 5));
            string text = l == null ? offText ?? "не действует"
                        : pct < 0.5 ? "не расходовался"
                        : l.ResetsAt.HasValue && l.ResetsAt.Value > now ? "сброс через " + Duration(l.ResetsAt.Value - now) : null;
            if (text != null)
                panel.Children.Add(new TextBlock { Text = text, FontSize = 10.5, Foreground = B("#8E8E93"), Margin = new Thickness(0, 3, 0, 0),
                                                   TextTrimming = TextTrimming.CharacterEllipsis,
                                                   ToolTip = l != null && l.ResetsAt.HasValue ? ResetMoment(l.ResetsAt.Value) : l == null ? offText : null });
            return panel;
        }

        static UIElement Bar(double pct, Color color, double height)
        {
            var track = new Grid { Height = height, Margin = new Thickness(0, 4, 0, 0) };
            track.Children.Add(new Border { CornerRadius = new CornerRadius(height / 2), Background = B("#26FFFFFF") });
            var bar = new Grid();
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(pct, GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100 - pct, GridUnitType.Star) });
            if (pct > 0) bar.Children.Add(new Border { CornerRadius = new CornerRadius(height / 2), Background = B(color), MinWidth = height });
            track.Children.Add(bar);
            return track;
        }

        UIElement Row(Limit l, DateTime now, string note, Color accent)
        {
            bool expired = l.ResetsAt.HasValue && l.ResetsAt.Value <= now;
            double pct = expired || note != null ? 0 : Math.Max(0, Math.Min(100, l.Percent));
            Color color = Severity(pct, accent);
            var panel = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };

            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition());
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(new TextBlock { Text = l.Title, FontSize = 12.5, Foreground = B("#D1D1D6"), VerticalAlignment = VerticalAlignment.Bottom });
            var value = new TextBlock { Text = Math.Round(pct) + "%", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = B(pct >= 75 ? color : C("#F5F5F7")) };
            Grid.SetColumn(value, 1);
            head.Children.Add(value);
            panel.Children.Add(head);

            panel.Children.Add(Bar(pct, color, 7));

            string text = note ?? (l.ResetsAt.HasValue && !expired
                ? "Сброс через " + Duration(l.ResetsAt.Value - now) + " · " + ResetMoment(l.ResetsAt.Value) : null);
            if (text != null)
                panel.Children.Add(new TextBlock { Text = text, FontSize = 11, Foreground = B("#8E8E93"), Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis });
            return panel;
        }

        // экран «не вошли»: как в Claude Usage Widget — пояснение и оранжевая кнопка
        UIElement LoginPanel()
        {
            var panel = new StackPanel { Margin = new Thickness(0, 14, 0, 4) };
            if (loginProc != null)
            {
                panel.Children.Add(new TextBlock { Text = "Подтвердите вход в браузере", FontSize = 14, FontWeight = FontWeights.SemiBold,
                                                   Foreground = B("#F5F5F7"), TextAlignment = TextAlignment.Center });
                panel.Children.Add(new TextBlock { Text = "Войдите (можно через Google) и нажмите «Authorize».\nЛимиты появятся здесь сами.", FontSize = 12,
                                                   Foreground = B("#AEAEB2"), TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 6, 0, 12) });
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition());
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
                row.ColumnDefinitions.Add(new ColumnDefinition());
                var cancel = PanelButton("Отмена", B("#3A3A3C"), CancelLogin);
                var again = PanelButton("Открыть снова", B(Accent), () => { if (loginUrl != null) OpenUrl(loginUrl); });
                again.Opacity = loginUrl != null ? 1 : 0.5;
                Grid.SetColumn(again, 2);
                row.Children.Add(cancel);
                row.Children.Add(again);
                panel.Children.Add(row);
                return panel;
            }
            panel.Children.Add(new TextBlock { Text = "Войдите в свой аккаунт Claude,\nчтобы видеть лимиты использования.", FontSize = 12.5,
                                               Foreground = B("#AEAEB2"), TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 0, 0, 12) });
            var button = new Border { CornerRadius = new CornerRadius(6), Background = B(Accent), Padding = new Thickness(16, 7, 16, 8), Cursor = System.Windows.Input.Cursors.Hand,
                                      Child = new TextBlock { Text = "Войти в Claude", FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center } };
            button.MouseEnter += (s, e) => button.Opacity = 0.9;
            button.MouseLeave += (s, e) => button.Opacity = 1;
            button.MouseLeftButtonUp += (s, e) => { e.Handled = true; Login(); };
            button.MouseLeftButtonDown += (s, e) => e.Handled = true;
            panel.Children.Add(button);
            panel.Children.Add(new TextBlock { Text = "Откроется браузер — можно войти через Google.", FontSize = 11, Foreground = B("#8E8E93"),
                                               TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 8, 0, 0) });
            return panel;
        }

        // ---------- подробности (по нажатию на виджет) ----------
        string Acc(string key)
        {
            object v = Get(account, key);
            string s = v == null ? null : Convert.ToString(v, Inv);
            return string.IsNullOrEmpty(s) ? null : s;
        }

        void BuildDetails(StackPanel panel, DateTime now)
        {
            panel.Children.Clear();
            // подробности свёрнуты по умолчанию — иначе окно выше половины экрана
            var toggle = new TextBlock { Text = settings.ShowDetails ? "Скрыть подробности ▴" : "Подробнее ▾", FontSize = 11.5, Foreground = B("#8E8E93"),
                                         HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0),
                                         Cursor = System.Windows.Input.Cursors.Hand, Background = Brushes.Transparent };
            toggle.MouseEnter += (s, e) => toggle.Foreground = B("#D1D1D6");
            toggle.MouseLeave += (s, e) => toggle.Foreground = B("#8E8E93");
            toggle.MouseLeftButtonDown += (s, e) => e.Handled = true;
            toggle.MouseLeftButtonUp += (s, e) =>
            {
                e.Handled = true;
                settings.ShowDetails = !settings.ShowDetails;
                SaveSettings();
                UpdateView();
            };
            panel.Children.Add(toggle);
            if (!settings.ShowDetails) return;

            // аккаунты: почта и тариф; одинаковая почта у всех — одной строкой сверху
            bool claudeOn = settings.ShowClaude && !loggedOut, agyOn = settings.ShowAgy && !agyMissing, codexOn = settings.ShowCodex && !codexMissing;
            var accounts = new List<Tuple<Color, string, string, string>>();   // цвет, сервис, почта, тариф
            if (claudeOn) accounts.Add(Tuple.Create(Accent, "Claude Code", Acc("emailAddress"), plan.Length > 0 ? "Claude " + plan : null));
            if (agyOn) accounts.Add(Tuple.Create(GeminiColor, "Antigravity", agyEmail, (string)null));
            if (codexOn) accounts.Add(Tuple.Create(CodexColor, "Codex", codexEmail, codexPlan.Length > 0 ? "ChatGPT " + codexPlan : null));
            foreach (var x in ShownExtras) accounts.Add(Tuple.Create(x.Color, x.Name, x.Email, x.Plan.Length > 0 ? x.Plan : null));
            var emails = accounts.Select(a => a.Item3).Where(e => !string.IsNullOrEmpty(e)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            bool oneEmail = emails.Count == 1;
            Section(panel, "Аккаунты");
            if (oneEmail) Pair(panel, "Email", emails[0]);
            foreach (var a in accounts)
            {
                string value = oneEmail ? a.Item4 ?? "подключён"
                             : string.Join(" · ", new[] { a.Item4, a.Item3 }.Where(x => !string.IsNullOrEmpty(x)));
                PairDot(panel, a.Item1, a.Item2, value.Length > 0 ? value : "подключён");
            }

            // на что ушла неделя: разбивку по продуктам присылает только Claude, у остальных — недельный расход целиком
            var week = new List<Tuple<Color, string, double>>();
            if (claudeOn)
                foreach (var b in breakdown.Where(b => b.Value >= 0.5)) week.Add(Tuple.Create(Accent, "Claude · " + b.Key, b.Value));
            if (agyOn)
                foreach (var g in agyGroups.Where(g => g.Week != null)) week.Add(Tuple.Create(GroupColor(g.Key), g.Title + " · лимит", Current(g.Week, now)));
            if (codexOn && CodexLong != null) week.Add(Tuple.Create(CodexColor, "Codex · " + CodexLong.Title.ToLower(Ru), Current(CodexLong, now)));
            foreach (var x in ShownExtras)
            {
                Limit l = x.Long ?? x.Short;
                if (l != null) week.Add(Tuple.Create(x.Color, x.Name + " · " + l.Title.ToLower(Ru), Current(l, now)));
            }
            if (week.Count > 0)
            {
                Section(panel, "На что ушла неделя");
                foreach (var w in week) PairDot(panel, w.Item1, w.Item2, Math.Round(w.Item3) + "%");
            }

            // одно общее время обновления для всех сервисов
            DateTime? last = null;
            var next = new List<DateTime>();
            if (claudeOn) { last = Max(last, updatedAt); if (!fetching) next.Add(nextFetch); }
            if (agyOn) { last = Max(last, agyUpdatedAt); if (!agyFetching) next.Add(agyNextFetch); }
            if (codexOn) { last = Max(last, codexUpdatedAt); if (!codexFetching) next.Add(codexNextFetch); }
            foreach (var x in ShownExtras) { last = Max(last, x.UpdatedAt); if (!x.Fetching) next.Add(x.NextFetch); }
            var soon = next.Where(t => t > now).DefaultIfEmpty(DateTime.MinValue).Min();
            Section(panel, "Данные");
            Pair(panel, "Обновлено", last.HasValue ? last.Value.ToString(last.Value.Date == now.Date ? "HH:mm:ss" : "d MMM HH:mm", Ru) : "ещё нет");
            Pair(panel, "Следующее", AnyFetching ? "обновляю…" : soon > now ? "через " + Duration(soon - now) : null);
        }

        // строка подробностей с цветной точкой сервиса перед названием
        static void PairDot(StackPanel panel, Color color, string label, string value)
        {
            var g = new Grid { Margin = new Thickness(0, 3, 0, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.Children.Add(Dot(color, 6, new Thickness(0, 1, 6, 0)));
            var name = new TextBlock { Text = label, FontSize = 12, Foreground = B("#AEAEB2") };
            Grid.SetColumn(name, 1);
            g.Children.Add(name);
            var v = new TextBlock { Text = value, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = B("#F5F5F7"),
                                    HorizontalAlignment = HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis,
                                    Margin = new Thickness(12, 0, 0, 0), ToolTip = value };
            Grid.SetColumn(v, 2);
            g.Children.Add(v);
            panel.Children.Add(g);
        }

        static void Section(StackPanel panel, string title)
        {
            panel.Children.Add(new Border { Height = 1, Background = B("#26FFFFFF"), Margin = new Thickness(0, 12, 0, 6) });
            panel.Children.Add(new TextBlock { Text = title.ToUpper(Ru), FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = B("#8E8E93"), Margin = new Thickness(0, 0, 0, 2) });
        }

        static void Pair(StackPanel panel, string label, string value)
        {
            if (string.IsNullOrEmpty(value)) return;
            var g = new Grid { Margin = new Thickness(0, 3, 0, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.Children.Add(new TextBlock { Text = label, FontSize = 12, Foreground = B("#AEAEB2") });
            var v = new TextBlock { Text = value, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = B("#F5F5F7"),
                                    HorizontalAlignment = HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis,
                                    Margin = new Thickness(12, 0, 0, 0), ToolTip = value };
            Grid.SetColumn(v, 1);
            g.Children.Add(v);
            panel.Children.Add(g);
        }

        // ---------- положение ----------
        // окно всплывает над панелью задач, как календарь у часов: справа внизу, над надписью
        void Dock()
        {
            if (window == null) return;
            IntPtr hwnd = new WindowInteropHelper(window).EnsureHandle();
            if (hwnd == IntPtr.Zero) return;
            IntPtr bar = FindWindow("Shell_TrayWnd", null);
            var work = bar != IntPtr.Zero ? WinForms.Screen.FromHandle(bar).WorkingArea : WinForms.Screen.PrimaryScreen.WorkingArea;
            RECT r;
            if (GetWindowRect(hwnd, out r))
            {
                var source = PresentationSource.FromVisual(window);
                double scale = source != null && source.CompositionTarget != null ? source.CompositionTarget.TransformToDevice.M11 : 1;
                // в SizeChanged настоящее окно ещё старого размера — берём новый размер из WPF, иначе окно уезжает под панель задач
                int widthPx = window.ActualWidth > 0 ? (int)Math.Round(window.ActualWidth * scale) : r.Right - r.Left;
                int heightPx = window.ActualHeight > 0 ? (int)Math.Round(window.ActualHeight * scale) : r.Bottom - r.Top;
                int margin = (int)(DockMargin * scale);
                int x = work.Right - widthPx - margin;
                int y = work.Bottom - heightPx - margin;
                SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
        }

        public void ShowWidget()
        {
            preview = false;
            activeSinceShow = false;
            UpdateView();
            new WindowInteropHelper(window).EnsureHandle();
            Dock();
            window.Show();
            window.UpdateLayout();   // размер окна известен сразу — ставим его точно в правый нижний угол
            Dock();
            window.Activate();
            HookMouse(true);
            UpdateView();
        }

        // для проверки вида: «AiLimitWidget.exe --snapshot файл.png» — открыть окно, дождаться данных, сохранить картинку и выйти
        public void Snapshot(string file, string askLogout)
        {
            if (askLogout != null) { logoutTarget = askLogout; confirmLogout = true; }   // только вопрос «Выйти из …?», выход не выполняется
            settings.KeepOpen = true;
            settings.ShowDetails = true;   // на снимке — со всеми подробностями (в настройки не сохраняется)
            ShowWidget();
            var wait = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            int ticks = 0;
            wait.Tick += (s, e) =>
            {
                if (++ticks < 25 && (AnyFetching || ticks < 3)) return;
                wait.Stop();
                UpdateView();
                window.UpdateLayout();
                var surface = Find<Border>("Surface");
                var bg = surface.Background;
                surface.Background = B("#F21C1C1E");
                surface.UpdateLayout();
                var rtb = new RenderTargetBitmap((int)(surface.ActualWidth * 2), (int)(surface.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32);
                rtb.Render(surface);
                surface.Background = bg;
                var png = new PngBitmapEncoder();
                png.Frames.Add(BitmapFrame.Create(rtb));
                using (var fs = File.Create(file)) png.Save(fs);
                // надпись у часов — на фоне тёмной панели задач
                var box = clock.Content as Border;
                if (box != null)
                {
                    box.Background = B("#FF1F1F1F");
                    box.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));   // панель задач может быть скрыта — меряем сами
                    box.Arrange(new Rect(box.DesiredSize));
                    box.UpdateLayout();
                    var crt = new RenderTargetBitmap((int)(box.ActualWidth * 2), (int)(box.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32);
                    crt.Render(box);
                    var cpng = new PngBitmapEncoder();
                    cpng.Frames.Add(BitmapFrame.Create(crt));
                    using (var fs = File.Create(Path.ChangeExtension(file, null) + "-clock.png")) cpng.Save(fs);
                }
                Exit();
            };
            wait.Start();
        }

        void HideWidget()
        {
            preview = false;
            confirmLogout = false;
            HookMouse(false);
            window.Hide();
            hiddenAt = DateTime.Now;
        }

        // Пока окно открыто, следим за нажатиями мыши по всему экрану: нажали мимо окна — сразу прячем.
        // Не зависит от того, успела ли Windows сделать окно активным.
        delegate IntPtr LowLevelMouseProc(int code, IntPtr message, IntPtr data);
        [StructLayout(LayoutKind.Sequential)] struct MouseHookData { public int X, Y; public uint MouseData, Flags, Time; public IntPtr Extra; }
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int hook, LowLevelMouseProc proc, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        const int WH_MOUSE_LL = 14, WM_LBUTTONDOWN = 0x201, WM_RBUTTONDOWN = 0x204, WM_MBUTTONDOWN = 0x207;

        LowLevelMouseProc mouseProc;   // ссылка держит делегат живым, пока установлен хук
        IntPtr mouseHook;

        void HookMouse(bool on)
        {
            if (on && mouseHook == IntPtr.Zero)
            {
                mouseProc = MouseHook;
                mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, GetModuleHandle(null), 0);
            }
            else if (!on && mouseHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(mouseHook);
                mouseHook = IntPtr.Zero;
            }
        }

        IntPtr MouseHook(int code, IntPtr message, IntPtr data)
        {
            int msg = message.ToInt32();
            if (code >= 0 && (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN))
            {
                var p = (MouseHookData)Marshal.PtrToStructure(data, typeof(MouseHookData));
                RECT r;
                IntPtr hwnd = new WindowInteropHelper(window).Handle;
                if (GetWindowRect(hwnd, out r) && (p.X < r.Left || p.X >= r.Right || p.Y < r.Top || p.Y >= r.Bottom))
                    dispatcher.BeginInvoke(new Action(() =>
                    {
                        // меню ⋯ открыто — нажатие по нему не считается нажатием мимо окна
                        if (window.IsVisible && !settings.KeepOpen && !(menu != null && menu.IsOpen)) HideWidget();
                    }));
            }
            return CallNextHookEx(mouseHook, code, message, data);
        }

        void ToggleWindow()
        {
            if (window.IsVisible) HideWidget();
            // нажатие на значок в трее сначала уводит фокус (окно прячется), затем приходит само нажатие —
            // не открываем окно заново сразу после такого скрытия
            else if ((DateTime.Now - hiddenAt).TotalMilliseconds > 400) ShowWidget();
        }

        // ---------- трей ----------
        string lastTrayKey;

        void UpdateTray(double pct, bool active)
        {
            if (tray == null) return;
            DateTime now = DateTime.Now;
            AgyGroup ag = settings.ShowAgy ? ClockGroup() : null;
            double agyPct = ag == null ? 0 : Current(ag.Short, now);
            var tip = new List<string>();
            if (settings.ShowClaude && session != null) tip.Add("Claude " + Math.Round(pct) + "%" + (weekly.Count > 0 ? " (нед. " + Math.Round(Current(weekly[0], now)) + "%)" : ""));
            if (settings.ShowAgy)
                foreach (var gr in agyGroups)
                    tip.Add((gr.Key == "3p" ? "Claude/GPT" : gr.Title) + " " + Math.Round(Current(gr.Short, now)) + "%");
            if (settings.ShowCodex && codexLimits.Count > 0) tip.Add("Codex " + Math.Round(Current(codexLimits[0], now)) + "%");
            foreach (var x in ShownExtras) if (x.Short != null) tip.Add(x.Name + " " + Math.Round(Current(x.Short, now)) + "%");
            string text63 = tip.Count == 0 ? "Лимиты ИИ" : string.Join(" · ", tip);
            tray.Text = text63.Length > 63 ? text63.Substring(0, 63) : text63;

            // главное число — сессия Claude; если Claude скрыт — сессия Antigravity
            bool claudeMain = settings.ShowClaude;
            bool known = claudeMain ? session != null : ag != null && ag.Short != null;
            double main = claudeMain ? pct : agyPct;
            bool stripe = claudeMain && ag != null && ag.Short != null;   // полоска снизу цвета группы — сессия Antigravity
            Color agyColor = ag == null ? GeminiColor : GroupColor(ag.Key);
            string key = (known ? Math.Round(main).ToString(Inv) : "-") + "|" + claudeMain + "|" + (stripe ? Math.Round(agyPct).ToString(Inv) + ag.Key : "");
            if (key == lastTrayKey) return;
            lastTrayKey = key;
            using (var bmp = new Gdi.Bitmap(32, 32))
            {
                using (var g = Gdi.Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = Gdi.Drawing2D.SmoothingMode.AntiAlias;
                    g.TextRenderingHint = Gdi.Text.TextRenderingHint.AntiAliasGridFit;
                    Color c = !known ? C("#636366") : Severity(main, claudeMain ? Accent : agyColor);
                    using (var brush = new Gdi.SolidBrush(Gdi.Color.FromArgb(c.R, c.G, c.B)))
                    using (var path = RoundRect(0, 0, 32, 32, 8))
                        g.FillPath(brush, path);
                    string text = !known ? "…" : main >= 99.5 ? "!!" : Math.Round(main).ToString(Inv);
                    float size = text.Length >= 2 ? 15f : 19f;
                    using (var font = new Gdi.Font("Segoe UI", size, Gdi.FontStyle.Bold, Gdi.GraphicsUnit.Pixel))
                    using (var fmt = new Gdi.StringFormat { Alignment = Gdi.StringAlignment.Center, LineAlignment = Gdi.StringAlignment.Center })
                        g.DrawString(text, font, Gdi.Brushes.White, new Gdi.RectangleF(0, stripe ? -2 : 1, 32, 32), fmt);
                    if (stripe)
                    {
                        Color s = Severity(agyPct, agyColor);
                        using (var track = new Gdi.SolidBrush(Gdi.Color.FromArgb(170, 20, 20, 22)))
                        using (var trackPath = RoundRect(4, 25, 24, 5, 2.5f))
                            g.FillPath(track, trackPath);
                        float w = (float)Math.Max(5, 24 * agyPct / 100);
                        if (agyPct >= 0.5)
                        using (var fill = new Gdi.SolidBrush(Gdi.Color.FromArgb(s.R, s.G, s.B)))
                        using (var fillPath = RoundRect(4, 25, w, 5, 2.5f))
                            g.FillPath(fill, fillPath);
                    }
                }
                IntPtr handle = bmp.GetHicon();
                tray.Icon = Gdi.Icon.FromHandle(handle);
                if (trayIconHandle != IntPtr.Zero) DestroyIcon(trayIconHandle);
                trayIconHandle = handle;
            }
        }

        static Gdi.Drawing2D.GraphicsPath RoundRect(float x, float y, float w, float h, float r)
        {
            var p = new Gdi.Drawing2D.GraphicsPath();
            p.AddArc(x, y, 2 * r, 2 * r, 180, 90);
            p.AddArc(x + w - 2 * r, y, 2 * r, 2 * r, 270, 90);
            p.AddArc(x + w - 2 * r, y + h - 2 * r, 2 * r, 2 * r, 0, 90);
            p.AddArc(x, y + h - 2 * r, 2 * r, 2 * r, 90, 90);
            p.CloseFigure();
            return p;
        }

        // ---------- меню ----------
        // Тёмное меню в стиле Windows 11 (как в Claude Usage Widget): скруглённые углы, тень, галочки, подменю.
        const string MenuXaml = @"
<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
                    xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <SolidColorBrush x:Key='MenuBg' Color='#2C2C2C'/>
  <SolidColorBrush x:Key='MenuLine' Color='#454545'/>
  <Style x:Key='DarkMenu' TargetType='ContextMenu'>
    <Setter Property='OverridesDefaultStyle' Value='True'/>
    <Setter Property='HasDropShadow' Value='False'/>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ContextMenu'>
          <Border Margin='10' Background='{StaticResource MenuBg}' BorderBrush='{StaticResource MenuLine}' BorderThickness='1' CornerRadius='8' Padding='4'>
            <Border.Effect><DropShadowEffect BlurRadius='14' ShadowDepth='3' Direction='270' Opacity='0.5'/></Border.Effect>
            <StackPanel IsItemsHost='True' KeyboardNavigation.DirectionalNavigation='Cycle'/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key='{x:Static MenuItem.SeparatorStyleKey}' TargetType='Separator'>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Separator'><Border Height='1' Background='{StaticResource MenuLine}' Margin='-4,4'/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType='MenuItem'>
    <Setter Property='OverridesDefaultStyle' Value='True'/>
    <Setter Property='Foreground' Value='#F3F3F3'/>
    <Setter Property='FontFamily' Value='Segoe UI Variable Text, Segoe UI'/>
    <Setter Property='FontSize' Value='13'/>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='MenuItem'>
          <Border x:Name='Bd' Background='Transparent' CornerRadius='4' MinHeight='32' MinWidth='230' Padding='0,0,12,0'>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width='34'/><ColumnDefinition/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
              <TextBlock x:Name='Check' Text='&#xE73E;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='12'
                         HorizontalAlignment='Center' VerticalAlignment='Center' Visibility='Hidden'/>
              <ContentPresenter Grid.Column='1' ContentSource='Header' VerticalAlignment='Center' RecognizesAccessKey='False'/>
              <TextBlock x:Name='Arrow' Grid.Column='2' Text='&#xE76C;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='10'
                         VerticalAlignment='Center' Margin='16,0,0,0' Visibility='Collapsed'/>
              <Popup x:Name='PART_Popup' Placement='Right' HorizontalOffset='-6' VerticalOffset='-15' AllowsTransparency='True' Focusable='False'
                     PopupAnimation='None' IsOpen='{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}'>
                <Border Margin='10' Background='{StaticResource MenuBg}' BorderBrush='{StaticResource MenuLine}' BorderThickness='1' CornerRadius='8' Padding='4'>
                  <Border.Effect><DropShadowEffect BlurRadius='14' ShadowDepth='3' Direction='270' Opacity='0.5'/></Border.Effect>
                  <StackPanel IsItemsHost='True'/>
                </Border>
              </Popup>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property='IsChecked' Value='True'><Setter TargetName='Check' Property='Visibility' Value='Visible'/></Trigger>
            <Trigger Property='HasItems' Value='True'><Setter TargetName='Arrow' Property='Visibility' Value='Visible'/></Trigger>
            <Trigger Property='IsHighlighted' Value='True'><Setter TargetName='Bd' Property='Background' Value='#3B3B3B'/></Trigger>
            <Trigger Property='IsEnabled' Value='False'><Setter Property='Foreground' Value='#9A9A9A'/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>";

        static ResourceDictionary menuStyles;
        static ResourceDictionary MenuStyles { get { return menuStyles ?? (menuStyles = (ResourceDictionary)XamlReader.Parse(MenuXaml)); } }

        MenuItem Item(string text, bool check, Action click)
        {
            var item = new MenuItem { Header = text, IsChecked = check };
            item.Click += (s, e) => dispatcher.BeginInvoke(click);
            return item;
        }

        // переключатель: меню остаётся открытым, галочка меняется сразу — видно, что настройка сработала
        MenuItem Toggle(string text, bool check, Action click)
        {
            var item = new MenuItem { Header = text, IsChecked = check, StaysOpenOnClick = true };
            item.Click += (s, e) => { item.IsChecked = !item.IsChecked; click(); };
            return item;
        }

        // выбор одного из вариантов (интервал, прозрачность): галочка переезжает сразу
        MenuItem Choice(string text, bool check, Action click)
        {
            var item = new MenuItem { Header = text, IsChecked = check, StaysOpenOnClick = true };
            item.Click += (s, e) =>
            {
                var parent = item.Parent as MenuItem;
                if (parent != null) foreach (var other in parent.Items.OfType<MenuItem>()) other.IsChecked = other == item;
                click();
            };
            return item;
        }

        // сервис в окне: выключить последний нельзя — галочка просто не снимется
        MenuItem ServiceToggle(string text, bool check, Action<bool> set, Action fetch)
        {
            var item = new MenuItem { Header = text, IsChecked = check, StaysOpenOnClick = true };
            item.Click += (s, e) =>
            {
                bool on = !item.IsChecked;
                if (!on && ShownServices <= 1) return;
                item.IsChecked = on;
                set(on);
                SaveSettings();
                lastTrayKey = null;
                if (on) fetch();
                UpdateView();
            };
            return item;
        }

        // столбец у часов: последний не снимается
        MenuItem ClockToggle(string key, string text)
        {
            var item = new MenuItem { Header = text, IsChecked = ClockShows(key), StaysOpenOnClick = true };
            item.Click += (s, e) =>
            {
                var items = settings.ClockItems.Split(',').Where(x => x.Length > 0).ToList();
                if (items.Contains(key)) { if (items.Count <= 1) return; items.Remove(key); }
                else items.Add(key);
                settings.ClockItems = string.Join(",", ClockColumns.Select(c => c[0]).Where(items.Contains));
                item.IsChecked = ClockShows(key);
                SaveSettings();
                lastTrayKey = null;
                UpdateView();
            };
            return item;
        }

        MenuItem Sub(string text, params MenuItem[] items)
        {
            var sub = new MenuItem { Header = text };
            foreach (var i in items) sub.Items.Add(i);
            return sub;
        }

        // target — кнопка ⋯ (меню под ней) или null (меню у курсора: трей, правый клик)
        void ShowMenu(FrameworkElement target, bool fromTray = false)
        {
            BuildMenu();
            menu.PlacementTarget = target;
            menu.Placement = target != null ? System.Windows.Controls.Primitives.PlacementMode.Bottom
                                            : System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            menu.HorizontalOffset = target != null ? -200 : 0;
            menu.IsOpen = true;
            // из трея приложение не на переднем плане — без этого меню не закрывается кликом мимо;
            // из открытого окна так делать нельзя: окно теряет фокус, и WPF сразу закрывает меню
            var source = PresentationSource.FromVisual(menu) as HwndSource;
            if (fromTray && source != null) SetForegroundWindow(source.Handle);
        }

        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);

        bool LoggedIn { get { return !loggedOut; } }

        void BuildMenu()
        {
            menu.Items.Clear();
            string email = Acc("emailAddress");
            if (LoggedIn && email != null)
            {
                menu.Items.Add(new MenuItem { Header = email + (plan.Length > 0 ? "  ·  " + plan : ""), IsEnabled = false });
                menu.Items.Add(new Separator());
            }
            menu.Items.Add(Item("Обновить", false, FetchAll));
            menu.Items.Add(new Separator());
            menu.Items.Add(Sub("Показывать",
                new[] {
                    ServiceToggle("Claude Code", settings.ShowClaude, v => { settings.ShowClaude = v; SetLoggedOut("claude", false); }, Fetch),
                    ServiceToggle("Antigravity", settings.ShowAgy, v => { settings.ShowAgy = v; SetLoggedOut("agy", false); }, FetchAgy),
                    ServiceToggle("Codex", settings.ShowCodex, v => { settings.ShowCodex = v; SetLoggedOut("codex", false); }, FetchCodex) }
                .Concat(extras.Where(x => x.SignedIn).Select(x => ServiceToggle(x.Name, ExtraOn(x.Key), v =>
                {
                    var list = settings.HiddenExtras.Split(',').Where(k => k.Length > 0 && k != x.Key).ToList();
                    if (!v) list.Add(x.Key);
                    settings.HiddenExtras = string.Join(",", list);
                }, () => FetchExtra(x)))).ToArray()));
            // столбцы других ИИ — только тех, в которые вошли
            menu.Items.Add(Sub("У часов", ClockColumns.Where(c => { var x = ExtraFor(c[0]); return x == null || x.SignedIn; })
                                                      .Select(c => ClockToggle(c[0], c[1])).ToArray()));
            menu.Items.Add(Toggle("Не скрывать при нажатии мимо", settings.KeepOpen, () => { settings.KeepOpen = !settings.KeepOpen; SaveSettings(); }));
            menu.Items.Add(Toggle("Показывать у часов", settings.ClockLabel, () =>
            {
                settings.ClockLabel = !settings.ClockLabel;
                SaveSettings();
                UpdateView();
            }));
            menu.Items.Add(Toggle("Уведомлять при 80% и 95%", settings.Notify, () => { settings.Notify = !settings.Notify; SaveSettings(); }));
            menu.Items.Add(Toggle("Запускать вместе с Windows", Autostart, () => SetAutostart(!Autostart)));

            menu.Items.Add(Sub("Интервал обновления", RefreshOptions.Select(m => Choice(m + " мин", settings.RefreshMinutes == m, () =>
            {
                settings.RefreshMinutes = m;
                nextFetch = (updatedAt ?? DateTime.Now).AddMinutes(m);
                SaveSettings();
            })).ToArray()));
            string[] levels = { "Низкая", "Средняя", "Высокая", "Максимальная" };
            menu.Items.Add(Sub("Прозрачность", Enumerable.Range(0, levels.Length).Select(level => Choice(levels[level], settings.Transparency == level, () =>
            {
                settings.Transparency = level;
                SaveSettings();
                ApplyTint();
                Glass.SetBlur(window, level < 3);
            })).ToArray()));

            menu.Items.Add(new Separator());
            // выход — только из тех сервисов, где вход есть; какой именно, выбирают в подменю
            var outs = new List<MenuItem>();
            if (settings.ShowClaude && LoggedIn) outs.Add(Item("Claude Code", false, () => Logout("claude")));
            if (settings.ShowAgy && !agyMissing && agyGroups.Count > 0) outs.Add(Item("Antigravity", false, () => Logout("agy")));
            if (settings.ShowCodex && !codexMissing) outs.Add(Item("Codex", false, () => Logout("codex")));
            if (outs.Count > 0) menu.Items.Add(Sub("Выйти из аккаунта", outs.ToArray()));
            if (settings.ShowClaude && !LoggedIn) menu.Items.Add(Item("Войти в Claude…", false, Login));
            menu.Items.Add(Item("Закрыть", false, Exit));
        }

        // ---------- вход и выход ----------
        // Вход у виджета общий с Claude Code, поэтому входим и выходим его же командами:
        // «claude auth login» открывает браузер по умолчанию (Chrome — там уже есть вход через Google),
        // «claude auth logout» удаляет ключи входа.
        static string ClaudeExe
        {
            get
            {
                string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "claude.exe");
                return File.Exists(local) ? local : "claude";
            }
        }

        System.Diagnostics.Process loginProc;
        string loginUrl;

        // «claude auth login» без окна консоли: он сам открывает браузер (Chrome — вход через Google),
        // а ссылку на случай, если браузер не открылся, забираем из его вывода
        void Login()
        {
            if (loginProc != null)
            {
                if (loginUrl != null) OpenUrl(loginUrl);   // вход уже идёт — просто открыть страницу снова
                return;
            }
            loginUrl = null;
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo(ClaudeExe, "auth login --claudeai") {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
                var proc = new System.Diagnostics.Process { StartInfo = psi, EnableRaisingEvents = true };
                System.Diagnostics.DataReceivedEventHandler grab = (s, e) =>
                {
                    var m = System.Text.RegularExpressions.Regex.Match(e.Data ?? "", @"https://\S+");
                    if (m.Success && loginUrl == null) dispatcher.BeginInvoke(new Action(() => { loginUrl = m.Value; UpdateView(); }));
                };
                proc.OutputDataReceived += grab;
                proc.ErrorDataReceived += grab;
                proc.Exited += (s, e) => dispatcher.BeginInvoke(new Action(() =>
                {
                    loginProc = null;
                    loginUrl = null;
                    Fetch();
                }));
                proc.Start();
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
                loginProc = proc;
            }
            catch (Exception) { SetStatus("Claude Code не найден — установите его и выполните claude", true); }
            if (!window.IsVisible) ShowWidget();
            UpdateView();
        }

        void CancelLogin()
        {
            try { if (loginProc != null && !loginProc.HasExited) loginProc.Kill(); } catch (Exception) { }
            loginProc = null;
            loginUrl = null;
            UpdateView();
        }

        static void OpenUrl(string url)
        {
            try { System.Diagnostics.Process.Start(url); } catch (Exception) { }
        }

        bool confirmLogout, loggingOut;
        string logoutTarget = "claude";   // из какого сервиса выходим: claude, agy или codex

        static string ServiceName(string target)
        {
            return target == "agy" ? "Antigravity" : target == "codex" ? "Codex" : "Claude Code";
        }

        static string CodexExe
        {
            get
            {
                string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                string exe = string.IsNullOrEmpty(local) ? null : Path.Combine(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe");
                return exe != null && File.Exists(exe) ? exe : "codex";
            }
        }

        int ShownServices { get { return (settings.ShowClaude ? 1 : 0) + (settings.ShowAgy ? 1 : 0) + (settings.ShowCodex ? 1 : 0) + ShownExtras.Count; } }

        // подтверждение показываем в самом окне (отдельное окно-вопрос пряталось за другими окнами);
        // из какого сервиса выходить, выбирают в меню «Выйти из аккаунта»
        void Logout(string target)
        {
            logoutTarget = target;
            confirmLogout = true;
            if (!window.IsVisible) ShowWidget();
            UpdateView();
        }

        void DoLogout()
        {
            string target = logoutTarget;
            confirmLogout = false;
            loggingOut = true;
            UpdateView();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    if (target == "agy")
                        // у Antigravity выход есть только внутри его окна: открываем agy и сразу выполняем /logout
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AgyExe, "-i /logout") {
                            UseShellExecute = true, WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) });
                    else
                    {
                        Background.Run(target == "codex" ? CodexExe : ClaudeExe, target == "codex" ? "logout" : "auth logout", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), 30000);
                    }
                }
                catch (Exception) { }
                dispatcher.BeginInvoke(new Action(() =>
                {
                    loggingOut = false;
                    AfterLogout(target);
                }));
            });
        }

        // после выхода сведения о сервисе больше не показываем: раздел, столбец у часов и подробности прячутся
        // (если это был единственный сервис в окне — раздел остаётся, в нём предложение войти)
        void AfterLogout(string target)
        {
            bool hide = ShownServices > 1;
            if (target == "claude")
            {
                ClearData();
                if (hide) { settings.ShowClaude = false; SetLoggedOut("claude", true); }
            }
            else if (target == "agy")
            {
                agyGroups.Clear();
                agyEmail = null;
                agyCredits = null;
                agyUpdatedAt = null;
                try { File.Delete(agyCachePath); } catch (Exception) { }
                if (hide) { settings.ShowAgy = false; SetLoggedOut("agy", true); }
                else SetAgyStatus("Нет входа в Antigravity — запустите agy и войдите", false);
                // окно agy с /logout ещё открыто — первую пробу делаем не сразу, а через обычный интервал
                agyNextFetch = DateTime.Now.AddMinutes(settings.RefreshMinutes);
            }
            else
            {
                codexLimits.Clear();
                codexEmail = null;
                codexPlan = "";
                codexUpdatedAt = null;
                try { File.Delete(codexCachePath); } catch (Exception) { }
                if (hide) { settings.ShowCodex = false; SetLoggedOut("codex", true); }
            }
            SaveSettings();
            lastTrayKey = null;
            Fetch();
            FetchAgy();
            FetchCodex();
            UpdateView();
        }

        // ---------- возврат после нового входа ----------
        bool IsLoggedOut(string key) { return settings.LoggedOut.Split(',').Contains(key); }

        void SetLoggedOut(string key, bool on)
        {
            var list = settings.LoggedOut.Split(',').Where(x => x.Length > 0 && x != key).ToList();
            if (on) list.Add(key);
            settings.LoggedOut = string.Join(",", list);
        }

        static bool CodexSignedIn()
        {
            try
            {
                if (!File.Exists(CodexAuthPath)) return false;
                var d = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(CodexAuthPath, Encoding.UTF8)) as Dictionary<string, object>;
                return !string.IsNullOrEmpty(Convert.ToString(Get(Get(d, "tokens") as Dictionary<string, object>, "access_token"), Inv));
            }
            catch (Exception) { return false; }
        }

        DateTime nextReturnCheck = DateTime.MinValue;

        // сервисы, скрытые из-за выхода, тихо проверяем: вошли снова (codex login, claude, agy) — раздел возвращается сам.
        // Codex и Claude — по файлу входа раз в 5 с; Antigravity — пробным /quota с обычным интервалом обновления.
        // now — проверить сразу (кнопка «Обновить»)
        void CheckReturn(bool now)
        {
            if (settings.LoggedOut.Length == 0) return;
            if (!now && DateTime.Now < nextReturnCheck) return;
            nextReturnCheck = DateTime.Now.AddSeconds(5);
            string token;
            if (IsLoggedOut("codex") && CodexSignedIn()) Return("codex");
            if (IsLoggedOut("claude")) { ReadToken(out token); if (!string.IsNullOrEmpty(token)) Return("claude"); }
            if (IsLoggedOut("agy") && !agyFetching && (now || DateTime.Now >= agyNextFetch)) FetchAgy(true);
        }

        void Return(string key)
        {
            SetLoggedOut(key, false);
            if (key == "claude") { settings.ShowClaude = true; loggedOut = false; }
            else if (key == "agy") settings.ShowAgy = true;
            else settings.ShowCodex = true;
            SaveSettings();
            lastTrayKey = null;
            if (key == "claude") Fetch();
            else if (key == "codex") FetchCodex();
            if (tray != null && settings.Notify) tray.ShowBalloonTip(4000, ServiceName(key), "Вход найден — лимиты снова в виджете.", WinForms.ToolTipIcon.Info);
            UpdateView();
        }

        UIElement LogoutPanel()
        {
            string name = ServiceName(logoutTarget);
            var panel = new StackPanel { Margin = new Thickness(0, 14, 0, 4) };
            panel.Children.Add(new TextBlock { Text = loggingOut ? "Выходим из " + name + "…" : "Выйти из " + name + "?", FontSize = 14, FontWeight = FontWeights.SemiBold,
                                               Foreground = B("#F5F5F7"), TextAlignment = TextAlignment.Center });
            if (loggingOut) return panel;
            string what = logoutTarget == "agy" ? "Откроется окно Antigravity и выполнит /logout —\nпосле выхода закройте его."
                        : logoutTarget == "codex" ? "Вход общий с Codex — в нём тоже\nнужно будет войти заново (codex login)."
                        : "Вход общий с Claude Code — в нём тоже\nнужно будет войти заново.";
            if (ShownServices > 1) what += "\n\nРаздел пропадёт из виджета.\nВернуть: ⋯ → Показывать.";
            panel.Children.Add(new TextBlock { Text = what, FontSize = 12, Foreground = B("#AEAEB2"),
                                               TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 6, 0, 12) });
            var buttons = new Grid();
            buttons.ColumnDefinitions.Add(new ColumnDefinition());
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
            buttons.ColumnDefinitions.Add(new ColumnDefinition());
            var cancel = PanelButton("Отмена", B("#3A3A3C"), () => { confirmLogout = false; UpdateView(); });
            var ok = PanelButton("Выйти", B(Danger), DoLogout);
            Grid.SetColumn(ok, 2);
            buttons.Children.Add(cancel);
            buttons.Children.Add(ok);
            panel.Children.Add(buttons);
            return panel;
        }

        Border PanelButton(string text, Brush background, Action click)
        {
            var button = new Border { CornerRadius = new CornerRadius(6), Background = background, Padding = new Thickness(12, 7, 12, 8), Cursor = System.Windows.Input.Cursors.Hand,
                                      Child = new TextBlock { Text = text, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center } };
            button.MouseEnter += (s, e) => button.Opacity = 0.88;
            button.MouseLeave += (s, e) => button.Opacity = 1;
            button.MouseLeftButtonDown += (s, e) => e.Handled = true;
            button.MouseLeftButtonUp += (s, e) => { e.Handled = true; click(); };
            return button;
        }

        void ClearData()
        {
            session = null;
            weekly.Clear();
            breakdown.Clear();
            account = null;
            updatedAt = null;
            plan = "";
            try { File.Delete(cachePath); } catch (Exception) { }
            lastTrayKey = null;
        }

        static bool Autostart
        {
            get
            {
                try { using (var key = Registry.CurrentUser.OpenSubKey(RunKey)) return key != null && key.GetValue(RunName) != null; }
                catch (Exception) { return false; }
            }
        }

        static void SetAutostart(bool enable)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (enable) key.SetValue(RunName, "\"" + System.Reflection.Assembly.GetExecutingAssembly().Location + "\"");
                    else key.DeleteValue(RunName, false);
                }
            }
            catch (Exception) { }
        }

        void Exit()
        {
            timer.Stop();
            tray.Visible = false;
            tray.Dispose();
            if (trayIconHandle != IntPtr.Zero) DestroyIcon(trayIconHandle);
            Application.Current.Shutdown();
        }
    }

    static class Program
    {
        const string ShowEventName = @"Local\AiLimitWidget.Show";

        [STAThread]
        static void Main(string[] args)
        {
            try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; }
            catch (NotSupportedException) { }

            if (args.Length >= 2 && args[0] == "--snapshot")
            {
                var snapApp = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                var snap = new Widget(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AiLimitWidget"));
                snap.Init();
                snap.Snapshot(Path.GetFullPath(args[1]), args.Length >= 3 ? args[2] : null);
                snapApp.Run();
                return;
            }

            bool created;
            using (var mutex = new Mutex(true, @"Local\AiLimitWidget", out created))
            {
                if (!created)
                {
                    try { using (var show = EventWaitHandle.OpenExisting(ShowEventName)) show.Set(); }
                    catch (Exception) { }
                    return;
                }
                string appDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AiLimitWidget");
                var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                app.DispatcherUnhandledException += (s, e) => { e.Handled = true; };
                var widget = new Widget(appDir);
                widget.Init();
                var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
                ThreadPool.RegisterWaitForSingleObject(showEvent,
                    (state, timedOut) => app.Dispatcher.BeginInvoke(new Action(widget.ShowWidget)), null, -1, false);
                app.Run();
            }
        }
    }

    // ---------- запуск CLI в фоне ----------
    // agy, claude, gh при запуске сами проверяют обновления и ставят их — установщик открывает своё окно консоли
    // (CreateNoWindow прячет только консоль самой программы, не её потомков). Поэтому запускаем их на отдельном
    // невидимом рабочем столе: всё, что они или их потомки откроют, окажется там — обновление пройдёт в фоне.
    static class Background
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb; public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, int flags,
            IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern int WaitForSingleObject(IntPtr h, int ms);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, int code);
        [DllImport("kernel32.dll")] static extern bool SetHandleInformation(IntPtr h, int mask, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name, uint access, int share, IntPtr sa, int disposition, int flags, IntPtr template);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devmode, int flags, uint access, IntPtr sa);

        const string DesktopName = "AiLimitWidgetBackground";
        static IntPtr desktop;   // держим открытым, пока жив виджет, иначе Windows удалит стол
        static readonly object gate = new object();

        static string Desktop()
        {
            lock (gate)
            {
                if (desktop == IntPtr.Zero) desktop = CreateDesktop(DesktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /* GENERIC_ALL */, IntPtr.Zero);
                return desktop == IntPtr.Zero ? null : DesktopName;   // не вышло — запустим на обычном столе, но всё равно без окна
            }
        }

        static string Quote(string s) { return s.IndexOf(' ') >= 0 && !s.StartsWith("\"") ? "\"" + s + "\"" : s; }

        // запустить и дождаться; вывод — stdout программы (null — не ответила за timeoutMs);
        // env — добавить переменные окружения; Win32Exception — программа не найдена
        public static string Run(string exe, string args, string dir, int timeoutMs, IDictionary<string, string> env = null)
        {
            IntPtr block = IntPtr.Zero;
            int flags = 0x08000000;   // CREATE_NO_WINDOW
            if (env != null)
            {
                var all = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) all[(string)e.Key] = (string)e.Value;
                foreach (var e in env) all[e.Key] = e.Value;
                var sb = new StringBuilder();
                foreach (var e in all) sb.Append(e.Key).Append('=').Append(e.Value).Append('\0');
                block = Marshal.StringToHGlobalUni(sb.Append('\0').ToString());
                flags |= 0x400;   // CREATE_UNICODE_ENVIRONMENT
            }
            try { return Run(exe, args, dir, timeoutMs, block, flags); }
            finally { if (block != IntPtr.Zero) Marshal.FreeHGlobal(block); }
        }

        static string Run(string exe, string args, string dir, int timeoutMs, IntPtr env, int flags)
        {
            // stdin и stderr — в NUL (как у скрытой консоли), stdout — в канал, откуда читаем ответ
            using (var nul = CreateFile("NUL", 0xC0000000 /* GENERIC_READ | GENERIC_WRITE */, 3, IntPtr.Zero, 3 /* OPEN_EXISTING */, 0, IntPtr.Zero))
            using (var pipe = new System.IO.Pipes.AnonymousPipeServerStream(System.IO.Pipes.PipeDirection.In, HandleInheritability.Inheritable))
            {
                IntPtr nulHandle = nul.DangerousGetHandle();
                SetHandleInformation(nulHandle, 1, 1);   // HANDLE_FLAG_INHERIT
                string desktop = Desktop();
                if (desktop == null) return null;
                var si = new STARTUPINFO {
                    lpDesktop = desktop, dwFlags = 0x101 /* STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES */, wShowWindow = 0 /* SW_HIDE */,
                    hStdInput = nulHandle, hStdOutput = pipe.ClientSafePipeHandle.DangerousGetHandle(), hStdError = nulHandle };
                si.cb = Marshal.SizeOf(si);
                PROCESS_INFORMATION pi;
                var cmd = new StringBuilder(Quote(exe) + " " + args);
                if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, true, flags, env, dir, ref si, out pi))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                CloseHandle(pi.hThread);
                pipe.DisposeLocalCopyOfClientHandle();
                try
                {
                    var read = new StreamReader(pipe, Encoding.UTF8).ReadToEndAsync();
                    if (WaitForSingleObject(pi.hProcess, timeoutMs) != 0) { TerminateProcess(pi.hProcess, 1); return null; }
                    return read.Wait(5000) ? read.Result : null;
                }
                finally { CloseHandle(pi.hProcess); }
            }
        }
    }
}
