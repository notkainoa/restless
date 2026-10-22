import AppIntents
import SwiftUI
import WidgetKit

@main
struct RestlessControlBundle: WidgetBundle {
    var body: some Widget {
        RestlessToggle()
        LidClosedToggle()
        AutoOffToggle()
    }
}

struct GroupValueProvider: ControlValueProvider {
    let key: String

    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        UserDefaults(suiteName: RestlessDefaults.suiteName)?.bool(forKey: key) ?? false
    }
}

struct RestlessToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "me.kainoa.Restless.toggle", provider: GroupValueProvider(key: RestlessDefaults.isActiveKey)) { isOn in
            ControlWidgetToggle("Restless", isOn: isOn, action: SetRestlessActiveIntent()) { isOn in
                Label(isOn ? "Awake" : "Sleep Allowed", systemImage: isOn ? "pill.fill" : "pill")
            }
        }
        .displayName("Restless")
        .description("Keep your Mac awake with the settings you last used.")
    }
}

struct LidClosedToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "me.kainoa.Restless.lidClosed", provider: GroupValueProvider(key: RestlessDefaults.lidClosedKey)) { isOn in
            ControlWidgetToggle("When Lid Is Closed", isOn: isOn, action: SetLidClosedIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: "laptopcomputer")
            }
        }
        .displayName("When Lid Is Closed")
        .description("Keep your Mac running with the lid closed.")
    }
}

struct AutoOffToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "me.kainoa.Restless.autoOff", provider: GroupValueProvider(key: RestlessDefaults.autoOffKey)) { isOn in
            ControlWidgetToggle("Auto-off at 20%", isOn: isOn, action: SetAutoOffIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: "battery.25percent")
            }
        }
        .displayName("Auto-off at 20% Battery")
        .description("Let the Mac sleep again when the battery drops to 20%.")
    }
}
