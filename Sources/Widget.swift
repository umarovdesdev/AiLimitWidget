// Виджет «Лимиты ИИ» для macOS — лимиты Claude Code, Antigravity CLI, Codex и других ИИ (Extra.swift) в строке меню.
// Claude: те же данные, что /usage в Claude Code; вход читаем из связки ключей («Claude Code-credentials»)
// или из ~/.claude/.credentials.json — только читаем.
// Antigravity: «agy -p /quota --output-format json» — без обращения к модели и без расхода квоты.
// Codex: вход из ~/.codex/auth.json, лимиты — тот же запрос, что /status в самом Codex.
// Порт AiLimitWidget.cs (Windows): надпись у часов → две строки процентов в строке меню, окно → всплывающая панель.

import AppKit
import SwiftUI

final class Limit {
    let key: String
    var title: String
    let percent: Double          // израсходовано, 0…100 (у Antigravity пересчитано из остатка)
    let resetsAt: Date?
    let windowSeconds: Int64     // длина окна лимита (у Codex приходит с сервера)

    init(key: String, title: String, percent: Double, resetsAt: Date?, windowSeconds: Int64 = 0) {
        self.key = key; self.title = title; self.percent = percent; self.resetsAt = resetsAt; self.windowSeconds = windowSeconds
    }
}

// группа моделей Antigravity: у каждой свой 5-часовой и недельный лимит
final class AgyGroup {
    var key = "", title = "", models = ""
    var session: Limit?, week: Limit?
}

struct AppSettings {
    var transparency = 1         // 0 — низкая … 3 — максимальная
    var refreshMinutes = 2
    var notify = true
    var clockLabel = true        // проценты в строке меню (иначе — квадратный значок с числом)
    var showClaude = true, showAgy = true, showCodex = true
    var showDetails = false
    var clockItems = "claude,gemini,3p,codex,geminicli,copilot,cursor"
    var hiddenExtras = ""        // другие ИИ (Gemini CLI, Copilot, Cursor), которые выключили в «Показывать»
    var loggedOut = ""           // сервисы, скрытые из-за выхода: вернутся сами, когда в них снова войдут
}

// у каждого лимита свой цвет: Claude Code — оранжевый, Gemini — зелёный, Claude и GPT в Antigravity — синий, Codex — жёлтый
enum Pal {
    static let accent = NSColor(hex: "#D97757"), gemini = NSColor(hex: "#34C759"), agyClaude = NSColor(hex: "#4C8DF6"),
               codex = NSColor(hex: "#FFD60A"), warn = NSColor(hex: "#FF9F0A"), danger = NSColor(hex: "#FF453A")

    static func group(_ key: String) -> NSColor {
        switch key {
        case "claude": return accent
        case "gemini": return gemini
        case "codex": return codex
        default: return agyClaude
        }
    }

    static func severity(_ pct: Double, _ normal: NSColor = accent) -> NSColor { pct >= 90 ? danger : pct >= 75 ? warn : normal }
}

// процент с учётом того, что окно лимита уже закончилось (тогда до нового запроса — 0)
func current(_ l: Limit?, _ now: Date) -> Double {
    guard let l = l else { return 0 }
    if let r = l.resetsAt, r <= now { return 0 }
    return max(0, min(100, l.percent))
}

private func ended(_ l: Limit?, _ now: Date) -> Bool {
    guard let l = l, let r = l.resetsAt else { return false }
    return r <= now && l.percent > 0
}

final class Widget: NSObject, ObservableObject, NSPopoverDelegate {
    static let usageUrl = "https://api.anthropic.com/api/oauth/usage"
    static let codexUsageUrl = "https://chatgpt.com/backend-api/wham/usage"
    static let launchLabel = "com.asror.AiLimitWidget"
    static let refreshOptions = [1, 2, 5, 10]
    static let notifyThresholds = [95, 80]
    // недельные лимиты, которые показываем строками (остальные поля ответа — служебные)
    static let weeklyKeys = [("seven_day", "Неделя · все модели"), ("seven_day_opus", "Неделя · Opus"), ("seven_day_sonnet", "Неделя · Sonnet")]
    // столбцы в строке меню, слева направо
    static let clockColumns = [("claude", "Claude Code"), ("gemini", "Gemini"), ("3p", "Claude и GPT (Antigravity)"), ("codex", "Codex")]
        + Extra.all.map { ($0.key, $0.name) }

    let dir: String
    var s = AppSettings()
    var settingsPath: String { dir + "/settings.json" }
    var cachePath: String { dir + "/last-usage.json" }
    var agyCachePath: String { dir + "/last-agy.json" }
    var codexCachePath: String { dir + "/last-codex.json" }

    // ---------- Claude ----------
    var session: Limit?
    var weekly: [Limit] = []
    var plan = "", status = ""
    var statusIsError = false
    var account: JSON?                          // oauthAccount из ~/.claude.json
    var breakdown: [(String, Double)] = []
    var updatedAt: Date?
    var nextFetch = Date.distantPast
    var fetching = false
    var loggedOut = false                       // нет входа по подписке — показываем кнопку «Войти в Claude»
    var notified = Set<String>()

    // ---------- Antigravity ----------
    var agyGroups: [AgyGroup] = []
    var agyEmail: String?
    var agyStatus = ""
    var agyStatusIsError = false, agyFetching = false, agyMissing = false
    var agyCredits: Double?
    var agyUpdatedAt: Date?
    var agyNextFetch = Date.distantPast

    // ---------- Codex ----------
    var codexLimits: [Limit] = []
    var codexPlan = ""
    var codexEmail: String?
    var codexStatus = ""
    var codexStatusIsError = false, codexFetching = false, codexMissing = false
    var codexUpdatedAt: Date?
    var codexNextFetch = Date.distantPast

    // ---------- другие ИИ ----------
    let extras = Extra.all.map { ExtraProvider(key: $0.key, name: $0.name, color: NSColor(hex: $0.color)) }

    // ---------- окно ----------
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var hosting: NSHostingController<PanelView>!
    var preview = false                         // панель открыта наведением, а не нажатием
    var hoverSince: Date?
    var hiddenAt = Date.distantPast
    var lastIconKey: String?
    var confirmLogout = false, loggingOut = false
    var logoutTarget = "claude"                 // из какого сервиса выходим: claude, agy или codex
    var loginProc: Process?
    var loginUrl: String?
    var nextReturnCheck = Date.distantPast
    private var timers: [Timer] = []

