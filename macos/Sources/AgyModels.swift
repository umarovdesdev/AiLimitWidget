import Foundation

// одна модель Antigravity без уровня: «Gemini 4 Argon» + уровни low / medium / high
final class AgyModel {
    let name: String
    var levels: [String] = []
    var isNew = false        // появилась меньше AgyModels.newDays дней назад
    var noOwnGroup = false   // кодовое имя, а своей группы в /quota нет — лимит считается в группе, где она показана
    init(_ name: String) { self.name = name }
}

// Модели Antigravity: «agy models» (бесплатно, без запуска модели) → к какой группе лимитов относится каждая.
// Новые модели (впервые увиденные меньше newDays дней назад) помечаются «новая»; когда впервые увидели — в agy-models.json.
enum AgyModels {
    static let newDays = 3.0   // сколько дней новая модель отмечена словом «новая»
    private static let gate = NSLock()
    private static var seen: [String: Date]?
    private static let plain: Set<String> = ["gemini", "pro", "flash", "lite", "high", "medium", "low", "xhigh", "max", "minimal", "thinking", "preview"]
    static let levelOrder = ["minimal", "low", "medium", "high", "xhigh", "max", "thinking"]

    private static var appDir: String { Shell.home + "/Library/Application Support/AiLimitWidget" }
    private static var seenPath: String { appDir + "/agy-models.json" }
    private static var listsPath: String { appDir + "/agy-model-lists.json" }
    private static var aceModelsPath: String { Shell.home + "/.claude/skills/ace/state/models.json" }

