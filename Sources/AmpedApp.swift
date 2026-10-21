import SwiftUI

@main
struct AmpedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SleepController.shared

    // The menu bar item is an AppKit StatusMenu, created by AppDelegate.
    var body: some Scene {
        Settings {
            SettingsView(controller: controller)
        }
    }
}
