import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var controller: SleepController
    @AppStorage(SettingsView.showMenuBarItemKey, store: SettingsView.store) private var showMenuBarItem = true
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Form {
            Section {
                Toggle("Show menu bar item", isOn: $showMenuBarItem)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("When hidden, open Restless again to show Settings.")
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            }

            Section("Updates") {
                LabeledContent {
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                } label: {
                    Text("Restless \(version)")
                    if version.hasSuffix("-local") { Text("Local build") }
                }
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(height: 345)
    }
}
