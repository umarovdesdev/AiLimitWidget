// Другие ИИ, кроме Claude Code, Antigravity и Codex, а также дополнительные аккаунты всех ИИ.
// Встроенные ИИ появляются в виджете сами, как только на этом Mac есть вход в них, и пропадают, если входа нет.
// Gemini CLI: вход из ~/.gemini/oauth_creds.json, лимиты — тот же запрос, что /stats в самом Gemini CLI.
// GitHub Copilot: вход Copilot CLI (связка ключей или ~/.copilot), плагина Copilot или gh; месячный лимит премиум-запросов.
// Cursor: вход из базы Cursor (state.vscdb), расход за текущий месяц подписки.
// Любой другой ИИ — файлом <имя>.json в папке providers (см. ниже), без пересборки виджета.
// Дополнительные аккаунты: отдельные папки в ~/Library/Application Support/AiLimitWidget/accounts/<ai>/<n>
// (CLAUDE_CONFIG_DIR, CODEX_HOME, GEMINI_CLI_HOME или свой блок "accounts"), а для Antigravity — записи
// связки ключей agy-account:<почта>, общие со скиллом ace.

import AppKit
import CryptoKit

final class ExtraProvider {
    let key: String
    var name: String
    let color: NSColor
    var limits: [Limit] = []     // по возрастанию окна: сверху в строке меню — первый, снизу — последний
    var plan = ""
    var email: String?
    var status = ""
    var longKey: String?         // лимит для нижней строки в строке меню (если не последний)
    var groups: [AgyGroup]?      // Antigravity: группы — рисуем как в основном разделе
    var statusIsError = false
    var signedIn = false         // есть вход — раздел показываем
    var fetching = false
    var updatedAt: Date?
    var nextFetch = Date.distantPast

    init(key: String, name: String, color: NSColor) { self.key = key; self.name = name; self.color = color }

    var short: Limit? { limits.first }
    var long: Limit? {
        if let lk = longKey, let l = limits.first(where: { $0.key == lk }) { return l }
        return limits.count > 1 ? limits.last : nil
    }
}

// результат одного запроса: signedIn = false — входа нет, раздел прячем
struct ExtraResult {
    var signedIn = true
    var confirmed = false
    var limits: [Limit] = []
    var plan = ""
    var email: String?
    var problem: String?
    var longKey: String?
    var retryAfter: TimeInterval?
    var groups: [AgyGroup]?      // Antigravity: группы моделей (5 часов + неделя рядом)
    var busy = false             // вход занят (Antigravity: идёт задача ace или вход в новый аккаунт) — данные не трогаем, повторим через минуту
}

// описание того, как добавить дополнительный аккаунт ИИ (переменная окружения для папки и команда входа)
struct AccountSpec {
    let env: String
    let login: String
}

enum Extra {
    // встроенные ИИ; к ним добавляются описания из папки providers и дополнительные аккаунты (scanProviders).
    // Меняется только в основном потоке.
    static var all: [(key: String, name: String, color: String)] = [
        ("geminicli", "Gemini CLI", "#8AB4F8"),   // голубой
        ("copilot", "GitHub Copilot", "#BF5AF2"),  // фиолетовый
        ("cursor", "Cursor", "#40C8E0")            // бирюзовый
    ]

    // ---------- ИИ из папки providers и дополнительные аккаунты ----------
    // ~/Library/Application Support/AiLimitWidget/providers/<имя>.json: { "name": "Grok", "color": "#RRGGBB" (можно не указывать),
    //   "command": "python3", "args": "~/scripts/grok.py --config {account}", "timeout": 30,
    //   "accounts": { "env": "GROK_HOME", "login": "grok login" } }
    // Команда печатает JSON: { "signed_in": true, "plan": "Pro", "email": "…", "problem": null,
    //   "limits": [ { "title": "Неделя", "percent": 12.5, "resets_at": "2026-10-20T10:00:00Z", "window_seconds": 604800 } ] }
    // percent — сколько израсходовано (0…100); вместо него можно remaining — сколько осталось (0…100).
    // Новый файл подхватывается на ходу: ИИ сам появляется в панели, в «Показывать» и в строке меню.
    private static var providers: [String: JSON] = [:]
    static let builtinAccounts: [String: AccountSpec] = [
        "claude": AccountSpec(env: "CLAUDE_CONFIG_DIR", login: "claude auth login"),
        "codex": AccountSpec(env: "CODEX_HOME", login: "codex login"),
        "geminicli": AccountSpec(env: "GEMINI_CLI_HOME", login: "gemini")
    ]
    private static var accountSpecs: [String: AccountSpec] = builtinAccounts
    // дополнительные аккаунты («acc-<svc>-<id>» → [svc, папка или почта, номер/id])
    private static var accounts: [String: [String]] = [:]
    private static var customNames: [String: String] = [:]
    private static var defaultLabels: [String: String] = [:]
    private static var mainProviderEmails: [String: String] = [:]
    private static var providerAccountEmails: [String: String] = [:]
    private static var probingDirs = Set<String>()
    private static let lock = NSLock()
    static let autoColors = ["#FF6482", "#66D4CF", "#A8E05F", "#AC8E68", "#DA8FFF", "#FFB8A0"]
    static let expiredAccountText = "Вход устарел — добавьте аккаунт заново"
    static var mainAgyEmail: String?
    static var lastDuplicateSvc: String?
    static var waitingDir: String?

