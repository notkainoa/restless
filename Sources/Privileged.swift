import Foundation

enum Privileged {
    @discardableResult
    static func setDisableSleep(_ enabled: Bool, allowPrompt: Bool = true) async -> Bool {
        if HelperClient.shared.isEnabled, await HelperClient.shared.setDisableSleep(enabled) {
            return true
        }
        guard allowPrompt else { return false }
        return await runAdmin(command(enabled))
    }

    /// For quitting, which has to finish before the process exits.
    @MainActor
    @discardableResult
    static func setDisableSleepBlocking(_ enabled: Bool) -> Bool {
        if HelperClient.shared.isEnabled, HelperClient.shared.setDisableSleepBlocking(enabled) {
            return true
        }
        return runAdmin(command(enabled))
    }

    private static func command(_ enabled: Bool) -> String {
        "/usr/bin/pmset -a disablesleep \(enabled ? "1" : "0")"
    }

    @MainActor
    private static func runAdmin(_ command: String) -> Bool {
        let source = "do shell script \"\(command)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}