    init(dir: String) {
        self.dir = dir
        super.init()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    var anyFetching: Bool { fetching || agyFetching || codexFetching || extras.contains { $0.fetching } }
    var shownServices: Int { (s.showClaude ? 1 : 0) + (s.showAgy ? 1 : 0) + (s.showCodex ? 1 : 0) + shownExtras.count }
    func extraOn(_ key: String) -> Bool { !s.hiddenExtras.split(separator: ",").contains(Substring(key)) }
    // другие ИИ показываем, только когда в них вошли
    var shownExtras: [ExtraProvider] { extras.filter { $0.signedIn && extraOn($0.key) } }
    func clockShows(_ key: String) -> Bool { s.clockItems.split(separator: ",").contains(Substring(key)) }

    // ---------- запуск ----------
    func start() {
        loadSettings()
        loadCache()
        loadAgyCache()
        loadCodexCache()
        Notify.setup()
        DispatchQueue.global().async { _ = Shell.loginPath }   // PATH пользователя — заранее, в фоне

        hosting = NSHostingController(rootView: PanelView(w: self))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.preferredContentSize] }
        popover.contentViewController = hosting
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
        }
        // нажали в другой программе или на рабочем столе — панель закрывается
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.hideWidget()
        }
        // перешли в другое пространство или в полноэкранную программу — панель закрывается
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.hideWidget()
        }
        // правый клик по значку или по панели — меню виджета, системное меню не открывается
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { [weak self] e in
            guard let self = self else { return e }
            let inStatus = e.window != nil && e.window === self.statusItem.button?.window
            let inPanel = self.popover.isShown && e.window === self.popover.contentViewController?.view.window
            if !inStatus && !inPanel { return e }
            if e.type == .rightMouseDown {
                DispatchQueue.main.async {
                    if inStatus && self.preview { self.hideWidget() }
                    self.showMenu(fromStatus: inStatus)
                }
            }
            return nil
        }
        // Esc — закрыть панель
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.keyCode == 53, self.popover.isShown, e.window === self.popover.contentViewController?.view.window else { return e }
            self.hideWidget()
            return nil
        }
        // нажали в панели, открытой наведением, — она остаётся открытой как обычно
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            if let self = self, self.preview, self.popover.isShown, e.window === self.popover.contentViewController?.view.window {
                self.makeInteractive()
            }
            return e
        }

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        let hover = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.checkHover() }
        for t in [tick, hover] { RunLoop.main.add(t, forMode: .common); timers.append(t) }

        if Autostart.isOn(Widget.launchLabel) { Autostart.set(Widget.launchLabel, true) }   // приложение перенесли — обновить путь
        updateView()
        fetchAll()
    }

    // ---------- настройки ----------
    func loadSettings() {
        if let d = J.file(settingsPath) {
            if let v = J.double(d["Transparency"]) { s.transparency = max(0, min(3, Int(v))) }
            if let v = J.double(d["RefreshMinutes"]) { s.refreshMinutes = Int(v) }
            if let v = J.bool(d["Notify"]) { s.notify = v }
            if let v = J.bool(d["ClockLabel"]) { s.clockLabel = v }
            if let v = J.bool(d["ShowClaude"]) { s.showClaude = v }
            if let v = J.bool(d["ShowAgy"]) { s.showAgy = v }
            if let v = J.bool(d["ShowCodex"]) { s.showCodex = v }
            if let v = J.bool(d["ShowDetails"]) { s.showDetails = v }
            if let v = J.string(d["ClockItems"]) { s.clockItems = v }
            if let v = J.string(d["LoggedOut"]) { s.loggedOut = v }
            if let v = J.string(d["HiddenExtras"]) { s.hiddenExtras = v }
            // настройки старой версии: столбцы других ИИ в строке меню включены по умолчанию
            if J.bool(d["ClockExtras"]) == nil { s.clockItems += "," + Extra.all.map { $0.key }.joined(separator: ",") }
        }
        if !Widget.refreshOptions.contains(s.refreshMinutes) { s.refreshMinutes = 2 }
        if !Widget.clockColumns.contains(where: { clockShows($0.0) }) { s.clockItems = "claude,gemini,3p,codex" }
        if !s.showClaude && !s.showAgy && !s.showCodex { s.showClaude = true }
    }

    func saveSettings() {
        J.write(["Transparency": s.transparency, "RefreshMinutes": s.refreshMinutes, "Notify": s.notify,
                 "ClockLabel": s.clockLabel, "ShowClaude": s.showClaude, "ShowAgy": s.showAgy, "ShowCodex": s.showCodex,
                 "ShowDetails": s.showDetails, "ClockItems": s.clockItems, "LoggedOut": s.loggedOut,
                 "HiddenExtras": s.hiddenExtras, "ClockExtras": true] as [String: Any], settingsPath)
    }

    // ---------- данные Claude ----------
    static var claudeConfigDir: String {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        return env.isEmpty ? Shell.home + "/.claude" : env
    }

    static var claudeExe: String? { Shell.find("claude", extra: [Shell.home + "/.claude/local/claude"]) }

    struct ClaudeAuth {
        var token: String?
        var plan = ""
        var problem: String?
        var account: JSON?
    }

    // Claude Code на macOS хранит вход в связке ключей; старые версии и CLAUDE_CONFIG_DIR — в файле
    static func readClaudeAuth() -> ClaudeAuth {
        var raw: JSON?
        let r = Proc.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
        if let out = r.output?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            raw = J.obj(out) ?? J.obj(hexDecode(out))
        }
        if raw == nil { raw = J.file(claudeConfigDir + "/.credentials.json") }
        guard let d = raw else { return ClaudeAuth(token: nil, problem: "Claude Code не найден — войдите в него командой claude") }
        let oauth = d["claudeAiOauth"] as? JSON
        var a = ClaudeAuth()
        a.token = J.string(oauth?["accessToken"])
        a.plan = planName(J.string(oauth?["subscriptionType"]), J.string(oauth?["rateLimitTier"]))
        if (a.token ?? "").isEmpty { a.problem = "Нет входа по подписке — выполните /login в Claude Code"; return a }
        a.account = readAccount()
        if let exp = J.double(oauth?["expiresAt"]), Date(timeIntervalSince1970: exp / 1000) < Date() {
            a.problem = "Вход истёк — откройте Claude Code, он обновит его сам"
        }
        return a
    }

    static func hexDecode(_ s: String) -> String? {
        guard s.count % 2 == 0, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            bytes.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    // сведения об аккаунте Claude Code хранит в ~/.claude.json → oauthAccount
    static func readAccount() -> JSON? {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        let path = env.isEmpty ? Shell.home + "/.claude.json" : env + "/.claude.json"
        return J.file(path)?["oauthAccount"] as? JSON
    }

    static func planName(_ type: String?, _ tier: String?) -> String {
        guard let type = type, !type.isEmpty else { return "" }
        let name = type.prefix(1).uppercased() + String(type.dropFirst())
        let t = tier ?? ""
        if let r = t.range(of: "\\d+(?=x)", options: .regularExpression) { return name + " " + String(t[r]) + "x" }
        return name
    }

    // обновить всё, что показываем
    func fetchAll() {
        fetch()
        fetchAgy()
        fetchCodex()
        for p in extras { fetchExtra(p) }
        checkReturn(true)   // заодно — не вошли ли снова в скрытые после выхода сервисы
    }

    func fetch() {
        if fetching || !s.showClaude { return }
        fetching = true
        nextFetch = Date().addingTimeInterval(TimeInterval(s.refreshMinutes * 60))
        updateView()
        DispatchQueue.global().async {
            let auth = Widget.readClaudeAuth()
            DispatchQueue.main.async { self.gotAuth(auth) }
        }
    }

    private func gotAuth(_ a: ClaudeAuth) {
        plan = a.plan
        if let acc = a.account { account = acc }
        loggedOut = (a.token ?? "").isEmpty
        if loggedOut {
            // пока не вошли — проверяем вход часто: вход в браузере подхватится за секунды
            fetching = false
            if session != nil || account != nil { clearData() }
            setStatus("", false)
            nextFetch = Date().addingTimeInterval(5)
            updateView()
            return
        }
        if let p = a.problem { fetching = false; setStatus(p, updatedAt == nil); updateView(); return }

        var req = URLRequest(url: URL(string: Widget.usageUrl)!, timeoutInterval: 30)
        req.setValue("Bearer " + (a.token ?? ""), forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.0 AiLimitWidget/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async { self.fetchDone(code, text) }
        }.resume()
    }

    private func fetchDone(_ code: Int, _ text: String?) {
        fetching = false
        if (200..<300).contains(code), let t = text, parse(t) {
            updatedAt = Date()
            setStatus("", false)
            J.write(["At": Fmt.isoString(updatedAt!), "Body": t], cachePath)
            checkNotifications()
        } else if code == 401 || code == 403 {
            setStatus("Вход устарел — откройте Claude Code, он обновит его сам", updatedAt == nil)
        } else if code == 429 {
            setStatus("Сервер просит подождать — повторю через 5 мин", false)
            nextFetch = Date().addingTimeInterval(300)
        } else {
            setStatus(code >= 300 ? "Ошибка сервера (\(code))" : "Нет соединения — повторю позже", updatedAt == nil)
        }
        updateView()
    }

    static func readLimit(_ d: JSON, _ key: String, _ title: String) -> Limit? {
        guard let o = d[key] as? JSON, let u = J.double(o["utilization"]) else { return nil }
        return Limit(key: key, title: title, percent: u, resetsAt: Fmt.iso(o["resets_at"]))
    }

    @discardableResult
    func parse(_ text: String) -> Bool {
        guard let d = J.obj(text) else { return false }
        session = Widget.readLimit(d, "five_hour", "Сессия (5 ч)") ?? Limit(key: "five_hour", title: "Сессия (5 ч)", percent: 0, resetsAt: nil)
        weekly = Widget.weeklyKeys.compactMap { Widget.readLimit(d, $0.0, $0.1) }
        breakdown = ((d["seven_day_breakdown"] as? JSON)?["rows"] as? [JSON] ?? []).compactMap { r -> (String, Double)? in
            guard let p = J.double(r["percent"]) else { return nil }
            return (J.string(r["display_name"]) ?? "", p)
        }
        // платные кредиты сверх подписки — только если включены
        if let extra = d["extra_usage"] as? JSON, J.bool(extra["is_enabled"]) == true, let u = J.double(extra["utilization"]) {
            weekly.append(Limit(key: "extra", title: "Доп. кредиты (месяц)", percent: u, resetsAt: nil))
        }
        return true
    }

    func loadCache() {
        guard let d = J.file(cachePath), let body = J.string(d["Body"]), parse(body) else { return }
        updatedAt = Fmt.iso(d["At"])
    }

    func setStatus(_ text: String, _ error: Bool) { status = text; statusIsError = error }

    func clearData() {
        session = nil
        weekly = []
        breakdown = []
        account = nil
        updatedAt = nil
        plan = ""
        try? FileManager.default.removeItem(atPath: cachePath)
        lastIconKey = nil
    }

    // ---------- данные Antigravity ----------
    static var agyExe: String? {
        Shell.find("agy", extra: [Shell.home + "/.agy/bin/agy", Shell.home + "/Library/Application Support/agy/bin/agy"])
    }
    static var agyDir: String { Shell.home + "/.gemini/antigravity-cli" }

    // probe — пробный запрос для скрытого после выхода Antigravity: ответил — значит, снова вошли
    func fetchAgy(probe: Bool = false) {
        if agyFetching || (!s.showAgy && !probe) { return }
        agyFetching = true
        agyNextFetch = Date().addingTimeInterval(TimeInterval(s.refreshMinutes * 60))
        updateView()
        DispatchQueue.global().async {
            var quota: String?, credits: String?
            var missing = true
            if let exe = Widget.agyExe {
                let q = Proc.run(exe, ["-p", "/quota", "--output-format", "json"])
                quota = q.output
                missing = q.missing
                if quota != nil { credits = Proc.run(exe, ["-p", "/credits", "--output-format", "json"]).output }
            }
            let email = Widget.readAgyEmail()
            DispatchQueue.main.async { self.fetchAgyDone(quota, credits, email, missing) }
        }
    }

    private func fetchAgyDone(_ quota: String?, _ credits: String?, _ email: String?, _ missing: Bool) {
        agyFetching = false
        agyMissing = missing
        if let e = email { agyEmail = e }
        var problem: String?
        if missing {
            setAgyStatus("Antigravity CLI не найден — установите agy", true)
            agyNextFetch = Date().addingTimeInterval(600)
        } else if let q = quota, parseAgy(q, &problem) {
            agyUpdatedAt = Date()
            setAgyStatus("", false)
            parseAgyCredits(credits)
            if isLoggedOut("agy") { comeBack("agy") }   // пробный запрос прошёл — в Antigravity снова вошли
            var cache: [String: Any] = ["At": Fmt.isoString(agyUpdatedAt!), "Body": q]
            if let c = credits { cache["Credits"] = c }
            if let e = agyEmail { cache["Email"] = e }
            J.write(cache, agyCachePath)
            checkNotifications()
        } else if quota != nil, let p = problem {
            setAgyStatus(p, agyUpdatedAt == nil)
        } else {
            setAgyStatus("Antigravity не ответил — повторю позже", agyUpdatedAt == nil)
        }
        updateView()
    }

    func setAgyStatus(_ text: String, _ error: Bool) { agyStatus = text; agyStatusIsError = error }

    // «Gemini Models» → «Gemini», «Claude and GPT models» → «Claude и GPT»
    static func agyTitle(_ key: String, _ name: String?) -> String {
        if key == "gemini" { return "Gemini" }
        if key == "3p" { return "Claude и GPT" }
        return (name ?? key).replacingOccurrences(of: " Models", with: "").replacingOccurrences(of: " models", with: "")
            .replacingOccurrences(of: " and ", with: " и ")
    }

    func parseAgy(_ text: String, _ problem: inout String?) -> Bool {
        guard let d = J.embedded(text) else { return false }
        if J.string(d["status"]) != "SUCCESS" {
            let r = (J.string(d["response"]) ?? J.string(d["error"]) ?? "").lowercased()
            problem = r.contains("sign") || r.contains("auth") ? "Нет входа в Antigravity — запустите agy и войдите" : "Antigravity вернул ошибку"
            return false
        }
        guard let groups = ((d["command"] as? JSON)?["data"] as? JSON)?["groups"] as? [JSON] else {
            problem = "Antigravity не сообщил лимиты"
            return false
        }
        var list: [AgyGroup] = []
        for gr in groups {
            let g = AgyGroup()
            let models = J.string(gr["description"]) ?? ""
            if let colon = models.firstIndex(of: ":") { g.models = models[models.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            guard let buckets = gr["buckets"] as? [JSON] else { continue }
            for b in buckets {
                let id = J.string(b["id"]) ?? ""
                if g.key.isEmpty, let dash = id.lastIndex(of: "-"), dash > id.startIndex { g.key = String(id[..<dash]) }
                guard let remaining = J.double(b["remaining_fraction"]) else { continue }   // окно сейчас не действует
                let window = J.string(b["window"])
                let l = Limit(key: id, title: "", percent: max(0, min(100, (1 - remaining) * 100)), resetsAt: Fmt.iso(b["reset_time"]))
                if window == "5h" { g.session = l } else if window == "weekly" { g.week = l }
            }
            if g.key.isEmpty { g.key = J.string(gr["name"]) ?? "" }
            g.title = Widget.agyTitle(g.key, J.string(gr["name"]))
            g.session?.title = g.title + " · 5 ч"
            g.week?.title = g.title + " · неделя"
            list.append(g)
        }
        agyGroups = list
        return true
    }

    func parseAgyCredits(_ text: String?) {
        let data = ((J.embedded(text) ?? [:])["command"] as? JSON)?["data"] as? JSON
        if let c = J.double(data?["remaining_credits"]) { agyCredits = c }
    }

    // почту Antigravity пишет в свой журнал при входе: «applyAuthResult: email=…»
    static func readAgyEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: agyDir + "/cli.log"),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let re = try? NSRegularExpression(pattern: "applyAuthResult: email=([^,\\s]+@[^,\\s]+)") else { return nil }
        guard let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    func loadAgyCache() {
        guard let d = J.file(agyCachePath) else { return }
        var problem: String?
        if let body = J.string(d["Body"]), parseAgy(body, &problem) { agyUpdatedAt = Fmt.iso(d["At"]) }
        parseAgyCredits(J.string(d["Credits"]))
        agyEmail = J.string(d["Email"])
    }

    // для значка: первая из показанных в строке меню групп (обычно Gemini)
    func clockGroup() -> AgyGroup? {
        agyGroups.first(where: { clockShows($0.key) }) ?? agyGroups.first(where: { $0.key == "gemini" }) ?? agyGroups.first
    }

    // ---------- данные Codex ----------
    static var codexAuthPath: String {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        return (env.isEmpty ? Shell.home + "/.codex" : env) + "/auth.json"
    }

    static var codexExe: String? { Shell.find("codex", extra: ["/Applications/Codex.app/Contents/Resources/codex"]) }

    // средняя часть JWT (id_token) — там почта и тариф
    static func jwtClaims(_ jwt: String?) -> JSON? {
        let parts = (jwt ?? "").split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var p = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while p.count % 4 != 0 { p += "=" }
        return J.any(Data(base64Encoded: p)) as? JSON
    }

    func fetchCodex() {
        if codexFetching || !s.showCodex { return }
        codexNextFetch = Date().addingTimeInterval(TimeInterval(s.refreshMinutes * 60))
        codexMissing = !FileManager.default.fileExists(atPath: Widget.codexAuthPath)
        if codexMissing {
            setCodexStatus("Нет входа в Codex — выполните codex login", false)
            codexNextFetch = Date().addingTimeInterval(60)   // вход подхватится вскоре после «codex login»
            updateView()
            return
        }
        guard let d = J.file(Widget.codexAuthPath) else {
            setCodexStatus("Не удалось прочитать вход Codex", codexUpdatedAt == nil)
            updateView()
            return
        }
        let tokens = d["tokens"] as? JSON
        let token = J.string(tokens?["access_token"]) ?? ""
        let accountId = J.string(tokens?["account_id"]) ?? ""
        if let email = J.string(Widget.jwtClaims(J.string(tokens?["id_token"]))?["email"]), !email.isEmpty { codexEmail = email }
        if token.isEmpty {
            setCodexStatus("Codex вошёл по API-ключу — лимитов подписки нет. Для них: codex login", false)
            updateView()
            return
        }
        codexFetching = true
        updateView()
        var req = URLRequest(url: URL(string: Widget.codexUsageUrl)!, timeoutInterval: 30)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty { req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex_cli_rs AiLimitWidget/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async { self.fetchCodexDone(code, text) }
        }.resume()
    }

    private func fetchCodexDone(_ code: Int, _ text: String?) {
        codexFetching = false
        if (200..<300).contains(code), let t = text, parseCodex(t) {
            codexUpdatedAt = Date()
            setCodexStatus("", false)
            var cache: [String: Any] = ["At": Fmt.isoString(codexUpdatedAt!), "Body": t]
            if let e = codexEmail { cache["Email"] = e }
            J.write(cache, codexCachePath)
            checkNotifications()
        } else if code == 401 || code == 403 {
            setCodexStatus("Вход Codex устарел — запустите codex, он обновит его сам", codexUpdatedAt == nil)
        } else if code == 429 {
            setCodexStatus("Сервер просит подождать — повторю через 5 мин", false)
            codexNextFetch = Date().addingTimeInterval(300)
        } else {
            setCodexStatus(code >= 300 ? "Ошибка сервера Codex (\(code))" : "Нет соединения — повторю позже", codexUpdatedAt == nil)
        }
        updateView()
    }

    func setCodexStatus(_ text: String, _ error: Bool) { codexStatus = text; codexStatusIsError = error }

    // 18000 с → «Сессия (5 ч)», 604800 → «Неделя», 2592000 → «30 дней»
    static func windowTitle(_ seconds: Int64) -> String {
        if seconds <= 0 { return "Лимит" }
        if seconds <= 24 * 3600 { return "Сессия (\(Int((Double(seconds) / 3600).rounded())) ч)" }
        if seconds <= 8 * 24 * 3600 { return "Неделя" }
        return "\(Int((Double(seconds) / 86400).rounded())) дней"
    }

    @discardableResult
    func parseCodex(_ text: String) -> Bool {
        guard let d = J.obj(text) else { return false }
        let p = J.string(d["plan_type"]) ?? ""
        codexPlan = p.isEmpty ? "" : p.prefix(1).uppercased() + p.dropFirst()
        let rl = d["rate_limit"] as? JSON
        var list: [Limit] = []
        for w in ["primary_window", "secondary_window"] {
            guard let o = rl?[w] as? JSON, let used = J.double(o["used_percent"]) else { continue }
            let secs = Int64(J.double(o["limit_window_seconds"]) ?? 0)
            let at = J.double(o["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            list.append(Limit(key: "codex-" + w, title: Widget.windowTitle(secs), percent: max(0, min(100, used)), resetsAt: at, windowSeconds: secs))
        }
        codexLimits = list.sorted { $0.windowSeconds < $1.windowSeconds }
        return true
    }

    func loadCodexCache() {
        guard let d = J.file(codexCachePath) else { return }
        if let body = J.string(d["Body"]), parseCodex(body) { codexUpdatedAt = Fmt.iso(d["At"]) }
        codexEmail = J.string(d["Email"])
    }

    // «Сессия» — короткое окно Codex (до суток), «Неделя» — самое длинное из остальных
    var codexShort: Limit? { codexLimits.first { $0.windowSeconds <= 24 * 3600 } }
    var codexLong: Limit? { codexLimits.last { $0.windowSeconds > 24 * 3600 } }

    // ---------- данные других ИИ ----------
    // Вход не нашли — раздел не показываем и проверяем раз в несколько минут: вдруг войдут.
    func fetchExtra(_ p: ExtraProvider) {
        if p.fetching || !extraOn(p.key) { return }
        p.fetching = true
        p.nextFetch = Date().addingTimeInterval(TimeInterval(s.refreshMinutes * 60))
        DispatchQueue.global().async {
            let r = Extra.fetch(p.key)
            DispatchQueue.main.async {
                p.fetching = false
                let wasShown = p.signedIn
                p.signedIn = r.signedIn
                if !r.signedIn {
                    p.limits = []; p.plan = ""; p.email = nil; p.updatedAt = nil
                    p.nextFetch = Date().addingTimeInterval(max(TimeInterval(self.s.refreshMinutes * 60), 300))
                } else {
                    if !r.plan.isEmpty { p.plan = r.plan }
                    if let e = r.email, !e.isEmpty { p.email = e }
                    if r.problem == nil || !r.limits.isEmpty {
                        p.limits = r.limits
                        p.updatedAt = Date()
                    }
                    p.status = r.problem ?? ""
                    p.statusIsError = r.problem != nil && p.updatedAt == nil
                    if let wait = r.retryAfter { p.nextFetch = Date().addingTimeInterval(wait) }
                    self.checkNotifications()
                }
                if wasShown != p.signedIn { self.lastIconKey = nil }
                self.updateView()
            }
        }
    }

    // уведомление, когда лимит переходит 80% и 95% (один раз на окно лимита)
    func checkNotifications() {
        if !s.notify { return }
        var all: [(String, Limit)] = []
        if s.showClaude {
            if let l = session { all.append(("Claude Code", l)) }
            all += weekly.map { ("Claude Code", $0) }
        }
        if s.showAgy {
            for g in agyGroups { for l in [g.session, g.week].compactMap({ $0 }) { all.append(("Antigravity", l)) } }
        }
        if s.showCodex { all += codexLimits.map { ("Codex", $0) } }
        for p in shownExtras { all += p.limits.map { (p.name, $0) } }
        let now = Date()
        for (service, l) in all {
            for t in Widget.notifyThresholds where current(l, now) >= Double(t) {
                let id = "\(service)|\(l.key)|\(l.resetsAt.map(Fmt.isoString) ?? "")|\(t)"
                if notified.insert(id).inserted {
                    let when = l.resetsAt.map { "Сброс через " + Fmt.duration($0.timeIntervalSince(now)) + "." } ?? ""
                    Notify.post("\(service): \(l.title) — \(Fmt.pct(l.percent))", when)
                }
                break
            }
        }
    }

    // ---------- обновление по таймеру ----------
    func tick() {
        let now = Date()
        let window = TimeInterval(s.refreshMinutes * 60)
        // окно лимита закончилось — спрашиваем новые данные раньше срока
        let expired = session?.resetsAt.map { $0 <= now } ?? false
        if !fetching && (now >= nextFetch || (expired && now >= nextFetch.addingTimeInterval(-window + 20))) { fetch() }
        let agyExpired = agyGroups.contains { ended($0.session, now) || ended($0.week, now) }
        if !agyFetching && (now >= agyNextFetch || (agyExpired && now >= agyNextFetch.addingTimeInterval(-window + 20))) { fetchAgy() }
        let codexExpired = codexLimits.contains { ended($0, now) }
        if !codexFetching && (now >= codexNextFetch || (codexExpired && now >= codexNextFetch.addingTimeInterval(-window + 20))) { fetchCodex() }
        for p in extras where !p.fetching {
            let expired = p.limits.contains { ended($0, now) }
            if now >= p.nextFetch || (expired && now >= p.nextFetch.addingTimeInterval(-window + 20)) { fetchExtra(p) }
        }
        checkReturn(false)
        updateView()
    }

    func updateView() {
        objectWillChange.send()
        updateStatusItem()
        if #available(macOS 13.0, *) { return }
        // до macOS 13 размер панели по содержимому выставляем сами
        DispatchQueue.main.async {
            guard self.popover.isShown else { return }
            let size = self.hosting.view.fittingSize
            if size.width > 1 && size != self.popover.contentSize { self.popover.contentSize = size }
        }
    }

    // подпись в шапке: когда обновлялось (по самому свежему из сервисов)
    var subText: String {
        if anyFetching { return "обновление…" }
        let dates = [s.showClaude ? updatedAt : nil, s.showAgy ? agyUpdatedAt : nil, s.showCodex ? codexUpdatedAt : nil].compactMap { $0 }
            + shownExtras.compactMap { $0.updatedAt }
        guard let last = dates.max() else { return "" }
        return "обновлено " + Fmt.date(last, Calendar.current.isDateInToday(last) ? "HH:mm" : "d MMM HH:mm")
    }

    // ---------- строка меню ----------
    struct ClockValue { let text: String; let color: NSColor? }
    struct ClockCell { let color: NSColor; let top: ClockValue; let bottom: ClockValue }

    // столбцы как у часов в Windows: сверху сессия (5 ч), снизу неделя; у каждого точка своего цвета
    func clockCells(_ now: Date) -> [ClockCell] {
        var cells: [ClockCell] = []
        for (key, _) in Widget.clockColumns {
            let shown: Bool
            let limits: [Limit?]
            switch key {
            case "claude":
                shown = s.showClaude
                limits = [session, weekly.first]
            case "codex":
                shown = s.showCodex && !codexMissing
                limits = [codexShort, codexLong]
            case _ where extras.contains { $0.key == key }:
                let p = extras.first { $0.key == key }!
                shown = p.signedIn && extraOn(key) && !p.limits.isEmpty
                limits = [p.short, p.long]
            default:
                let g = agyGroups.first { $0.key == key }
                // пока данных нет — столбец всё равно показываем («—»), чтобы надпись не прыгала
                shown = s.showAgy && !agyMissing && (g != nil || agyGroups.isEmpty)
                limits = [g?.session, g?.week]
            }
            guard shown && clockShows(key) else { continue }
            let extra = extras.first { $0.key == key }
            let values = limits.enumerated().map { (i, l) -> ClockValue in
                let v = current(l, now)
                // у другого ИИ один лимит (например, месяц у Copilot) — нижняя строка пустая
                if l == nil && extra != nil && i == 1 { return ClockValue(text: "", color: nil) }
                return ClockValue(text: l == nil ? "—" : Fmt.pct(v), color: v >= 75 ? Pal.severity(v) : nil)
            }
            cells.append(ClockCell(color: extra?.color ?? Pal.group(key), top: values[0], bottom: values[1]))
        }
        if cells.isEmpty {
            cells.append(ClockCell(color: Pal.accent, top: ClockValue(text: "—", color: nil), bottom: ClockValue(text: "—", color: nil)))
        }
        return cells
    }

    func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        let now = Date()
        b.toolTip = trayTip(now)
        let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if s.clockLabel {
            let cells = clockCells(now)
            let key = "clock|\(dark)|" + cells.map { c in [c.top, c.bottom].map { "\($0.text)\($0.color?.description ?? "")" }.joined(separator: "/") }.joined(separator: ",")
            if key == lastIconKey { return }
            lastIconKey = key
            b.image = Widget.clockImage(cells, dark: dark)
            return
        }
        // главное число — сессия Claude; если Claude скрыт — сессия Antigravity
        let ag = s.showAgy ? clockGroup() : nil
        let agyPct = current(ag?.session, now)
        let claudeMain = s.showClaude
        let known = claudeMain ? session != nil : ag?.session != nil
        let active = session?.resetsAt.map { $0 > now } ?? false
        let main = claudeMain ? (active ? session!.percent : 0) : agyPct
        let stripe = claudeMain && ag?.session != nil   // полоска снизу цвета группы — сессия Antigravity
        let agyColor = ag.map { Pal.group($0.key) } ?? Pal.gemini
        let key = "badge|\(known ? String(Int(main.rounded())) : "-")|\(claudeMain)|\(stripe ? String(Int(agyPct.rounded())) + (ag?.key ?? "") : "")"
        if key == lastIconKey { return }
        lastIconKey = key
        let color = !known ? NSColor(hex: "#636366") : Pal.severity(main, claudeMain ? Pal.accent : agyColor)
        let text = !known ? "…" : main >= 99.5 ? "!!" : String(Int(main.rounded()))
        b.image = Widget.badgeImage(text, color, stripe ? (agyPct, Pal.severity(agyPct, agyColor)) : nil)
    }

    func trayTip(_ now: Date) -> String {
        var tip: [String] = []
        if s.showClaude, let sess = session {
            let active = sess.resetsAt.map { $0 > now } ?? false
            tip.append("Claude " + Fmt.pct(active ? sess.percent : 0) + (weekly.isEmpty ? "" : " (нед. " + Fmt.pct(current(weekly[0], now)) + ")"))
        }
        if s.showAgy { for g in agyGroups { tip.append((g.key == "3p" ? "Claude/GPT" : g.title) + " " + Fmt.pct(current(g.session, now))) } }
        if s.showCodex, let l = codexLimits.first { tip.append("Codex " + Fmt.pct(current(l, now))) }
        for p in shownExtras { if let l = p.short { tip.append(p.name + " " + Fmt.pct(current(l, now))) } }
        return tip.isEmpty ? "Лимиты ИИ" : "Сверху — сессия, снизу — неделя\n" + tip.joined(separator: " · ")
    }

    static func clockImage(_ cells: [ClockCell], dark: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let ink = dark ? NSColor.white : NSColor(hex: "#1C1C1E")
        let h = max(18, NSStatusBar.system.thickness)
        let lineH = ceil(font.ascender - font.descender)
        let dot: CGFloat = 5, gap: CGFloat = 2, between: CGFloat = 6
        func width(_ t: String) -> CGFloat { ceil((t as NSString).size(withAttributes: [.font: font]).width) }
        let widths = cells.map { max(width($0.top.text), width($0.bottom.text), width("0%")) }
        var total: CGFloat = 0
        for w in widths { total += dot + gap + w }
        total += between * CGFloat(max(0, cells.count - 1))
        let image = NSImage(size: NSSize(width: max(total, 10), height: h), flipped: true) { _ in
            var x: CGFloat = 0
            for (i, c) in cells.enumerated() {
                for (row, v) in [c.top, c.bottom].enumerated() {
                    let y = row == 0 ? h / 2 - lineH + 0.5 : h / 2 - 0.5
                    c.color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: y + (lineH - dot) / 2, width: dot, height: dot)).fill()
                    let tw = width(v.text)
                    (v.text as NSString).draw(at: NSPoint(x: x + dot + gap + widths[i] - tw, y: y),
                                              withAttributes: [.font: font, .foregroundColor: v.color ?? ink])
                }
                x += dot + gap + widths[i] + between
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func badgeImage(_ text: String, _ color: NSColor, _ stripe: (Double, NSColor)?) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 4.5, yRadius: 4.5).fill()
            let font = NSFont.systemFont(ofSize: text.count >= 2 ? 9.5 : 11.5, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2 - (stripe != nil ? 1.5 : 0)), withAttributes: attrs)
            if let st = stripe {
                NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 0.67).setFill()
                NSBezierPath(roundedRect: NSRect(x: 2.5, y: 14, width: 13, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
                if st.0 >= 0.5 {
                    st.1.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 2.5, y: 14, width: max(3, 13 * st.0 / 100), height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // ---------- панель ----------
    @objc func statusClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showMenu(fromStatus: true); return }
        toggleWindow()
    }

    func toggleWindow() {
        if popover.isShown {
            if preview { makeInteractive() } else { hideWidget() }
        }
        // нажатие по значку сначала закрывает панель (нажали мимо неё), затем приходит само нажатие —
        // не открываем панель заново сразу после такого закрытия
        else if Date().timeIntervalSince(hiddenAt) > 0.3 { showWidget() }
    }

    func showWidget() {
        preview = false
        NSApp.activate(ignoringOtherApps: true)
        present()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func present() {
        popover.behavior = preview ? .applicationDefined : .transient
        updateView()
        if !popover.isShown, let b = statusItem.button {
            if #available(macOS 13.0, *) {} else { popover.contentSize = hosting.view.fittingSize }
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    func makeInteractive() {
        preview = false
        NSApp.activate(ignoringOtherApps: true)
        popover.behavior = .transient
        popover.contentViewController?.view.window?.makeKey()
        updateView()
    }

    func hideWidget() {
        preview = false
        confirmLogout = false
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        hiddenAt = Date()
        preview = false
        confirmLogout = false
        updateView()
    }

    // При наведении на проценты в строке меню открывается та же панель, но без шапки и без фокуса —
    // только посмотреть. Увели курсор — панель прячется; нажали в ней — остаётся открытой как обычно.
    func checkHover() {
        guard s.clockLabel, let b = statusItem?.button, let bw = b.window else { hoverSince = nil; return }
        let pt = NSEvent.mouseLocation
        let overLabel = bw.frame.insetBy(dx: -2, dy: -4).contains(pt)
        let overWindow = popover.isShown && (popover.contentViewController?.view.window?.frame.insetBy(dx: -2, dy: -8).contains(pt) ?? false)
        if preview {
            if !overLabel && !overWindow { hideWidget() }
            return
        }
        if !overLabel || popover.isShown { hoverSince = nil; return }
        if hoverSince == nil { hoverSince = Date() }
        if Date().timeIntervalSince(hoverSince!) < 0.4 { return }
        hoverSince = nil
        // полноэкранная программа — строка меню выезжает от курсора у края, панель не показываем
        if FullScreen.isActive() { return }
        preview = true
        present()
    }

    // ---------- меню ----------
    func showMenu(fromStatus: Bool = false) {
        let menu = buildMenu()
        if fromStatus, let b = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 5), in: b)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func serviceToggle(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void, _ fetch: @escaping () -> Void) -> NSMenuItem {
        ClosureItem(title, checked: on) { [unowned self] in
            // выключить последний сервис нельзя
            if on && self.shownServices <= 1 { return }
            set(!on)
            self.saveSettings()
            self.lastIconKey = nil
            if !on { fetch() }
            self.updateView()
        }
    }

    private func clockToggle(_ key: String, _ title: String) -> NSMenuItem {
        ClosureItem(title, checked: clockShows(key)) { [unowned self] in
            var items = self.s.clockItems.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if items.contains(key) {
                if items.count <= 1 { return }   // последний столбец не снимается
                items.removeAll { $0 == key }
            } else { items.append(key) }
            self.s.clockItems = Widget.clockColumns.map { $0.0 }.filter { items.contains($0) }.joined(separator: ",")
            self.saveSettings()
            self.lastIconKey = nil
            self.updateView()
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !loggedOut, let email = J.string(account?["emailAddress"]), !email.isEmpty {
            menu.addItem(ClosureItem(email + (plan.isEmpty ? "" : "  ·  " + plan), enabled: false))
            menu.addItem(.separator())
        }
        menu.addItem(ClosureItem("Обновить") { [unowned self] in self.fetchAll() })
        menu.addItem(.separator())
        menu.addItem(submenu("Показывать", [
            serviceToggle("Claude Code", s.showClaude, { [unowned self] v in self.s.showClaude = v; self.setLoggedOut("claude", false) }, { [unowned self] in self.fetch() }),
            serviceToggle("Antigravity", s.showAgy, { [unowned self] v in self.s.showAgy = v; self.setLoggedOut("agy", false) }, { [unowned self] in self.fetchAgy() }),
            serviceToggle("Codex", s.showCodex, { [unowned self] v in self.s.showCodex = v; self.setLoggedOut("codex", false) }, { [unowned self] in self.fetchCodex() })
        ] + extras.filter { $0.signedIn }.map { p in
            serviceToggle(p.name, extraOn(p.key), { [unowned self] v in
                var list = self.s.hiddenExtras.split(separator: ",").map(String.init).filter { $0 != p.key && !$0.isEmpty }
                if !v { list.append(p.key) }
                self.s.hiddenExtras = list.joined(separator: ",")
            }, { [unowned self] in self.fetchExtra(p) })
        }))
        // в строке меню — только столбцы тех ИИ, в которые вошли
        menu.addItem(submenu("В строке меню", Widget.clockColumns.filter { c in !extras.contains { $0.key == c.0 && !$0.signedIn } }.map { clockToggle($0.0, $0.1) }))
        menu.addItem(ClosureItem("Проценты в строке меню", checked: s.clockLabel) { [unowned self] in
            self.s.clockLabel.toggle(); self.saveSettings(); self.lastIconKey = nil; self.updateView()
        })
        menu.addItem(ClosureItem("Уведомлять при 80% и 95%", checked: s.notify) { [unowned self] in self.s.notify.toggle(); self.saveSettings() })
        menu.addItem(ClosureItem("Запускать вместе с macOS", checked: Autostart.isOn(Widget.launchLabel)) {
            Autostart.set(Widget.launchLabel, !Autostart.isOn(Widget.launchLabel))
        })
        menu.addItem(submenu("Интервал обновления", Widget.refreshOptions.map { m in
            ClosureItem("\(m) мин", checked: s.refreshMinutes == m) { [unowned self] in
                self.s.refreshMinutes = m
                self.nextFetch = (self.updatedAt ?? Date()).addingTimeInterval(TimeInterval(m * 60))
                self.saveSettings()
            }
        }))
        let levels = ["Низкая", "Средняя", "Высокая", "Максимальная"]
        menu.addItem(submenu("Прозрачность", levels.indices.map { i in
            ClosureItem(levels[i], checked: s.transparency == i) { [unowned self] in self.s.transparency = i; self.saveSettings(); self.updateView() }
        }))
        menu.addItem(.separator())
        // выход — только из тех сервисов, где вход есть
        var outs: [NSMenuItem] = []
        if s.showClaude && !loggedOut { outs.append(ClosureItem("Claude Code") { [unowned self] in self.logout("claude") }) }
        if s.showAgy && !agyMissing && !agyGroups.isEmpty { outs.append(ClosureItem("Antigravity") { [unowned self] in self.logout("agy") }) }
        if s.showCodex && !codexMissing { outs.append(ClosureItem("Codex") { [unowned self] in self.logout("codex") }) }
        if !outs.isEmpty { menu.addItem(submenu("Выйти из аккаунта", outs)) }
        if s.showClaude && loggedOut { menu.addItem(ClosureItem("Войти в Claude…") { [unowned self] in self.login() }) }
        menu.addItem(ClosureItem("Закрыть") { NSApp.terminate(nil) })
        return menu
    }

    // ---------- вход и выход ----------
    // Вход у виджета общий с Claude Code, поэтому входим и выходим его же командами:
    // «claude auth login» открывает браузер, «claude auth logout» удаляет вход из связки ключей.
    func login() {
        if loginProc != nil {
            if let u = loginUrl { Shell.open(u) }   // вход уже идёт — просто открыть страницу снова
            return
        }
        loginUrl = nil
        if let exe = Widget.claudeExe {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["auth", "login", "--claudeai"]
            p.environment = Shell.environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = Pipe()
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                guard let text = String(data: d, encoding: .utf8), let r = text.range(of: "https://\\S+", options: .regularExpression) else { return }
                let url = String(text[r])
                DispatchQueue.main.async { if self?.loginUrl == nil { self?.loginUrl = url; self?.updateView() } }
            }
            p.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.loginProc = nil; self?.loginUrl = nil; self?.fetch() }
            }
            do { try p.run(); loginProc = p } catch { setStatus("Не удалось запустить Claude Code", true) }
        } else {
            setStatus("Claude Code не найден — установите его и выполните claude", true)
        }
        if !popover.isShown || preview { showWidget() }
        updateView()
    }

    func cancelLogin() {
        if let p = loginProc, p.isRunning { p.terminate() }
        loginProc = nil
        loginUrl = nil
        updateView()
    }

    static func serviceName(_ target: String) -> String { target == "agy" ? "Antigravity" : target == "codex" ? "Codex" : "Claude Code" }

    // подтверждение показываем в самой панели
    func logout(_ target: String) {
        logoutTarget = target
        confirmLogout = true
        if !popover.isShown || preview { showWidget() }
        updateView()
    }

    func doLogout() {
        let target = logoutTarget
        confirmLogout = false
        loggingOut = true
        updateView()
        DispatchQueue.global().async {
            if target == "agy" {
                // у Antigravity выход есть только внутри его окна: открываем agy в Терминале и сразу выполняем /logout
                if let exe = Widget.agyExe { Shell.runInTerminal("'\(exe)' -i /logout") }
            } else if let exe = target == "codex" ? Widget.codexExe : Widget.claudeExe {
                _ = Proc.run(exe, target == "codex" ? ["logout"] : ["auth", "logout"], timeout: 30)
            }
            DispatchQueue.main.async { self.loggingOut = false; self.afterLogout(target) }
        }
    }

    // после выхода сведения о сервисе больше не показываем
    // (если это был единственный сервис — раздел остаётся, в нём предложение войти)
    func afterLogout(_ target: String) {
        let hide = shownServices > 1
        switch target {
        case "claude":
            clearData()
            if hide { s.showClaude = false; setLoggedOut("claude", true) }
        case "agy":
            agyGroups = []
            agyEmail = nil
            agyCredits = nil
            agyUpdatedAt = nil
            try? FileManager.default.removeItem(atPath: agyCachePath)
            if hide { s.showAgy = false; setLoggedOut("agy", true) } else { setAgyStatus("Нет входа в Antigravity — запустите agy и войдите", false) }
            // окно agy с /logout ещё открыто — первую пробу делаем через обычный интервал
            agyNextFetch = Date().addingTimeInterval(TimeInterval(s.refreshMinutes * 60))
        default:
            codexLimits = []
            codexEmail = nil
            codexPlan = ""
            codexUpdatedAt = nil
            try? FileManager.default.removeItem(atPath: codexCachePath)
            if hide { s.showCodex = false; setLoggedOut("codex", true) }
        }
        saveSettings()
        lastIconKey = nil
        fetch()
        fetchAgy()
        fetchCodex()
        updateView()
    }

    // ---------- возврат после нового входа ----------
    func isLoggedOut(_ key: String) -> Bool { s.loggedOut.split(separator: ",").contains(Substring(key)) }

    func setLoggedOut(_ key: String, _ on: Bool) {
        var list = s.loggedOut.split(separator: ",").map(String.init).filter { !$0.isEmpty && $0 != key }
        if on { list.append(key) }
        s.loggedOut = list.joined(separator: ",")
    }

    static func codexSignedIn() -> Bool {
        !(J.string((J.file(codexAuthPath)?["tokens"] as? JSON)?["access_token"]) ?? "").isEmpty
    }

    // сервисы, скрытые из-за выхода, тихо проверяем: вошли снова — раздел возвращается сам.
    // Codex и Claude — по входу раз в 5 с; Antigravity — пробным /quota с обычным интервалом.
    func checkReturn(_ now: Bool) {
        if s.loggedOut.isEmpty { return }
        if !now && Date() < nextReturnCheck { return }
        nextReturnCheck = Date().addingTimeInterval(5)
        if isLoggedOut("codex") && Widget.codexSignedIn() { comeBack("codex") }
        if isLoggedOut("claude") {
            DispatchQueue.global().async {
                let token = Widget.readClaudeAuth().token ?? ""
                if !token.isEmpty { DispatchQueue.main.async { if self.isLoggedOut("claude") { self.comeBack("claude") } } }
            }
        }
        if isLoggedOut("agy") && !agyFetching && (now || Date() >= agyNextFetch) { fetchAgy(probe: true) }
    }

    func comeBack(_ key: String) {
        setLoggedOut(key, false)
        switch key {
        case "claude": s.showClaude = true; loggedOut = false
        case "agy": s.showAgy = true
        default: s.showCodex = true
        }
        saveSettings()
        lastIconKey = nil
        if key == "claude" { fetch() } else if key == "codex" { fetchCodex() }
        if s.notify { Notify.post(Widget.serviceName(key), "Вход найден — лимиты снова в виджете.", sound: false) }
        updateView()
    }
}
