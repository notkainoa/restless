import Foundation
import ServiceManagement

final class HelperClient {
    static let shared = HelperClient()
    private init() {}

    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }

    var status: SMAppService.Status { service.status }
    var isEnabled: Bool { service.status == .enabled }

    @discardableResult
    func register() -> SMAppService.Status {
        try? service.register()
        return service.status
    }

    @discardableResult
    func unregister() -> Bool {
        do { try service.unregister(); return true } catch { return false }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private enum Outcome {
        case done(Bool)
        /// The connection dropped before a reply, which is what a helper left over from an update does.
        case dropped
    }

    func setDisableSleep(_ enabled: Bool) -> Bool {
        guard isEnabled else { return false }
        switch send(enabled) {
        case .done(let success):
            return success
        case .dropped:
            // The stale helper exits on that first connection and launchd spawns the current one. A helper
            // that's merely slow times out instead and isn't retried, so a call never waits twice.
            Thread.sleep(forTimeInterval: 0.3)
            if case .done(let success) = send(enabled) { return success }
            return false
        }
    }

    private func send(_ enabled: Bool) -> Outcome {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if let requirement = CodeSigning.sameTeamRequirement(identifier: HelperConstants.helperIdentifier) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome = Outcome.done(false)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            outcome = .dropped
            semaphore.signal()
        } as? HelperProtocol
        guard let proxy else { return .done(false) }

        proxy.setDisableSleep(enabled) { success in
            outcome = .done(success)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return .done(false) }
        return outcome
    }
}
