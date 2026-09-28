// Другие ИИ, кроме Claude Code, Antigravity и Codex: появляются в виджете сами, как только на этом Mac
// есть вход в них, и пропадают, если входа нет. У каждого свой цвет.
// Gemini CLI: вход из ~/.gemini/oauth_creds.json, лимиты — тот же запрос, что /stats в самом Gemini CLI.
// GitHub Copilot: вход Copilot CLI (связка ключей или ~/.copilot), плагина Copilot или gh; месячный лимит премиум-запросов.
// Cursor: вход из базы Cursor (state.vscdb), расход за текущий месяц подписки.
// Входы только читаем: обновлённый токен Gemini держим в памяти и в файл не пишем.

import AppKit

final class ExtraProvider {
    let key: String
    let name: String
    let color: NSColor
    var limits: [Limit] = []     // по возрастанию окна: сверху в строке меню — первый, снизу — последний
    var plan = ""
    var email: String?
    var status = ""
    var statusIsError = false
    var signedIn = false         // есть вход — раздел показываем
    var fetching = false
    var updatedAt: Date?
    var nextFetch = Date.distantPast

    init(key: String, name: String, color: NSColor) { self.key = key; self.name = name; self.color = color }

    var short: Limit? { limits.first }
    var long: Limit? { limits.count > 1 ? limits.last : nil }
}

// результат одного запроса: nil в signedIn — входа нет, раздел прячем
struct ExtraResult {
    var signedIn = true
    var limits: [Limit] = []
    var plan = ""
    var email: String?
    var problem: String?
    var retryAfter: TimeInterval?
}

enum Extra {
    static let all: [(key: String, name: String, color: String)] = [
        ("geminicli", "Gemini CLI", "#8AB4F8"),   // голубой
        ("copilot", "GitHub Copilot", "#BF5AF2"),  // фиолетовый
        ("cursor", "Cursor", "#40C8E0")            // бирюзовый
    ]

    static func fetch(_ key: String) -> ExtraResult {
        switch key {
        case "geminicli": return gemini()
        case "copilot": return copilot()
        case "cursor": return cursor()
        default: return ExtraResult(signedIn: false)
        }
    }

    // ---------- HTTP в фоне ----------
    static func http(_ url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> (Int, String?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var result: (Int, String?) = (0, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data.flatMap { String(data: $0, encoding: .utf8) })
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 35)
        return result
    }

    static func problem(_ service: String, _ code: Int) -> ExtraResult {
        var r = ExtraResult()
        if code == 401 || code == 403 { r.problem = "Вход \(service) устарел — откройте \(service), он обновит его сам" }
        else if code == 429 { r.problem = "Сервер просит подождать — повторю через 5 мин"; r.retryAfter = 300 }
        else { r.problem = code >= 300 ? "Ошибка сервера \(service) (\(code))" : "Нет соединения — повторю позже" }
        return r
    }

    static func capital(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }

    // ---------- Gemini CLI ----------
    // Открытый клиент OAuth самого Gemini CLI (он опубликован в его исходниках) — нужен, чтобы обновить истёкший вход.
    static let geminiClientId = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    static let geminiClientSecret = "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"
    static let codeAssist = "https://cloudcode-pa.googleapis.com/v1internal:"
    static var geminiToken: (token: String, until: Date)?
    static var geminiProject: String?

    static var geminiDir: String {
        let env = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"] ?? ""
        return (env.isEmpty ? Shell.home : env) + "/.gemini"
    }

