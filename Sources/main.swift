// Точка входа: приложение без значка в Dock (LSUIElement), живёт в строке меню.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var widget: Widget!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        widget = Widget(dir: support + "/AiLimitWidget")
        widget.start()
    }

    // приложение открыли повторно (Finder, Spotlight) — показать панель
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        widget.showWidget()
        return false
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
