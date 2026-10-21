import AppKit
import Combine
import Sparkle

/// Sparkle updates, from the appcast attached to the latest GitHub release.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    private var observation: NSKeyValueObservation?

    @Published private(set) var automaticallyChecks = false

    func start() {
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        observation = updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
            let value = updater.automaticallyChecksForUpdates
            Task { @MainActor in self?.automaticallyChecks = value }
        }
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }

    func checkForUpdates() {
        // An accessory app's windows open behind the frontmost app unless it activates first.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // A local build would otherwise replace itself with the latest release in the background.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground, AppVersion.isLocalBuild {
            throw NSError(domain: "Restless", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local builds don't check in the background."])
        }
    }
}