    static func gemini() -> ExtraResult {
        guard let creds = J.file(geminiDir + "/oauth_creds.json") else { return ExtraResult(signedIn: false) }
        // вошли по API-ключу или через Vertex — лимитов подписки нет
        if let type = J.string(((J.file(geminiDir + "/settings.json")?["security"] as? JSON)?["auth"] as? JSON)?["selectedType"]),
           !type.isEmpty, type != "oauth-personal" { return ExtraResult(signedIn: false) }
        var token = J.string(creds["access_token"]) ?? ""
        let expiry = J.double(creds["expiry_date"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        if expiry < Date().addingTimeInterval(60) {
            if let t = geminiToken, t.until > Date().addingTimeInterval(60) { token = t.token }
            else {
                guard let refresh = J.string(creds["refresh_token"]), !refresh.isEmpty else { return ExtraResult(signedIn: false) }
                let form = ["client_id": geminiClientId, "client_secret": geminiClientSecret, "refresh_token": refresh, "grant_type": "refresh_token"]
                    .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
                let (code, text) = http("https://oauth2.googleapis.com/token", method: "POST",
                                        headers: ["Content-Type": "application/x-www-form-urlencoded"], body: form.data(using: .utf8))
                guard (200..<300).contains(code), let d = J.obj(text), let t = J.string(d["access_token"]) else {
                    var r = code == 400 || code == 401 ? ExtraResult() : problem("Gemini CLI", code)
                    if code == 400 || code == 401 { r.problem = "Вход Gemini CLI устарел — запустите gemini и войдите снова" }
                    return r
                }
                token = t
                geminiToken = (t, Date().addingTimeInterval(J.double(d["expires_in"]) ?? 3000))
            }
        }
        let headers = ["Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "GeminiCLI AiLimitWidget/1.0"]
        var r = ExtraResult()
        r.email = J.string(Widget.jwtClaims(J.string(creds["id_token"]))?["email"])
        // проект и тариф — один раз, как при запуске Gemini CLI
        let meta = #"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
        let (lc, lt) = http(codeAssist + "loadCodeAssist", method: "POST", headers: headers, body: meta.data(using: .utf8))
        guard (200..<300).contains(lc), let load = J.obj(lt) else { return problem("Gemini CLI", lc) }
        let tier = (load["paidTier"] as? JSON) ?? (load["currentTier"] as? JSON)
        let tierName = J.string(tier?["name"]) ?? J.string(tier?["id"]) ?? ""
        r.plan = tierName.replacingOccurrences(of: "Gemini Code Assist ", with: "")
        let project = J.string(load["cloudaicompanionProject"]) ?? J.string((load["cloudaicompanionProject"] as? JSON)?["id"]) ?? geminiProject
        geminiProject = project
        var q: [String: Any] = [:]
        if let p = project { q["project"] = p }
        let (qc, qt) = http(codeAssist + "retrieveUserQuota", method: "POST", headers: headers, body: try? JSONSerialization.data(withJSONObject: q))
        guard (200..<300).contains(qc), let quota = J.obj(qt) else { return problem("Gemini CLI", qc) }
        // по модели — остаток запросов на сутки; показываем Pro и Flash, остальные модели делят те же лимиты
        var byModel: [String: Limit] = [:]
        for b in (quota["buckets"] as? [JSON]) ?? [] {
            guard let model = J.string(b["modelId"]), let left = J.double(b["remainingFraction"]) else { continue }
            if model.contains("lite") || model.contains("embedding") { continue }
            let used = max(0, min(100, (1 - left) * 100))
            let at = Fmt.iso(b["resetTime"])
            let title = model.contains("pro") ? "Сутки · Pro" : model.contains("flash") ? "Сутки · Flash" : "Сутки · " + model
            if let old = byModel[title], old.percent >= used { continue }
            byModel[title] = Limit(key: "geminicli-" + title, title: title, percent: used, resetsAt: at, windowSeconds: 86400)
        }
        r.limits = byModel.values.sorted { $0.percent > $1.percent }
        if r.limits.isEmpty { r.problem = "Сервер не сообщил лимиты" }
        return r
    }

    // ---------- GitHub Copilot ----------
    static var copilotDirs: [String] {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
        return [Shell.home + "/.copilot", (env.isEmpty ? Shell.home + "/.config" : env) + "/github-copilot"]
    }

    // вход: Copilot CLI (связка ключей или его config.json), плагин Copilot (apps.json / hosts.json), затем gh
    static func copilotToken() -> String? {
        let kc = Proc.run("/usr/bin/security", ["find-generic-password", "-s", "copilot-cli", "-w"], timeout: 10)
        if let t = kc.output?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.contains(" ") { return t }
        for dir in copilotDirs {
            for f in ["config.json", "apps.json", "hosts.json"] {
                guard let d = J.file(dir + "/" + f) else { continue }
                if let found = firstToken(d) { return found }
            }
        }
        if let gh = Shell.find("gh", extra: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]) {
            let out = Proc.run(gh, ["auth", "token"], timeout: 10).output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if out.hasPrefix("gh") { return out }
        }
        return nil
    }

    // токены GitHub начинаются с gho_ / ghu_ / github_pat_ — ищем по всему файлу, где бы он ни лежал
    static func firstToken(_ v: Any) -> String? {
        if let s = v as? String { return s.hasPrefix("gho_") || s.hasPrefix("ghu_") || s.hasPrefix("github_pat_") ? s : nil }
        if let d = v as? JSON {
            for key in ["oauth_token", "token", "copilot_tokens"] { if let x = d[key], let t = firstToken(x) { return t } }
            for (_, x) in d { if let t = firstToken(x) { return t } }
        }
        if let a = v as? [Any] { for x in a { if let t = firstToken(x) { return t } } }
        return nil
    }

    static func copilot() -> ExtraResult {
        let hasApp = copilotDirs.contains { FileManager.default.fileExists(atPath: $0) }
        guard hasApp, let token = copilotToken() else { return ExtraResult(signedIn: false) }
        let (code, text) = http("https://api.github.com/copilot_internal/user", headers: [
            "Authorization": "token " + token, "Accept": "application/json",
            "Editor-Version": "vscode/1.99.0", "Editor-Plugin-Version": "copilot-chat/0.26.0",
            "User-Agent": "GitHubCopilotChat/0.26.0", "X-Github-Api-Version": "2025-04-01"])
        if code == 404 { return ExtraResult(signedIn: false) }   // у аккаунта нет Copilot
        guard (200..<300).contains(code), let d = J.obj(text) else { return problem("Copilot", code) }
        var r = ExtraResult()
        r.plan = capital((J.string(d["copilot_plan"]) ?? J.string(d["access_type_sku"]) ?? "").replacingOccurrences(of: "_", with: " "))
        r.email = J.string(d["login"])
        let resetAt = Fmt.iso(d["quota_reset_date_utc"]) ?? day(J.string(d["quota_reset_date"]) ?? J.string(d["limited_user_reset_date"]))
        let month: Int64 = 30 * 86400
        let names = ["premium_interactions": "Премиум-запросы · месяц", "chat": "Чат · месяц", "completions": "Дополнения · месяц"]
        if let snaps = d["quota_snapshots"] as? JSON {
            for key in ["premium_interactions", "chat", "completions"] {
                guard let s = snaps[key] as? JSON, J.bool(s["unlimited"]) != true else { continue }
                let left = J.double(s["percent_remaining"]) ?? {
                    guard let e = J.double(s["entitlement"]), e > 0, let rem = J.double(s["remaining"]) else { return nil }
                    return rem / e * 100
                }()
                guard let l = left else { continue }
                r.limits.append(Limit(key: "copilot-" + key, title: names[key]!, percent: max(0, min(100, 100 - l)), resetsAt: resetAt, windowSeconds: month))
            }
        } else if let left = d["limited_user_quotas"] as? JSON, let total = d["monthly_quotas"] as? JSON {
            // бесплатный Copilot: сколько осталось из месячной нормы
            for key in ["chat", "completions"] {
                guard let t = J.double(total[key]), t > 0, let rem = J.double(left[key]) else { continue }
                r.limits.append(Limit(key: "copilot-" + key, title: names[key]!, percent: max(0, min(100, (t - rem) / t * 100)), resetsAt: resetAt, windowSeconds: month))
            }
        }
        if r.limits.isEmpty { r.problem = "Без ограничений по тарифу" }
        return r
    }

    static func day(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    // ---------- Cursor ----------
    static var cursorDb: String { Shell.home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb" }

    static func cursorValue(_ key: String) -> String? {
        let out = Proc.run("/usr/bin/sqlite3", ["-readonly", cursorDb, "SELECT value FROM ItemTable WHERE key='\(key)'"], timeout: 10).output?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    static func cursor() -> ExtraResult {
        guard FileManager.default.fileExists(atPath: cursorDb), let token = cursorValue("cursorAuth/accessToken") else { return ExtraResult(signedIn: false) }
        // сайт Cursor узнаёт пользователя по cookie «id::токен»; id — в самом токене (sub = «auth0|user_…»)
        let sub = J.string(Widget.jwtClaims(token)?["sub"]) ?? ""
        let user = sub.split(separator: "|").last.map(String.init) ?? sub
        let headers = ["Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)", "Accept": "application/json",
                       "Origin": "https://cursor.com", "User-Agent": "Mozilla/5.0 AiLimitWidget/1.0"]
        let (code, text) = http("https://cursor.com/api/usage-summary", headers: headers)
        guard (200..<300).contains(code), let d = J.obj(text) else { return problem("Cursor", code) }
        var r = ExtraResult()
        r.email = cursorValue("cursorAuth/cachedEmail")
        r.plan = capital(J.string(d["membershipType"]) ?? cursorValue("cursorAuth/stripeMembershipType") ?? "")
        let end = Fmt.iso(d["billingCycleEnd"])
        let start = Fmt.iso(d["billingCycleStart"])
        let secs = Int64(max(86400, (end?.timeIntervalSince(start ?? Date()) ?? 30 * 86400)))
        let individual = d["individualUsage"] as? JSON
        if let plan = individual?["plan"] as? JSON {
            let pct = J.double(plan["totalPercentUsed"]) ?? {
                guard let used = J.double(plan["used"]), let limit = J.double(plan["limit"]), limit > 0 else { return nil }
                return used / limit * 100
            }()
            if let p = pct { r.limits.append(Limit(key: "cursor-plan", title: "Тариф · месяц", percent: max(0, min(100, p)), resetsAt: end, windowSeconds: secs)) }
        }
        if let od = individual?["onDemand"] as? JSON, J.bool(od["enabled"]) == true,
           let used = J.double(od["used"]), let limit = J.double(od["limit"]), limit > 0 {
            r.limits.append(Limit(key: "cursor-ondemand", title: "Сверх тарифа · месяц", percent: max(0, min(100, used / limit * 100)), resetsAt: end, windowSeconds: secs))
        }
        if r.limits.isEmpty { r.problem = "Сервер не сообщил лимиты" }
        return r
    }
}
