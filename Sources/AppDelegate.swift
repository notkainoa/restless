import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if let output = SettingsSnapshot.output {
            Task { await SettingsSnapshot.capture(to: output) { Self.openSettings() } }
            return
        }
#endif
        AppUpdater.registerDefaults()
        panelController = PanelController(controller: SleepController.shared)
#if DEBUG
        if let output = UserDefaults.standard.string(forKey: "panelSnapshot").map({ URL(filePath: $0) }) {
            let screen: PanelScreen = UserDefaults.standard.string(forKey: "panelSnapshotScreen") == "settings" ? .settings : .dashboard
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panelController?.snapshot(to: output, screen: screen) }
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

    // Opening Amped again shows its settings: in the panel, or in a window while the menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let panelController, panelController.canShowPanel {
            panelController.showSettings()
        } else {
            Self.openSettings()
        }
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
