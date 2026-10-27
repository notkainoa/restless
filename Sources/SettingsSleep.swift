import SwiftUI

struct SleepSettings: View {
    @ObservedObject var controller: SleepController

    var body: some View {
        Form {
            Section {
                Toggle("Keep awake", isOn: Binding(
                    get: { controller.keepAwake },
                    set: { controller.setKeepAwake($0) }
                ))
            } header: {
                Text("Lid open")
            } footer: {
                Text("Stops your Mac and its screen from sleeping when idle while the lid is open. Always off when Restless starts, and released when it quits.")
            }

            Section {
                Toggle("Keep awake", isOn: Binding(
                    get: { controller.lidClosed },
                    set: { on in Task { await controller.setLidClosed(on) } }
                ))
                Toggle("Sleep display", isOn: Binding(
                    get: { controller.lidSleepDisplay },
                    set: { controller.setLidSleepDisplay($0) }
                ))
                Toggle("Lock screen", isOn: Binding(
                    get: { controller.lidLockScreen },
                    set: { controller.setLidLockScreen($0) }
                ))
            } header: {
                Text("Lid closed")
            } footer: {
                Text("Keep awake keeps your Mac running when you close the lid. It changes a system power setting, needs Restless’s helper or an administrator password, and Restless turns it back off when it quits. Sleep display turns the screen off when the lid closes; turn it off when a computer-use agent needs to see the screen, and Restless keeps it drawing at zero brightness instead. Lock screen locks the Mac when the lid closes; with it off, anyone who opens the lid can use the Mac, although macOS can still lock it when the display turns off if your Lock Screen settings ask for a password. Sleep display and Lock screen apply only while Keep awake is on and only to the built-in screen, so they do nothing while an external display is connected.")
            }

            Section {
                Toggle("Auto-off at 20% battery", isOn: Binding(
                    get: { controller.autoOff },
                    set: { controller.setAutoOff($0) }
                ))
            } footer: {
                Text("Turns off keep awake and lid-closed mode when your Mac is on battery power at 20% or less, so it can still sleep before the battery runs out.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }
}
