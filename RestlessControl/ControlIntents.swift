import AppIntents

// A foreground mode cannot run in an extension, so the system runs these in the app, launching it if needed.

struct SetAmpedActiveIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Active")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
#if AMPED_CONTROL_EXTENSION
        throw CocoaError(.featureUnsupported)
#else
        SleepController.shared.setActive(value)
#endif
        return .result()
    }
}

struct SetLidClosedIntent: SetValueIntent {
    static let title: LocalizedStringResource = "When Lid Is Closed"
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Allowed")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
#if AMPED_CONTROL_EXTENSION
        throw CocoaError(.featureUnsupported)
#else
        SleepController.shared.setLidClosed(value)
#endif
        return .result()
    }
}

struct SetAutoOffIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Auto-off at 20% Battery"
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Enabled")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
#if AMPED_CONTROL_EXTENSION
        throw CocoaError(.featureUnsupported)
#else
        SleepController.shared.setAutoOff(value)
#endif
        return .result()
    }
}