    // «id<TAB>название» → пары (id, название); строка «Fetching available models...» пропускается
    static func parseList(_ text: String?) -> [(id: String, title: String)] {
        var list: [(id: String, title: String)] = []
        let re = try! NSRegularExpression(pattern: "^[a-z][a-z0-9.\\-]+$")
        for raw in (text ?? "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let tab = line.firstIndex(of: "\t"), tab > line.startIndex else { continue }
            let id = line[..<tab].trimmingCharacters(in: .whitespaces)
            if re.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) == nil { continue }
            list.append((id, line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)))
        }
        return list
    }

    private static func words(_ id: String) -> [String] { id.components(separatedBy: "-") }
    private static func startsWithDigit(_ w: String) -> Bool { w.first?.isNumber == true }

    // кодовое имя Gemini: «gemini-4-argon-high» → «argon», у Flash / Pro — nil
    static func codename(_ id: String) -> String? {
        words(id).first { !$0.isEmpty && !plain.contains($0) && !startsWithDigit($0) }
    }

    // группа лимитов /quota, в которую идёт модель: Claude/GPT — «3p», Gemini с кодовым именем — своя группа (gemini-argon-…), иначе — «gemini»
    static func groupOf(_ id: String, _ groupKeys: [String]) -> String? {
        let keys = groupKeys.filter { !$0.isEmpty }
        if id.hasPrefix("claude") || id.hasPrefix("gpt") {
            return keys.first { $0 == "3p" } ?? keys.first { !$0.hasPrefix("gemini") }
        }
        if id.hasPrefix("gemini"), let code = codename(id), let own = keys.first(where: { words($0).contains(code) }) { return own }
        return keys.first { $0 == "gemini" } ?? keys.first
    }

    // «Gemini 4 Argon (High)» → («Gemini 4 Argon», «high»); уровень из id важнее (gemini-…-xhigh)
    private static func split(_ id: String, _ title: String) -> (name: String, level: String?) {
        var name = title.isEmpty ? id : title
        var level: String?
        if let re = try? NSRegularExpression(pattern: "^(.*?)\\s*\\(([^)]*)\\)\\s*$"),
           let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let a = Range(m.range(at: 1), in: name), let b = Range(m.range(at: 2), in: name) {
            level = name[b].lowercased()
            name = String(name[a])
        }
        if let last = words(id).last, levelOrder.contains(last) { level = last }
        if name == id, let l = level, name.hasSuffix("-" + l) { name = String(name.dropLast(l.count + 1)) }
        return (name, level)
    }

    // название по id, когда agy его не прислал: «claude-opus-4-6-thinking» → «Claude Opus 4.6 (Thinking)»
    static func titleOf(_ id: String) -> String {
        var ws = words(id)
        var level: String?
        if ws.count > 1, let last = ws.last, levelOrder.contains(last) { level = last; ws.removeLast() }
        var out: [String] = []
        for w in ws where !w.isEmpty {
            let digits = w.allSatisfy { $0.isNumber }
            if digits, w.count == 1, let prev = out.last, prev.allSatisfy({ $0.isNumber }) {
                out[out.count - 1] = prev + "." + w   // «5-5» → «5.5»
            } else if w == "gpt" || w == "oss" || startsWithDigit(w) {
                out.append(w.uppercased())            // «GPT», «120B», «3.8»
            } else {
                out.append(w.prefix(1).uppercased() + w.dropFirst())
            }
        }
        let name = out.joined(separator: " ")
        guard let l = level else { return name }
        return name + " (" + l.prefix(1).uppercased() + l.dropFirst() + ")"
    }

    // свежий ответ «agy models» запоминаем по почте: пока аккаунт занят (ace выполняет на нём задачу), его модели берутся отсюда
    private static func remember(_ email: String?, _ text: String) {
        guard let email = email, !email.isEmpty else { return }
        gate.lock(); defer { gate.unlock() }
        var d = J.file(listsPath) ?? [:]
        if J.string(d[email]) == text { return }
        d[email] = text
        try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        J.write(d, listsPath)
    }

    // список моделей аккаунта, когда agy сейчас не ответил: свой сохранённый, иначе тот, что сохранил ace (он спрашивает agy models при каждом запуске)
    private static func stored(_ email: String?) -> String? {
        let key = email ?? ""
        if let t = J.string(J.file(listsPath)?[key]), !parseList(t).isEmpty { return t }
        guard let acc = (J.file(aceModelsPath)?["accounts"] as? JSON)?[key] as? JSON,
              let ids = acc["ids"] as? [Any] else { return nil }
        return ids.compactMap { J.string($0) }.map { $0 + "\t" + titleOf($0) + "\n" }.joined()
    }

    // email — чей это список: свежий запоминается, а если agy сейчас не ответил (аккаунт занят), берётся сохранённый
    static func attach(_ groups: [AgyGroup], _ modelsText: String?, email: String?) {
        var text = modelsText
        if let t = text, !parseList(t).isEmpty { remember(email, t) } else { text = stored(email) }
        attach(groups, text)
    }

    // раскладывает модели по группам; группы без моделей остаются как есть (подпись из описания /quota)
    static func attach(_ groups: [AgyGroup], _ modelsText: String?) {
        let list = parseList(modelsText)
        if groups.isEmpty || list.isEmpty { return }
        let keys = groups.map { $0.key }
        let firstSeen = markSeen(list.map { $0.id }, keys)
        for g in groups { g.modelList = [] }
        for p in list {
            guard let key = groupOf(p.id, keys), let g = groups.first(where: { $0.key == key }) else { continue }
            let (name, level) = split(p.id, p.title)
            var model = g.modelList.first { $0.name == name }
            if model == nil {
                let m = AgyModel(name)
                let code = p.id.hasPrefix("gemini") ? codename(p.id) : nil
                m.noOwnGroup = code != nil && !words(g.key).contains(code!)
                g.modelList.append(m)
                model = m
            }
            if let l = level, !model!.levels.contains(l) { model!.levels.append(l) }
            if let at = firstSeen[p.id], Date().timeIntervalSince(at) < newDays * 86400 { model!.isNew = true }
        }
        for g in groups { for m in g.modelList { m.levels.sort { order($0) < order($1) } } }
    }

    private static func order(_ level: String) -> Int { levelOrder.firstIndex(of: level) ?? 99 }

    // линейка модели без версии и уровня: «claude-opus-4-6-thinking» → «claude-opus», «gemini-4-argon-high» → «gemini-argon»
    private static func line(_ id: String) -> String {
        words(id).filter { !$0.isEmpty && !startsWithDigit($0) && !levelOrder.contains($0) }.joined(separator: "-")
    }

    private static func version(_ id: String) -> [Int] {
        var v: [Int] = []
        for w in words(id) where startsWithDigit(w) {
            for part in w.components(separatedBy: ".") { if let n = Int(String(part.prefix { $0.isNumber })) { v.append(n) } }
        }
        return v
    }

    private static func compareVersion(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // когда каждую модель увидели впервые. Самый первый запуск: всё, что уже есть, — не новое,
    // кроме моделей Gemini с кодовым именем без своей группы лимитов (их ещё не описал /quota — значит, только что вышли)
    private static func markSeen(_ ids: [String], _ groupKeys: [String]) -> [String: Date] {
        gate.lock(); defer { gate.unlock() }
        var first = false
        if seen == nil {
            var s: [String: Date] = [:]
            if let d = J.file(seenPath) {
                for (k, v) in d { if let t = Fmt.iso(v) { s[k] = t } }
            } else if !FileManager.default.fileExists(atPath: seenPath) {
                first = true
            }
            seen = s
        }
        var changed = false
        for id in ids where seen![id] == nil {
            let code = id.hasPrefix("gemini") ? codename(id) : nil
            var brandNew = !first || (code != nil && !groupKeys.contains { words($0).contains(code!) })
            // старая версия уже известной линейки (Opus 4.6 у второго аккаунта, когда Opus 5.5 уже видели) — не новая
            if brandNew, seen!.keys.contains(where: { line($0) == line(id) && compareVersion(version($0), version(id)) > 0 }) { brandNew = false }
            seen![id] = brandNew ? Date() : Date(timeIntervalSince1970: 946684800)   // 2000-01-01
            changed = true
        }
        if changed {
            try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
            J.write(seen!.mapValues { Fmt.isoString($0) }, seenPath)
        }
        return seen!
    }

    // модели группы одной строкой в заголовке: «Hydrogen 4 новая · Flash 3.8» — без уровней и служебных моделей
    static func shortName(_ m: AgyModel, in g: AgyGroup) -> String? {
        if !m.name.contains(where: { $0.isNumber }) { return nil }   // служебная модель без версии (Gemini Pro Orchestrator) — только в подсказке
        var name = m.name
        for p in ["Gemini ", "Claude "] where name.hasPrefix(p) { name = String(name.dropFirst(p.count)) }
        if g.title.hasSuffix(name) { return nil }                    // «Gemini 4 Argon» в группе «Gemini 4 Argon»
        if let re = try? NSRegularExpression(pattern: "^([\\d.]+) (.+)$"),
           let mm = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let a = Range(mm.range(at: 1), in: name), let b = Range(mm.range(at: 2), in: name) {
            name = name[b] + " " + name[a]                            // «4 Hydrogen» → «Hydrogen 4», «3.8 Flash» → «Flash 3.8»
        }
        return name.replacingOccurrences(of: "GPT OSS", with: "GPT-OSS")
    }

    // полный список с уровнями — во всплывающей подсказке
    static func tooltip(_ g: AgyGroup) -> String {
        g.modelList.map { m in
            m.name + (m.levels.isEmpty ? "" : " — " + m.levels.joined(separator: ", "))
                + (m.isNew ? " — новая: появилась меньше 3 дней назад" : "")
                + (m.noOwnGroup ? " — своей строки лимита нет, расход в «\(g.title)»" : "")
        }.joined(separator: "\n")
    }
}
