import Foundation
import Combine
import CoreGraphics
import IOKit.pwr_mgt
import WidgetKit

@MainActor
final class SleepController: ObservableObject {
    static let shared = SleepController()

    @Published private(set) var keepAwake = false {
        didSet { mirrorControlState() }
    }

    @Published private(set) var lidClosed = false {
        didSet { mirrorControlState() }
    }

    @Published private(set) var lidSleepDisplay: Bool
    @Published private(set) var lidLockScreen: Bool

    @Published private(set) var autoOff: Bool {
        didSet { mirrorControlState() }
    }

    @Published private(set) var helperEnabled: Bool = HelperClient.shared.isEnabled

    @Published private(set) var launchAtLogin: Bool = LoginItem.isEnabled

    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onBattery = false

    private let systemAssertion = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep)
    private let displayAssertion = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
    private let backlight = Backlight()
    private let lidMonitor = LidMonitor()
    private var batteryTimer: Timer?
    private var lidIsShut = false

    private static let autoOffKey = "autoOffEnabled"
    private static let helperPromptedKey = "helperPrompted"
    private static let lastKeepAwakeKey = "lastActiveKeepAwake"
    private static let lastLidClosedKey = "lastActiveLidClosed"
    private static let legacyLidCloseActionKey = "lidCloseAction"
    private static let lidSleepDisplayKey = "lidSleepDisplay"
    private static let lidLockScreenKey = "lidLockScreen"
    private let autoOffThreshold = 20

    private var helperPrompted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.helperPromptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.helperPromptedKey) }
    }

    private init() {
        Self.migrateLegacyLidCloseAction()
        UserDefaults.standard.register(defaults: [
            Self.lastKeepAwakeKey: true,
            Self.lidSleepDisplayKey: true,
            Self.lidLockScreenKey: true,
        ])
        autoOff = UserDefaults.standard.bool(forKey: Self.autoOffKey)
        lidSleepDisplay = UserDefaults.standard.bool(forKey: Self.lidSleepDisplayKey)
        lidLockScreen = UserDefaults.standard.bool(forKey: Self.lidLockScreenKey)
        lidIsShut = LidMonitor.isClosed()
        refreshBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        lidMonitor.start { [weak self] closed in
            MainActor.assumeIsolated {
                guard let self, self.lidIsShut != closed else { return }
                self.lidIsShut = closed
                self.syncAssertion()
                self.applyLidPresentation()
            }
        }
        mirrorControlState()
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        syncAssertion()
        if on { rememberActiveCombination() }
    }

    func setActive(_ on: Bool) {
        guard on else {
            keepAwake = false
            if lidClosed { setLidClosed(false) } else { syncAssertion() }
            return
        }
        let restoreKeepAwake = UserDefaults.standard.bool(forKey: Self.lastKeepAwakeKey)
        let restoreLidClosed = UserDefaults.standard.bool(forKey: Self.lastLidClosedKey)
        keepAwake = restoreKeepAwake
        syncAssertion()
        if restoreLidClosed { setLidClosed(true) }
    }

    private func rememberActiveCombination() {
        UserDefaults.standard.set(keepAwake, forKey: Self.lastKeepAwakeKey)
        UserDefaults.standard.set(lidClosed, forKey: Self.lastLidClosedKey)
    }

    private func mirrorControlState() {
#if DEBUG
        // The app-group container prompts in unsigned builds, which would block a layout snapshot.
        if UserDefaults.standard.string(forKey: "menuSnapshot") != nil || UserDefaults.standard.string(forKey: "menuPreview") != nil || SettingsSnapshot.output != nil { return }
#endif
        let group = UserDefaults(suiteName: AmpedDefaults.suiteName)
        group?.set(keepAwake || lidClosed, forKey: AmpedDefaults.isActiveKey)
        group?.set(lidClosed, forKey: AmpedDefaults.lidClosedKey)
        group?.set(autoOff, forKey: AmpedDefaults.autoOffKey)
        ControlCenter.shared.reloadAllControls()
    }

    // 1.0.1 stored one lid choice; it maps onto the two switches.
    private static func migrateLegacyLidCloseAction() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyLidCloseActionKey) else { return }
        let keepUnlocked = legacy == "keepUnlocked"
        defaults.set(!keepUnlocked, forKey: lidSleepDisplayKey)
        defaults.set(!keepUnlocked, forKey: lidLockScreenKey)
        defaults.removeObject(forKey: legacyLidCloseActionKey)
    }

    func setLidSleepDisplay(_ on: Bool) {
        guard on != lidSleepDisplay else { return }
        lidSleepDisplay = on
        UserDefaults.standard.set(on, forKey: Self.lidSleepDisplayKey)
        lidIsShut = LidMonitor.isClosed()
        syncAssertion()
        applyLidPresentation()
    }

    func setLidLockScreen(_ on: Bool) {
        guard on != lidLockScreen else { return }
        lidLockScreen = on
        UserDefaults.standard.set(on, forKey: Self.lidLockScreenKey)
        lidIsShut = LidMonitor.isClosed()
        applyLidPresentation()
    }

    func setLidClosed(_ on: Bool) {
        guard on else {
            stopLidMode()
            return
        }

        refreshHelper()

        if !helperEnabled && !helperPrompted {
            switch Prompts.offerHelperSetup() {
            case .cancel:
                return
            case .setUpHelper:
                setUpHelper()
                // Not marked prompted, so the offer reappears until the daemon is approved.
                return
            case .justThisTime:
                helperPrompted = true
            }
        }

        if Privileged.setDisableSleep(true) { startLidMode() }
    }

    /// Changes lid-closed mode only if the helper can do it without an alert or password prompt; returns false when one is needed.
    func setLidClosedQuietly(_ on: Bool) -> Bool {
        refreshHelper()
        guard helperEnabled else { return false }
        if on {
            guard Privileged.setDisableSleep(true, allowPrompt: false) else { return false }
            startLidMode()
        } else {
            guard Privileged.setDisableSleep(false, allowPrompt: false) else { return false }
            backlight.restore()
            lidClosed = false
            syncAssertion()
        }
        return true
    }

    private func startLidMode() {
        lidClosed = true
        lidIsShut = LidMonitor.isClosed()
        syncAssertion()
        rememberActiveCombination()
        applyLidPresentation()
    }

    private func stopLidMode() {
        backlight.restore()
        _ = Privileged.setDisableSleep(false)
        lidClosed = false
        syncAssertion()
    }

    // Lid-closed needs the system assertion too: a shut lid under disablesleep still idle-sleeps without it.
    // With Sleep Display off, a shut lid also holds the display assertion so idle display-off cannot lock the session.
    private func syncAssertion() {
        if keepAwake || lidClosed {
            systemAssertion.enable()
        } else {
            systemAssertion.disable()
        }
        if keepAwake || (lidClosed && lidIsShut && !lidSleepDisplay) {
            displayAssertion.enable()
        } else {
            displayAssertion.disable()
        }
    }

    private func applyLidPresentation() {
        guard lidClosed, lidIsShut else {
            backlight.restore()
            return
        }
        guard onlyBuiltinDisplay() else { return }
        if lidLockScreen { ScreenLock.lock() }
        if lidSleepDisplay {
            backlight.restore()
            sleepDisplay()
        } else {
            backlight.dimBuiltin()
        }
    }

    private func onlyBuiltinDisplay() -> Bool {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsBuiltin($0) != 0 }
    }

    private func sleepDisplay() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
    }

    func setAutoOff(_ on: Bool) {
        autoOff = on
        UserDefaults.standard.set(on, forKey: Self.autoOffKey)
        if on { tick() }
    }

    private func setUpHelper() {
        _ = HelperClient.shared.register()
        refreshHelper()
        if !helperEnabled {
            HelperClient.shared.openSettings()
            Prompts.explainHelperApproval()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        if LoginItem.setEnabled(on) {
            launchAtLogin = on
        } else {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private func tick() {
        refreshBattery()
        refreshHelper()
        guard autoOff, onBattery, let percent = batteryPercent, percent <= autoOffThreshold else { return }
        guard keepAwake || lidClosed else { return }

        backlight.restore()
        systemAssertion.disable()
        displayAssertion.disable()
        // Without the helper, clamshell mode can't be dropped unattended.
        if lidClosed { _ = Privileged.setDisableSleep(false, allowPrompt: false) }
        keepAwake = false
        lidClosed = false
    }

    func refreshStatus() {
        refreshBattery()
        refreshHelper()
    }

    private func refreshBattery() {
        if let info = Battery.read() {
            batteryPercent = info.percent
            onBattery = info.isOnBattery
        } else {
            batteryPercent = nil
            onBattery = false
        }
    }

    private func refreshHelper() {
        helperEnabled = HelperClient.shared.isEnabled
    }

    func cleanup() {
        lidMonitor.stop()
        backlight.restore()
        systemAssertion.disable()
        displayAssertion.disable()
        if lidClosed { _ = Privileged.setDisableSleep(false) }
        keepAwake = false
        lidClosed = false
    }

    var menuBarSymbolName: String {
        if lidClosed { return "pills.fill" }
        if keepAwake { return "pill.fill" }
        return "pill"
    }

    // Dimmed while the lid-closed mode will turn the screen off and nothing keeps it on with the lid open.
    var menuBarSymbolDimmed: Bool {
        lidClosed && !keepAwake && lidSleepDisplay
    }

    var statusText: String {
        let battery = batteryPercent.map { " · \($0)%" } ?? ""
        if lidClosed {
            let display = lidSleepDisplay ? "display off" : "display on"
            let lock = lidLockScreen ? "locked" : "unlocked"
            return "Awake — lid closed: \(display), \(lock)\(battery)"
        }
        if keepAwake { return "Awake\(battery)" }
        return "Sleep allowed\(battery)"
    }
}