    static var providersDir: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return support + "/AiLimitWidget/providers"
    }

    static var accountsDir: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return support + "/AiLimitWidget/accounts"
    }

    static func isBuiltinFolderSvc(_ svc: String) -> Bool {
        svc == "claude" || svc == "codex" || svc == "geminicli"
    }

    static func accountSpecFor(_ svc: String?) -> AccountSpec? {
        guard let svc = svc else { return nil }
        lock.lock(); defer { lock.unlock() }
        return accountSpecs[svc]
    }

    // список всех ИИ, у которых есть описание аккаунтов (встроенные + провайдеры с "accounts")
    static func accountAis(_ agyAvail: Bool) -> [(key: String, name: String, color: String)] {
        var list: [(key: String, name: String, color: String)] = [
            ("claude", "Claude Code", "#D97757"),
            ("codex", "Codex", "#FFD60A")
        ]
        if agyAvail { list.append(("agy", "Antigravity", "#34C759")) }
        list.append(("geminicli", "Gemini CLI", "#8AB4F8"))
        for e in all where e.key.hasPrefix("p-") {
            lock.lock()
            let has = accountSpecs[e.key] != nil
            lock.unlock()
            if has { list.append(e) }
        }
        return list
    }

    static func aiName(_ svc: String) -> String {
        if svc == "claude" { return "Claude Code" }
        if svc == "codex" { return "Codex" }
        if svc == "agy" { return "Antigravity" }
        if svc == "geminicli" { return "Gemini CLI" }
        return all.first(where: { $0.key == svc || $0.key == "p-" + svc })?.name ?? svc
    }

    static func aiColor(_ svc: String) -> String {
        if svc == "claude" { return "#D97757" }
        if svc == "agy" { return "#34C759" }
        if svc == "codex" { return "#FFD60A" }
        if svc == "geminicli" { return "#8AB4F8" }
        return all.first(where: { $0.key == svc || $0.key == "p-" + svc })?.color ?? "#8AB4F8"
    }

    // цвет дополнительного аккаунта — цвет основного ИИ, осветлённый на ~45% к белому
    static func lighten(_ hex: String) -> String {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0
        let r = Int(Double((v >> 16) & 0xFF) + Double(255 - ((v >> 16) & 0xFF)) * 0.45)
        let g = Int(Double((v >> 8) & 0xFF) + Double(255 - ((v >> 8) & 0xFF)) * 0.45)
        let b = Int(Double(v & 0xFF) + Double(255 - (v & 0xFF)) * 0.45)
        return String(format: "#%02X%02X%02X", min(255, r), min(255, g), min(255, b))
    }

    static func credFile(_ svc: String, _ dir: String) -> String {
        if svc == "claude" { return dir + "/.credentials.json" }
        if svc == "codex" { return dir + "/auth.json" }
        return dir + "/.gemini/oauth_creds.json"
    }

    // Claude Code 2.x на macOS при заданном CLAUDE_CONFIG_DIR хранит вход в связке ключей под именем
    // «Claude Code-credentials-<первые 8 символов sha256 от NFC-пути папки>» или в <папка>/.credentials.json
    static func claudeKeychainService(_ dir: String) -> String {
        let norm = dir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(norm.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex
    }

    static func readClaudeCreds(_ dir: String) -> (json: JSON, fromKeychain: Bool)? {
        if let d = J.file(dir + "/.credentials.json"), d["claudeAiOauth"] != nil { return (d, false) }
        let svc = claudeKeychainService(dir)
        let r = Proc.run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"], timeout: 10)
        if let out = r.output?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty,
           let d = J.obj(out) ?? J.obj(Widget.hexDecode(out)), d["claudeAiOauth"] != nil {
            return (d, true)
        }
        return nil
    }

    static func hasCreds(_ svc: String, _ dir: String) -> Bool {
        let cred = credFile(svc, dir)
        if FileManager.default.fileExists(atPath: cred) { return true }
        if svc == "claude" && FileManager.default.fileExists(atPath: dir + "/.claude.json") {
            return readClaudeCreds(dir) != nil
        }
        return false
    }

    static func accountEmail(_ svc: String, _ dir: String) -> String? {
        if svc == "claude" {
            return J.string((J.file(dir + "/.claude.json")?["oauthAccount"] as? JSON)?["emailAddress"])
        }
        if svc == "codex" {
            return J.string(Widget.jwtClaims(J.string((J.file(dir + "/auth.json")?["tokens"] as? JSON)?["id_token"]))?["email"])
        }
        if svc == "geminicli" {
            return J.string(Widget.jwtClaims(J.string(J.file(dir + "/.gemini/oauth_creds.json")?["id_token"]))?["email"])
        }
        lock.lock(); defer { lock.unlock() }
        return providerAccountEmails[dir]
    }

    static func mainEmail(_ svc: String) -> String? {
        if svc == "claude" {
            return J.string(Widget.readAccount()?["emailAddress"])
        }
        if svc == "codex" {
            return J.string(Widget.jwtClaims(J.string((J.file(Widget.codexAuthPath)?["tokens"] as? JSON)?["id_token"]))?["email"])
        }
        if svc == "geminicli" {
            return J.string(Widget.jwtClaims(J.string(J.file(geminiDir + "/oauth_creds.json")?["id_token"]))?["email"])
        }
        lock.lock(); defer { lock.unlock() }
        return mainProviderEmails[svc]
    }

    static func cleanId(_ s: String?) -> String {
        var out = ""
        for ch in s ?? "" {
            if ch.isLetter || ch.isNumber { out.append(ch.lowercased()) } else { out.append("-") }
        }
        return out
    }

    static func accountSvc(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return accounts[key]?.first
    }

    static func accountPrefix(_ key: String) -> String? {
        lock.lock()
        let svc = accounts[key]?.first
        lock.unlock()
        return svc.map(aiName)
    }

    static func setCustomNames(_ names: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        customNames.removeAll()
        for (k, v) in names where !k.isEmpty && !v.isEmpty { customNames[k] = v }
    }

    static func getCustomName(_ key: String?) -> String? {
        guard let key = key else { return nil }
        lock.lock(); defer { lock.unlock() }
        return customNames[key]
    }

    static func getDefaultLabel(_ key: String?) -> String? {
        guard let key = key else { return nil }
        lock.lock(); defer { lock.unlock() }
        return defaultLabels[key]
    }

    static func accountTitle(_ key: String, _ fallbackLabel: String? = nil) -> String {
        guard let prefix = accountPrefix(key) else { return fallbackLabel ?? key }
        var def = fallbackLabel
        lock.lock()
        if let f = fallbackLabel, !f.isEmpty { defaultLabels[key] = f }
        else { def = defaultLabels[key] }
        let custom = customNames[key]
        lock.unlock()
        let suffix = (custom?.isEmpty == false) ? custom! : ((def?.isEmpty == false) ? def! : key)
        return prefix + " · " + suffix
    }

    // команда запуска CLI в терминале под папкой этого аккаунта (синтаксис sh/zsh на macOS)
    static func terminalCommand(_ key: String) -> String? {
        lock.lock()
        let info = accounts[key]
        lock.unlock()
        guard let info = info, info.count >= 2, info[0] != "agy" else { return nil }
        let svc = info[0], dir = info[1]
        guard let spec = accountSpecFor(svc), !spec.env.isEmpty,
              let exe = loginExe(svc, spec.login), !exe.isEmpty else { return nil }
        let qDir = dir.contains(" ") ? "\"\(dir)\"" : dir
        return "\(spec.env)=\(qDir) \(exe)"
    }

    static func loginExe(_ svc: String, _ login: String?) -> String? {
        if let login = login?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty {
            if login.hasPrefix("\"") {
                let rest = login.dropFirst()
                if let end = rest.firstIndex(of: "\"") { return String(login[...end]) }
            }
            if let sp = login.firstIndex(of: " ") { return String(login[..<sp]) }
            return login
        }
        lock.lock()
        let def = providers[svc]
        lock.unlock()
        return J.string(def?["command"])
    }

    // проверка папки, в которой сейчас ждём вход (вызывается из фонового потока раз в 5 с)
    static func checkWaitingFolder(_ svc: String, _ dir: String, _ num: Int) -> (ready: Bool, email: String?, duplicate: Bool) {
        var email: String?
        if isBuiltinFolderSvc(svc) {
            if !hasCreds(svc, dir) { return (false, nil, false) }
            email = accountEmail(svc, dir)
            let cred = credFile(svc, dir)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: cred)[.modificationDate] as? Date) ?? .distantPast
            if svc == "claude" && (email ?? "").isEmpty && mtime > Date().addingTimeInterval(-4) {
                return (false, nil, false)
            }
        } else {
            lock.lock()
            let def = providers[svc]
            lock.unlock()
            guard let def = def else { return (false, nil, false) }
            let r = provider("acc-\(svc)-\(num)", def, dir)
            if !r.confirmed { return (false, nil, false) }
            email = r.email
            if (mainEmail(svc) ?? "").isEmpty { _ = provider(svc, def, nil) }
        }
        if let e = email, !e.isEmpty, hasAccountEmail(svc, dir, e) {
            try? FileManager.default.removeItem(atPath: dir)
            if svc == "claude" {
                _ = Proc.run("/usr/bin/security", ["delete-generic-password", "-s", claudeKeychainService(dir)], timeout: 10)
            }
            return (true, e, true)
        }
        if !isBuiltinFolderSvc(svc) {
            lock.lock(); providerAccountEmails[dir] = email ?? ""; lock.unlock()
        }
        return (true, email, false)
    }

    static func hasAccountEmail(_ svc: String, _ excludeDir: String, _ email: String) -> Bool {
        if let main = mainEmail(svc), !main.isEmpty, main.caseInsensitiveCompare(email) == .orderedSame { return true }
        let fm = FileManager.default
        for sdir in serviceAccountDirs(svc) {
            guard let subdirs = try? fm.contentsOfDirectory(atPath: sdir) else { continue }
            for sub in subdirs {
                let d = sdir + "/" + sub
                if d.caseInsensitiveCompare(excludeDir) == .orderedSame { continue }
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: d, isDirectory: &isDir) || !isDir.boolValue { continue }
                if isBuiltinFolderSvc(svc) && !hasCreds(svc, d) { continue }
                if let e = accountEmail(svc, d), !e.isEmpty, e.caseInsensitiveCompare(email) == .orderedSame { return true }
            }
        }
        return false
    }

    static func serviceAccountDirs(_ svc: String) -> [String] {
        var dirs = [accountsDir + "/" + svc]
        if svc.hasPrefix("p-") { dirs.append(accountsDir + "/" + String(svc.dropFirst(2))) }
        return dirs
    }

    static func removeAccount(_ key: String) -> Bool {
        lock.lock()
        let info = accounts[key]
        lock.unlock()
        guard let info = info, info.count >= 2 else { return false }
        let svc = info[0], target = info[1]
        if svc == "agy" {
            AgyAccounts.remove(target)
        } else {
            if svc == "claude" {
                _ = Proc.run("/usr/bin/security", ["delete-generic-password", "-s", claudeKeychainService(target)], timeout: 10)
            }
            if FileManager.default.fileExists(atPath: target) {
                do { try FileManager.default.removeItem(atPath: target) } catch { return false }
            }
            lock.lock(); providerAccountEmails.removeValue(forKey: target); lock.unlock()
        }
        lock.lock()
        accounts.removeValue(forKey: key)
        defaultLabels.removeValue(forKey: key)
        lock.unlock()
        all.removeAll { $0.key == key }
        return true
    }

    // вызывается из основного потока: возвращает только что найденные ИИ и дополнительные аккаунты
    static func scanProviders() -> [(key: String, name: String, color: String)] {
        var found: [(key: String, name: String, color: String)] = []
        let fm = FileManager.default
        try? fm.createDirectory(atPath: providersDir, withIntermediateDirectories: true)
        var seenProviders = Set<String>()
        let files = ((try? fm.contentsOfDirectory(atPath: providersDir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".json") }.sorted { $0.lowercased() < $1.lowercased() }
        for f in files {
            guard let d = J.file(providersDir + "/" + f), let name = J.string(d["name"]), !name.isEmpty,
                  let cmd = J.string(d["command"]), !cmd.isEmpty else { continue }
            let key = "p-" + String(f.dropLast(5)).lowercased().replacingOccurrences(of: ",", with: "-").replacingOccurrences(of: " ", with: "-")
            seenProviders.insert(key)
            let acc = d["accounts"] as? JSON
            let accEnv = J.string(acc?["env"]) ?? "", accLogin = J.string(acc?["login"]) ?? ""
            lock.lock()
            providers[key] = d   // изменённый файл действует со следующего обновления
            if !accEnv.isEmpty || !accLogin.isEmpty {
                accountSpecs[key] = AccountSpec(env: accEnv, login: accLogin)
            } else {
                accountSpecs.removeValue(forKey: key)
            }
            lock.unlock()
            if all.contains(where: { $0.key == key }) { continue }
            var color = J.string(d["color"]) ?? ""
            if color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil {
                color = autoColors.first { c in !all.contains { $0.color.caseInsensitiveCompare(c) == .orderedSame } }
                    ?? autoColors[found.count % autoColors.count]
            }
            let entry = (key: key, name: name, color: color)
            all.append(entry)
            found.append(entry)
        }
        lock.lock()
        for k in accountSpecs.keys.filter({ $0.hasPrefix("p-") && !seenProviders.contains($0) }) {
            accountSpecs.removeValue(forKey: k)
        }
        lock.unlock()
        scanAccounts(&found)
        return found
    }

    static func scanAccounts(_ found: inout [(key: String, name: String, color: String)]) {
        var active = Set<String>()
        let fm = FileManager.default
        lock.lock()
        let svcs = Array(accountSpecs.keys)
        lock.unlock()
        for svc in svcs {
            var seen = Set<String>()
            if let main = mainEmail(svc), !main.isEmpty { seen.insert(main.lowercased()) }
            var dirs: [(Int, String)] = []
            for sdir in serviceAccountDirs(svc) {
                guard let subdirs = try? fm.contentsOfDirectory(atPath: sdir) else { continue }
                for sub in subdirs {
                    let d = sdir + "/" + sub
                    var isDir: ObjCBool = false
                    if !fm.fileExists(atPath: d, isDirectory: &isDir) || !isDir.boolValue { continue }
                    if let n = Int(sub), n > 0, !dirs.contains(where: { $0.0 == n }) {
                        dirs.append((n, d))
                    }
                }
            }
            for (n, dir) in dirs.sorted(by: { $0.0 < $1.0 }) {
                if let w = waitingDir, !w.isEmpty, dir.caseInsensitiveCompare(w) == .orderedSame { continue }
                var email: String?
                if isBuiltinFolderSvc(svc) {
                    if !hasCreds(svc, dir) {
                        // пустая папка без файла входа старше 30 минут — удаляем; с содержимым не трогаем
                        let attrs = try? fm.attributesOfItem(atPath: dir)
                        let ctime = (attrs?[.creationDate] as? Date) ?? .distantFuture
                        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantFuture
                        let cutoff = Date().addingTimeInterval(-1800)
                        if ctime < cutoff && mtime < cutoff && ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
                            try? fm.removeItem(atPath: dir)
                        }
                        continue
                    }
                    email = accountEmail(svc, dir)
                    let cred = credFile(svc, dir)
                    let mtime = (try? fm.attributesOfItem(atPath: cred)[.modificationDate] as? Date) ?? .distantPast
                    if svc == "claude" && (email ?? "").isEmpty && mtime > Date().addingTimeInterval(-4) {
                        continue   // .claude.json дописывается следом за .credentials.json
                    }
                } else {
                    lock.lock()
                    let cached = providerAccountEmails[dir]
                    lock.unlock()
                    guard let cachedEmail = cached else {
                        probeProviderAccount(svc, dir, n)
                        continue
                    }
                    email = cachedEmail
                }
                if let e = email, !e.isEmpty, !seen.insert(e.lowercased()).inserted {
                    // только что добавили тот же аккаунт — папку убираем; старую не трогаем
                    let ctime = (try? fm.attributesOfItem(atPath: dir)[.creationDate] as? Date) ?? .distantPast
                    if ctime > Date().addingTimeInterval(-3600) {
                        try? fm.removeItem(atPath: dir)
                        if svc == "claude" {
                            _ = Proc.run("/usr/bin/security", ["delete-generic-password", "-s", claudeKeychainService(dir)], timeout: 10)
                        }
                        lock.lock(); providerAccountEmails.removeValue(forKey: dir); lock.unlock()
                        lastDuplicateSvc = svc
                    }
                    continue
                }
                let key = "acc-\(svc)-\(n)"
                let label = (email?.isEmpty == false) ? email! : "аккаунт \(n)"
                registerAccount(key, label, lighten(aiColor(svc)), [svc, dir, "\(n)"], &active, &found)
            }
        }
        let live = AgyAccounts.isAdding ? mainAgyEmail : (AgyAccounts.liveEmail() ?? mainAgyEmail)
        for email in AgyAccounts.saved() {
            if email.isEmpty || (live != nil && email.caseInsensitiveCompare(live!) == .orderedSame) { continue }
            let id = cleanId(email)
            let key = "acc-agy-" + id
            registerAccount(key, email, lighten(aiColor("agy")), ["agy", email, id], &active, &found)
        }
        lock.lock()
        for k in accounts.keys.filter({ !active.contains($0) }) { accounts.removeValue(forKey: k) }
        lock.unlock()
        all.removeAll { $0.key.hasPrefix("acc-") && !active.contains($0.key) }
    }

    static func probeProviderAccount(_ svc: String, _ dir: String, _ n: Int) {
        lock.lock()
        let inserted = probingDirs.insert(dir).inserted
        lock.unlock()
        if !inserted { return }
        DispatchQueue.global().async {
            defer {
                lock.lock(); probingDirs.remove(dir); lock.unlock()
            }
            lock.lock()
            let def = providers[svc]
            lock.unlock()
            guard let def = def else { return }
            let r = provider("acc-\(svc)-\(n)", def, dir)
            if r.confirmed {
                lock.lock(); providerAccountEmails[dir] = r.email ?? ""; lock.unlock()
            } else {
                let fm = FileManager.default
                let attrs = try? fm.attributesOfItem(atPath: dir)
                let ctime = (attrs?[.creationDate] as? Date) ?? .distantFuture
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantFuture
                let cutoff = Date().addingTimeInterval(-1800)
                if ctime < cutoff && mtime < cutoff && ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
                    try? fm.removeItem(atPath: dir)
                }
            }
        }
    }

    static func registerAccount(_ key: String, _ defaultLabel: String, _ color: String, _ info: [String],
                                _ active: inout Set<String>, _ found: inout [(key: String, name: String, color: String)]) {
        active.insert(key)
        lock.lock(); accounts[key] = info; lock.unlock()
        let name = accountTitle(key, defaultLabel)
        if let idx = all.firstIndex(where: { $0.key == key }) {
            all[idx].name = name
            return
        }
        let entry = (key: key, name: name, color: color)
        all.append(entry)
        found.append(entry)
    }

    // «args» — строка (как в оболочке) или массив; команда ищется в PATH пользователя;
    // {account} заменяется на путь к папке аккаунта (для основного аккаунта — пустой)
    static func provider(_ key: String, _ def: JSON, _ accountDir: String? = nil) -> ExtraResult {
        let name = J.string(def["name"]) ?? key
        let baseKey = accountSvc(key) ?? key
        let file = (baseKey.hasPrefix("p-") ? String(baseKey.dropFirst(2)) : baseKey) + ".json"
        let command = J.string(def["command"]) ?? ""
        var line = command.contains("/") ? quote(command) : (Shell.find(command).map(quote) ?? command)
        let accReplacement = (accountDir?.isEmpty == false) ? quote(accountDir!) : ""
        if let list = def["args"] as? [Any] {
            let parts = list.compactMap(J.string).compactMap { arg -> String? in
                if arg == "{account}" { return accReplacement.isEmpty ? nil : accReplacement }
                let replaced = arg.replacingOccurrences(of: "{account}", with: accountDir ?? "")
                return replaced.isEmpty ? nil : quote(replaced)
            }
            if !parts.isEmpty { line += " " + parts.joined(separator: " ") }
        } else if let a = J.string(def["args"]), !a.isEmpty {
            let replaced = a.replacingOccurrences(of: "{account}", with: accReplacement).trimmingCharacters(in: .whitespaces)
            if !replaced.isEmpty { line += " " + replaced }
        }
        var env = Shell.environment
        if let dir = accountDir, !dir.isEmpty,
           let envVar = J.string((def["accounts"] as? JSON)?["env"]), !envVar.isEmpty {
            env[envVar] = dir
        }
        let timeout = max(5, min(300, J.double(def["timeout"]) ?? 30))
        let out = Proc.run("/bin/sh", ["-c", line], timeout: timeout, env: env)
        if out.missing { return ExtraResult(problem: name + ": команда не запускается — проверьте command в " + file) }
        let text = out.output?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = J.obj(text) ?? J.embedded(text) else { return ExtraResult(problem: name + " не ответил или ответ не JSON") }
        let signedIn = J.bool(d["signed_in"])
        if signedIn == false || (accountDir != nil && signedIn != true) { return ExtraResult(signedIn: false) }
        var r = ExtraResult(confirmed: signedIn == true, plan: J.string(d["plan"]) ?? "", email: J.string(d["email"]), problem: J.string(d["problem"]))
        if accountDir == nil, let e = r.email, !e.isEmpty {
            lock.lock(); mainProviderEmails[key] = e; lock.unlock()
        } else if let dir = accountDir, let e = r.email, !e.isEmpty {
            lock.lock(); providerAccountEmails[dir] = e; lock.unlock()
        }
        var list: [Limit] = []
        for l in (d["limits"] as? [JSON]) ?? [] {
            guard let used = J.double(l["percent"]) ?? J.double(l["remaining"]).map({ 100 - $0 }) else { continue }
            let at = Fmt.iso(l["resets_at"]) ?? J.double(l["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            list.append(Limit(key: key + "-\(list.count)", title: J.string(l["title"]) ?? "Лимит", percent: max(0, min(100, used)),
                              resetsAt: at, windowSeconds: Int64(J.double(l["window_seconds"]) ?? 0)))
        }
        r.limits = list.sorted { $0.windowSeconds < $1.windowSeconds }   // в строке меню сверху — самое короткое окно, снизу — самое длинное
        if r.limits.isEmpty && r.problem == nil { r.problem = "Сервер не сообщил лимиты" }
        return r
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func fetch(_ key: String) -> ExtraResult {
        if key.hasPrefix("acc-") { return account(key) }
        switch key {
        case "geminicli": return gemini()
        case "copilot": return copilot()
        case "cursor": return cursor()
        default:
            lock.lock()
            let def = providers[key]
            lock.unlock()
            return def.map { provider(key, $0) } ?? ExtraResult(signedIn: false)
        }
    }

    // ---------- дополнительные аккаунты (Claude Code, Codex, Gemini CLI, Antigravity, провайдеры) ----------
    static func account(_ key: String) -> ExtraResult {
        lock.lock()
        let info = accounts[key]
        lock.unlock()
        guard let info = info, info.count >= 2 else { return ExtraResult(signedIn: false) }
        let svc = info[0], target = info[1]
        if svc == "claude" { return claudeExtra(key, target) }
        if svc == "codex" { return codexExtra(key, target, retried: false) }
        if svc == "geminicli" { return gemini(target, key) }
        if svc == "agy" { return agyExtra(key, target) }
        lock.lock()
        let def = providers[svc]
        lock.unlock()
        return def.map { provider(key, $0, target) } ?? ExtraResult(signedIn: false)
    }

    static func claudeExtra(_ key: String, _ dir: String) -> ExtraResult {
        let credPath = dir + "/.credentials.json"
        guard let creds = readClaudeCreds(dir), var oauth = creds.json["claudeAiOauth"] as? JSON else {
            return ExtraResult(signedIn: false)
        }
        var d = creds.json
        let email = accountEmail("claude", dir)
        let plan = Widget.planName(J.string(oauth["subscriptionType"]), J.string(oauth["rateLimitTier"]))
        var token = J.string(oauth["accessToken"]) ?? ""
        let exp = J.double(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        if token.isEmpty || exp < Date().addingTimeInterval(60) {
            guard let refresh = J.string(oauth["refreshToken"]), !refresh.isEmpty else {
                return ExtraResult(plan: plan, email: email, problem: expiredAccountText)
            }
            let scope = ((oauth["scopes"] as? [Any])?.compactMap(J.string).filter { !$0.isEmpty } ?? []).joined(separator: " ")
            let bodyObj: [String: Any] = [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                "scope": scope
            ]
            let body = try? JSONSerialization.data(withJSONObject: bodyObj)
            let (rc, rt) = http("https://platform.claude.com/v1/oauth/token", method: "POST", headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "claude-code/2.0 AiLimitWidget/1.0"
            ], body: body)
            let rd = (200..<300).contains(rc) ? J.obj(rt) : nil
            guard let newToken = J.string(rd?["access_token"]), !newToken.isEmpty else {
                return ExtraResult(plan: plan, email: email, problem: rc == 0 ? "Нет соединения — повторю позже" : expiredAccountText)
            }
            token = newToken
            oauth["accessToken"] = token
            if let nr = J.string(rd?["refresh_token"]), !nr.isEmpty { oauth["refreshToken"] = nr }
            if let expIn = J.double(rd?["expires_in"]) {
                oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + expIn) * 1000)
            }
            d["claudeAiOauth"] = oauth
            J.write(d, credPath)
        }
        let (code, text) = http(Widget.usageUrl, headers: [
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.0 AiLimitWidget/1.0"
        ])
        guard (200..<300).contains(code), let u = J.obj(text) else {
            if code == 401 || code == 403 { return ExtraResult(plan: plan, email: email, problem: expiredAccountText) }
            return problem("Claude Code", code)
        }
        var r = ExtraResult(plan: plan, email: email)
        let s = Widget.readLimit(u, "five_hour", "Сессия (5 ч)") ?? Limit(key: "five_hour", title: "Сессия (5 ч)", percent: 0, resetsAt: nil)
        s.key = key + "-" + s.key
        s.windowSeconds = 18000
        r.limits.append(s)
        let known = Widget.weeklyKeys.map { $0.0 }
        let keys = known + u.keys.filter { $0 != "five_hour" && $0 != "extra_usage" && !known.contains($0) }.sorted()
        for k in keys {
            guard let o = u[k] as? JSON, J.double(o["utilization"]) != nil,
                  let l = Widget.readLimit(u, k, Widget.limitTitle(k, o)) else { continue }
            l.key = key + "-" + k
            l.windowSeconds = 604800
            if r.longKey == nil { r.longKey = l.key }
            r.limits.append(l)
        }
        if let extra = u["extra_usage"] as? JSON, J.bool(extra["is_enabled"]) == true, let util = J.double(extra["utilization"]) {
            r.limits.append(Limit(key: key + "-extra", title: "Доп. кредиты (месяц)", percent: util, resetsAt: nil, windowSeconds: 30 * 86400))
        }
        return r
    }

    static func codexExtra(_ key: String, _ dir: String, retried: Bool) -> ExtraResult {
        let authPath = dir + "/auth.json"
        guard var d = J.file(authPath), var tokens = d["tokens"] as? JSON,
              let token = J.string(tokens["access_token"]), !token.isEmpty else {
            return ExtraResult(signedIn: false)
        }
        let accountId = J.string(tokens["account_id"]) ?? ""
        let email = J.string(Widget.jwtClaims(J.string(tokens["id_token"]))?["email"])
        var headers = [
            "Authorization": "Bearer " + token,
            "User-Agent": "codex_cli_rs AiLimitWidget/1.0",
            "originator": "codex_cli_rs",
            "Accept": "application/json"
        ]
        if !accountId.isEmpty { headers["ChatGPT-Account-Id"] = accountId }
        let (code, text) = http(Widget.codexUsageUrl, headers: headers)
        if code == 401 && !retried {
            guard let refresh = J.string(tokens["refresh_token"]), !refresh.isEmpty else {
                return ExtraResult(email: email, problem: expiredAccountText)
            }
            let bodyObj: [String: Any] = [
                "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "scope": "openid profile email"
            ]
            let body = try? JSONSerialization.data(withJSONObject: bodyObj)
            let (rc, rt) = http("https://auth.openai.com/oauth/token", method: "POST", headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "codex_cli_rs AiLimitWidget/1.0"
            ], body: body)
            let rd = (200..<300).contains(rc) ? J.obj(rt) : nil
            guard let na = J.string(rd?["access_token"]), !na.isEmpty else {
                return ExtraResult(email: email, problem: rc == 0 ? "Нет соединения — повторю позже" : expiredAccountText)
            }
            tokens["access_token"] = na
            if let ni = J.string(rd?["id_token"]), !ni.isEmpty { tokens["id_token"] = ni }
            if let nr = J.string(rd?["refresh_token"]), !nr.isEmpty { tokens["refresh_token"] = nr }
            d["tokens"] = tokens
            d["last_refresh"] = Fmt.isoString(Date())
            J.write(d, authPath)
            return codexExtra(key, dir, retried: true)
        }
        guard (200..<300).contains(code), let u = J.obj(text) else {
            if code == 401 || code == 403 { return ExtraResult(email: email, problem: expiredAccountText) }
            return problem("Codex", code)
        }
        var r = ExtraResult(plan: capital(J.string(u["plan_type"]) ?? ""), email: email)
        let rl = u["rate_limit"] as? JSON
        var list: [Limit] = []
        let windows = ["primary_window", "secondary_window"]
        for w in windows + (rl?.keys.filter { !windows.contains($0) }.sorted() ?? []) {
            guard let o = rl?[w] as? JSON, let used = J.double(o["used_percent"]) else { continue }
            let secs = Int64(J.double(o["limit_window_seconds"]) ?? 0)
            let at = J.double(o["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            list.append(Limit(key: key + "-" + w, title: Widget.windowTitle(secs), percent: max(0, min(100, used)), resetsAt: at, windowSeconds: secs))
        }
        r.limits = list.sorted { $0.windowSeconds < $1.windowSeconds }
        if r.limits.isEmpty { r.problem = "Сервер не сообщил лимиты" }
        return r
    }

    static func agyExtra(_ key: String, _ email: String) -> ExtraResult {
        if AgyAccounts.isAdding { return ExtraResult(busy: true) }
        let pair = AgyAccounts.use(email) { () -> (String?, String?) in
            let q = Widget.runAgy("/quota")
            return (q.output, q.output == nil ? nil : Widget.runAgy("/credits").output)
        }
        guard let (quota, credits) = pair else { return ExtraResult(busy: true) }
        guard let quota = quota, !quota.isEmpty else {
            return ExtraResult(email: email, problem: "Antigravity не ответил — повторю позже")
        }
        var problem: String?
        guard let groups = Widget.agyGroupsOf(quota, &problem) else {
            return ExtraResult(email: email, problem: problem == Widget.agyNoAuthText ? expiredAccountText : (problem ?? "Antigravity вернул ошибку"))
        }
        let cr = Widget.creditsOf(credits)
        var r = ExtraResult(plan: (cr ?? 0) > 0 ? "кредиты: \(Int(cr!.rounded()))" : "", email: email)
        for g in groups {
            if let s = g.session {
                s.key = key + "-" + s.key
                s.title = g.title + " · 5 ч"
                s.windowSeconds = 18000
                r.limits.append(s)
            }
            if let w = g.week {
                w.key = key + "-" + w.key
                w.title = g.title + " · неделя"
                w.windowSeconds = 604800
                if r.longKey == nil { r.longKey = w.key }
                r.limits.append(w)
            }
        }
        r.groups = groups
        if r.limits.isEmpty { r.problem = "Antigravity не сообщил лимиты" }
        return r
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

    static func gemini(_ homeDir: String? = nil, _ keyPrefix: String = "geminicli") -> ExtraResult {
        let extra = homeDir != nil
        let dir = extra ? (homeDir! + "/.gemini") : geminiDir
        let credPath = dir + "/oauth_creds.json"
        guard var creds = J.file(credPath) else { return ExtraResult(signedIn: false) }
        // вошли по API-ключу или через Vertex — лимитов подписки нет
        if let type = J.string(((J.file(dir + "/settings.json")?["security"] as? JSON)?["auth"] as? JSON)?["selectedType"]),
           !type.isEmpty, type != "oauth-personal" { return ExtraResult(signedIn: false) }
        var token = J.string(creds["access_token"]) ?? ""
        let expiry = J.double(creds["expiry_date"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        if expiry < Date().addingTimeInterval(60) {
            if !extra, let t = geminiToken, t.until > Date().addingTimeInterval(60) { token = t.token }
            else {
                guard let refresh = J.string(creds["refresh_token"]), !refresh.isEmpty else {
                    return extra ? ExtraResult(problem: expiredAccountText) : ExtraResult(signedIn: false)
                }
                let form = ["client_id": geminiClientId, "client_secret": geminiClientSecret, "refresh_token": refresh, "grant_type": "refresh_token"]
                    .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
                let (code, text) = http("https://oauth2.googleapis.com/token", method: "POST",
                                        headers: ["Content-Type": "application/x-www-form-urlencoded"], body: form.data(using: .utf8))
                guard (200..<300).contains(code), let d = J.obj(text), let t = J.string(d["access_token"]), !t.isEmpty else {
                    if extra { return ExtraResult(problem: code == 0 ? "Нет соединения — повторю позже" : expiredAccountText) }
                    var r = code == 400 || code == 401 ? ExtraResult() : problem("Gemini CLI", code)
                    if code == 400 || code == 401 { r.problem = "Вход Gemini CLI устарел — запустите gemini и войдите снова" }
                    return r
                }
                token = t
                if extra {
                    creds["access_token"] = t
                    if let nr = J.string(d["refresh_token"]), !nr.isEmpty { creds["refresh_token"] = nr }
                    if let ni = J.string(d["id_token"]), !ni.isEmpty { creds["id_token"] = ni }
                    let expIn = J.double(d["expires_in"]) ?? 3600
                    creds["expiry_date"] = Int64((Date().timeIntervalSince1970 + expIn) * 1000)
                    J.write(creds, credPath)
                } else {
                    geminiToken = (t, Date().addingTimeInterval(J.double(d["expires_in"]) ?? 3000))
                }
            }
        }
        let headers = ["Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "GeminiCLI AiLimitWidget/1.0"]
        var r = ExtraResult()
        r.email = J.string(Widget.jwtClaims(J.string(creds["id_token"]))?["email"])
        // проект и тариф — один раз, как при запуске Gemini CLI
        let meta = #"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
        let (lc, lt) = http(codeAssist + "loadCodeAssist", method: "POST", headers: headers, body: meta.data(using: .utf8))
        guard (200..<300).contains(lc), let load = J.obj(lt) else {
            return extra && (lc == 401 || lc == 403) ? ExtraResult(email: r.email, problem: expiredAccountText) : problem("Gemini CLI", lc)
        }
        let tier = (load["paidTier"] as? JSON) ?? (load["currentTier"] as? JSON)
        let tierName = J.string(tier?["name"]) ?? J.string(tier?["id"]) ?? ""
        r.plan = tierName.replacingOccurrences(of: "Gemini Code Assist ", with: "")
        let project = J.string(load["cloudaicompanionProject"]) ?? J.string((load["cloudaicompanionProject"] as? JSON)?["id"]) ?? (extra ? nil : geminiProject)
        if !extra { geminiProject = project }
        var q: [String: Any] = [:]
        if let p = project { q["project"] = p }
        let (qc, qt) = http(codeAssist + "retrieveUserQuota", method: "POST", headers: headers, body: try? JSONSerialization.data(withJSONObject: q))
        guard (200..<300).contains(qc), let quota = J.obj(qt) else {
            return extra && (qc == 401 || qc == 403) ? ExtraResult(email: r.email, problem: expiredAccountText) : problem("Gemini CLI", qc)
        }
        // по модели — остаток запросов на сутки; показываем Pro и Flash, остальные модели делят те же лимиты
        var byModel: [String: Limit] = [:]
        for b in (quota["buckets"] as? [JSON]) ?? [] {
            guard let model = J.string(b["modelId"]), let left = J.double(b["remainingFraction"]) else { continue }
            if model.contains("lite") || model.contains("embedding") { continue }
            let used = max(0, min(100, (1 - left) * 100))
            let at = Fmt.iso(b["resetTime"])
            let title = model.contains("pro") ? "Сутки · Pro" : model.contains("flash") ? "Сутки · Flash" : "Сутки · " + model
            if let old = byModel[title], old.percent >= used { continue }
            byModel[title] = Limit(key: keyPrefix + "-" + title, title: title, percent: used, resetsAt: at, windowSeconds: 86400)
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
        // папок Copilot может не быть (VS Code хранит вход у себя) — тогда вход берём из gh
        guard let token = copilotToken() else { return ExtraResult(signedIn: false) }
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
        let known = ["premium_interactions", "chat", "completions"]
        // известные — в привычном порядке, новые — после них, с названием из ключа
        func title(_ key: String) -> String { names[key] ?? capital(key.replacingOccurrences(of: "_", with: " ")) + " · месяц" }
        if let snaps = d["quota_snapshots"] as? JSON {
            for key in known + snaps.keys.filter({ !known.contains($0) }).sorted() {
                guard let s = snaps[key] as? JSON, J.bool(s["unlimited"]) != true else { continue }
                let left = J.double(s["percent_remaining"]) ?? {
                    guard let e = J.double(s["entitlement"]), e > 0, let rem = J.double(s["remaining"]) else { return nil }
                    return rem / e * 100
                }()
                guard let l = left else { continue }
                r.limits.append(Limit(key: "copilot-" + key, title: title(key), percent: max(0, min(100, 100 - l)), resetsAt: resetAt, windowSeconds: month))
            }
        } else if let left = d["limited_user_quotas"] as? JSON, let total = d["monthly_quotas"] as? JSON {
            // бесплатный Copilot: сколько осталось из месячной нормы
            for key in known + total.keys.filter({ !known.contains($0) }).sorted() {
                guard let t = J.double(total[key]), t > 0, let rem = J.double(left[key]) else { continue }
                r.limits.append(Limit(key: "copilot-" + key, title: title(key), percent: max(0, min(100, (t - rem) / t * 100)), resetsAt: resetAt, windowSeconds: month))
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

// Несколько аккаунтов Antigravity на одном пользователе macOS. agy хранит вход в связке ключей (login keychain) —
// запись service="gemini", account="antigravity", одна на пользователя, значение "go-keyring-base64:<base64>".
// Сохранённые входы — service="agy-account", account="<почта>"; так же их хранит и скилл ace, поэтому аккаунт,
// добавленный здесь, видит ace, и наоборот. Общие правила:
//   - если сохранён хоть один аккаунт, текущий вход тоже сохраняется;
//   - аккаунт, в который сейчас вошёл agy, — первый, остальные — по почте;
//   - запрос под другим аккаунтом: блокировка account.lock (flock), подставили его вход, запрос, сохранили
//     обновлённый токен, вернули прежний вход. Пока прежний вход снят, его почта лежит в account.restore —
//     если процесс убили, следующий запрос сам вернёт вход.
enum AgyAccounts {
    static let live = "gemini:antigravity"
    static let prefix = "agy-account:"
    static let b64Prefix = "go-keyring-base64:"
    static let waitMs = 20000   // ace может держать аккаунт, пока выполняет задачу: дольше не ждём
    private static var justAdded: String?
    private static let stateLock = NSLock()

    static var dir: String { Shell.home + "/.gemini/antigravity-accounts" }
    static var mark: String { dir + "/account.restore" }
    static var adding: String { dir + "/adding" }

    static func takeJustAdded() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        let v = justAdded
        justAdded = nil
        return v
    }

    private static func split(_ target: String) -> (service: String, account: String) {
        guard let idx = target.lastIndex(of: ":") else { return (target, "") }
        return (String(target[..<idx]), String(target[target.index(after: idx)...]))
    }

    private static func decode(_ value: String) -> Data? {
        if value.hasPrefix(b64Prefix) {
            return Data(base64Encoded: String(value.dropFirst(b64Prefix.count)))
        }
        return value.data(using: .utf8)
    }

    static func read(_ target: String) -> Data? {
        let (service, account) = split(target)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
        return decode(trimmed)
    }

    static func write(_ target: String, _ blob: Data, _ user: String) {
        let (service, account) = split(target)
        // секрет передаём через stdin (security -i), чтобы он не попадал в аргументы командной строки (ps)
        let cmd = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \"\(b64Prefix)\(blob.base64EncodedString())\"\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let inp = Pipe()
        p.standardInput = inp
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            if let d = cmd.data(using: .utf8) { inp.fileHandleForWriting.write(d) }
            try? inp.fileHandleForWriting.close()
            p.waitUntilExit()
        } catch {}
    }

    static func email(_ blob: Data?) -> String? {
        guard let blob = blob, let d = J.any(blob) as? JSON, let e = J.string(d["id_token_email"]), !e.isEmpty else { return nil }
        return e
    }

    @discardableResult
    static func put(_ blob: Data?) -> String? {
        guard let blob = blob, let e = email(blob), !e.isEmpty else { return nil }
        write(prefix + e, blob, e)
        return e
    }

    static func saved() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["dump-keychain"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var names: [String] = []
        var svce: String?, acct: String?
        for line in text.components(separatedBy: "\n") + ["keychain:"] {
            if line.hasPrefix("keychain:") {
                if let s = svce, let a = acct, (s + ":" + a).hasPrefix(prefix) {
                    let addr = String((s + ":" + a).dropFirst(prefix.count))
                    if !addr.isEmpty && !names.contains(where: { $0.caseInsensitiveCompare(addr) == .orderedSame }) {
                        names.append(addr)
                    }
                }
                svce = nil; acct = nil
            }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for k in ["\"svce\"<blob>=\"", "\"acct\"<blob>=\""] {
                if t.hasPrefix(k) && t.hasSuffix("\"") && t.count > k.count {
                    let val = String(t.dropFirst(k.count).dropLast())
                    if k.hasPrefix("\"svce\"") { svce = val } else { acct = val }
                }
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func liveEmail() -> String? { email(read(live)) }

    static func remove(_ email: String) {
        let (service, account) = split(prefix + email)
        _ = Proc.run("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account], timeout: 10)
    }

    @_silgen_name("flock") private static func c_flock(_ fd: Int32, _ operation: Int32) -> Int32

    // блокировка, общая с ace; nil — аккаунт занят дольше waitMs
    private static func lock(_ waitMs: Int) -> Int32? {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir + "/account.lock", O_RDWR | O_CREAT, 0o600)
        if fd < 0 { return nil }
        let until = Date().addingTimeInterval(Double(waitMs) / 1000)
        while true {
            if c_flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if Date() > until { Darwin.close(fd); return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func unlock(_ fd: Int32) {
        _ = c_flock(fd, LOCK_UN)
        Darwin.close(fd)
    }

    // прошлый запрос не вернул вход (процесс убили) — возвращаем
    static func restoreAfterCrash() {
        guard FileManager.default.fileExists(atPath: mark) else { return }
        let origEmail = (try? String(contentsOfFile: mark, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let orig = read(prefix + origEmail)
        let currentLive = read(live)
        if let orig = orig, let oe = email(orig), currentLive == nil || email(currentLive) != oe {
            if let currentLive = currentLive, let le = email(currentLive), saved().contains(le) {
                put(currentLive)
            }
            write(live, orig, oe)
        }
        try? FileManager.default.removeItem(atPath: mark)
    }

    // Добавление аккаунта: текущий вход сохраняем и запоминаем, затем пользователь входит в agy другим аккаунтом.
    // Как только в agy новый вход — сохраняем его и возвращаем прежний (finishAdding).
    static func startAdding() -> Bool {
        guard let fd = lock(waitMs) else { return false }
        defer { unlock(fd) }
        restoreAfterCrash()
        guard let e = put(read(live)), !e.isEmpty else { return false }
        // первая строка — к какому входу вернуться, дальше — уже сохранённые: новый вход — тот, которого среди них нет
        let lines = ([e] + saved()).joined(separator: "\n")
        try? lines.write(toFile: adding, atomically: true, encoding: .utf8)
        return true
    }

    static var isAdding: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: adding),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return mtime > Date().addingTimeInterval(-1800)
    }

    static func finishAdding() {
        guard FileManager.default.fileExists(atPath: adding) else { return }
        let text = (try? String(contentsOfFile: adding, encoding: .utf8)) ?? ""
        let known = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !isAdding || known.isEmpty { try? FileManager.default.removeItem(atPath: adding); return }   // за полчаса так и не вошли — забываем
        let orig = known[0]
        guard let currentLive = read(live), let back = read(prefix + orig),
              let le = email(currentLive), !le.isEmpty, !known.contains(le) else { return }
        put(currentLive)
        write(live, back, orig)
        try? FileManager.default.removeItem(atPath: adding)
        stateLock.lock(); justAdded = le; stateLock.unlock()
    }

    // почты аккаунтов, первый — тот, в который вошёл agy; nil — аккаунт занят запуском ace.
    // Один аккаунт (или ни одного сохранённого) — пустой список: всё как без аккаунтов.
    static func prepare() -> [String]? {
        guard let fd = lock(waitMs) else { return nil }
        defer { unlock(fd) }
        restoreAfterCrash()
        finishAdding()
        var names = saved()
        let currentLive = read(live)
        let le = email(currentLive)
        if !names.isEmpty, let le = le, !le.isEmpty, !names.contains(le) {
            put(currentLive)
            names = saved()
        }
        let ordered: [String]
        if let le = le, names.contains(le) {
            ordered = [le] + names.filter { $0 != le }
        } else {
            ordered = names
        }
        return ordered.count > 1 ? ordered : []
    }

    // выполнить body под входом аккаунта targetEmail; nil — аккаунт занят или вход не сохранён
    static func use<T>(_ targetEmail: String, _ body: () -> T) -> T? {
        guard let fd = lock(waitMs) else { return nil }
        defer { unlock(fd) }
        restoreAfterCrash()
        guard let want = read(prefix + targetEmail) else { return nil }
        let before = read(live)
        let swap = before == nil || email(before) != targetEmail
        if swap {
            if let before = before, let be = email(before), saved().contains(be) {
                put(before)
                try? be.write(toFile: mark, atomically: true, encoding: .utf8)
            }
            write(live, want, targetEmail)
        }
        defer {
            let now = read(live)
            if let now = now, email(now) == targetEmail { put(now) }   // agy мог обновить токен
            if swap, let before = before, let be = email(before) { write(live, before, be) }
            try? FileManager.default.removeItem(atPath: mark)
        }
        return body()
    }
}
