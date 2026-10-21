import SwiftUI

enum SettingsTab: String {
    case general, sleep, about
}

struct SettingsView: View {
    static let showMenuBarItemKey = "showMenuBarItem"
    static let store: UserDefaults = {
#if DEBUG
        if SettingsSnapshot.output != nil {
            let suite = "dev.gustaf.Amped.snapshot"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let store = UserDefaults(suiteName: suite) ?? .standard
            if let tab = UserDefaults.standard.string(forKey: "settingsSnapshotTab") { store.set(tab, forKey: "settingsTab") }
            return store
        }
#endif
        return .standard
    }()

    @ObservedObject var controller: SleepController
    @AppStorage("settingsTab", store: SettingsView.store) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings(controller: controller)
            }
            Tab("Sleep", systemImage: "moon.zzz", value: .sleep) {
                SleepSettings(controller: controller)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettings()
            }
        }
        .frame(width: 500)
        .onAppear { NSApp.activate() }
    }
}
