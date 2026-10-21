import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if let output = SettingsSnapshot.output {
            Task { await SettingsSnapshot.capture(to: output) { Self.openSettings() } }
            return
        }
#endif
        AppUpdater.registerDefaults()
        statusMenu = StatusMenu(controller: SleepController.shared)
#if DEBUG
        if let output = UserDefaults.standard.string(forKey: "menuSnapshot").map({ URL(filePath: $0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.statusMenu?.snapshot(to: output) }
        }
        if let output = UserDefaults.standard.string(forKey: "menuPreview").map({ URL(filePath: $0) }) {
            statusMenu?.previewSnapshot(to: output)
        }
#endif
#if !DEBUG
        if UserDefaults.standard.bool(forKey: AppUpdater.checksAutomaticallyKey) {
            AppUpdater.check(manual: false)
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        SleepController.shared.cleanup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.openSettings()
        return true
    }

    // SwiftUI rejects showSettingsWindow: sent from code ("use SettingsLink") but honours its own app-menu item.
    static func openSettings() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
        else { return }
        NSApp.activate()
        menu.performActionForItem(at: index)
    }
}
