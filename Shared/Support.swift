// Общие мелочи: JSON, даты, цвета, запуск программ, автозапуск, уведомления, пункты меню.

import AppKit
import SwiftUI
import UserNotifications

typealias JSON = [String: Any]

enum J {
    static func any(_ data: Data?) -> Any? {
        guard let data = data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func obj(_ text: String?) -> JSON? { any(text?.data(using: .utf8)) as? JSON }
    static func file(_ path: String) -> JSON? { any(FileManager.default.contents(atPath: path)) as? JSON }

    // вывод программ иногда начинается со служебных строк — берём сам JSON-объект
    static func embedded(_ text: String?) -> JSON? {
        guard let t = text, let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
        return obj(String(t[a...b]))
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }
    static func text(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ obj: Any, _ path: String) {
        guard let t = text(obj) else { return }
        try? t.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

enum Fmt {
    static let ru = Locale(identifier: "ru_RU")

    // «2025-10-01T12:00:00.123456+00:00» — дробные секунды отбрасываем, их не понимает ISO8601DateFormatter
    static func iso(_ v: Any?) -> Date? {
        guard let raw = v as? String, !raw.isEmpty else { return nil }
        let s = raw.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    static func date(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = pattern
        return f.string(from: d)
    }

    static func duration(_ span: TimeInterval) -> String {
        if span < 60 { return "меньше минуты" }
        let total = Int(span)
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days) д \(hours) ч" }
        if hours > 0 { return "\(hours) ч " + String(format: "%02d", minutes) + " мин" }
        return "\(minutes) мин"
    }

    static func resetMoment(_ at: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(at) { return "сегодня в " + date(at, "HH:mm") }
        if cal.isDateInTomorrow(at) { return "завтра в " + date(at, "HH:mm") }
        return date(at, "EEE, d MMM 'в' HH:mm")
    }

    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
}

extension NSColor {
    // «#RRGGBB» или «#AARRGGBB» (как в WPF)
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v = UInt64(s, radix: 16) ?? 0
        if s.count == 6 { v |= 0xFF000000 }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: CGFloat((v >> 24) & 0xFF) / 255)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

// Выполнить программу и дождаться вывода; missing — программу не удалось запустить.
enum Proc {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 45, env: [String: String]? = nil) -> (output: String?, missing: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env ?? Shell.environment
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, true) }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        DispatchQueue.global().async { _ = err.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (nil, false) }
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8), false)
    }
}

// Приложения, открытые из Finder, не получают PATH из ~/.zshrc — узнаём его у оболочки один раз.
enum Shell {
    static let home = NSHomeDirectory()

    static let loginPath: [String] = {
        let r = Proc.run("/bin/zsh", ["-lic", "echo __PATH__$PATH"], timeout: 10, env: ProcessInfo.processInfo.environment)
        guard let out = r.output, let range = out.range(of: "__PATH__", options: .backwards) else { return [] }
        let line = out[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        return line.split(separator: ":").map(String.init)
    }()

    static var dirs: [String] {
        var list: [String] = []
        let standard = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                        "\(home)/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for d in loginPath + standard where !d.isEmpty && !list.contains(d) { list.append(d) }
        return list
    }

    static var environment: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = dirs.joined(separator: ":")
        return e
    }

    static func find(_ name: String, extra: [String] = []) -> String? {
        for p in extra + dirs.map({ "\($0)/\(name)" }) where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // команда в новом окне «Терминала» (там, где программе нужен живой терминал)
    static func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        _ = Proc.run("/usr/bin/osascript", ["-e", script], timeout: 20)
    }
}

// Запуск при входе в систему: агент launchd в ~/Library/LaunchAgents.
enum Autostart {
    static func path(_ label: String) -> String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static func isOn(_ label: String) -> Bool { FileManager.default.fileExists(atPath: path(label)) }

    static func set(_ label: String, _ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let dict: NSDictionary = ["Label": label, "ProgramArguments": [exe], "RunAtLoad": true, "ProcessType": "Interactive"]
            try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents", withIntermediateDirectories: true)
            dict.write(toFile: path(label), atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: path(label))
        }
    }
}

enum Notify {
    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Delegate()
        // показывать баннер, даже когда приложение активно
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }

    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = Delegate.shared
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String, sound: Bool = true) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if sound { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// Пункт меню с замыканием вместо селектора.
final class ClosureItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: (() -> Void)? = nil) {
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
        state = checked ? .on : .off
        isEnabled = enabled && handler != nil
    }

    required init(coder: NSCoder) { fatalError("init(coder:) не используется") }

    @objc private func fire() { handler?() }
}

func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    for i in items { menu.addItem(i) }
    item.submenu = menu
    return item
}

// Полноэкранная программа (Telegram, Safari и т. п. в своём пространстве): строка меню скрыта,
// и виджет не должен всплывать, когда курсор просто подходит к верхнему краю экрана.
enum FullScreen {
    static func isActive() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map { $0.frame.size }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == front, (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let size = CGSize(width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if screens.contains(where: { abs($0.width - size.width) < 1 && abs($0.height - size.height) < 1 }) { return true }
        }
        return false
    }
}
