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

    func setDisableSleep(_ enabled: Bool) -> Bool {
        guard isEnabled else { return false }
        if send(enabled) { return true }
        // A helper left over from before an update exits on this first connection; launchd then spawns the current one.
        Thread.sleep(forTimeInterval: 0.3)
        return send(enabled)
    }

    private func send(_ enabled: Bool) -> Bool {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if let requirement = CodeSigning.sameTeamRequirement(identifier: HelperConstants.helperIdentifier) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        } as? HelperProtocol
        guard let proxy else { return false }

        proxy.setDisableSleep(enabled) { success in
            result = success
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }
}
