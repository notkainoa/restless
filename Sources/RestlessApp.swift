import SwiftUI

@main
struct AmpedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SleepController.shared

    // The menu bar item and its panel are created by AppDelegate (PanelController).
    var body: some Scene {
        Settings {
            SettingsView(controller: controller)
        }
    }
}
