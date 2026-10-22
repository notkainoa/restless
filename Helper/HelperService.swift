import Foundation

final class HelperService: NSObject, HelperProtocol {
    func setDisableSleep(_ enabled: Bool, withReply reply: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", enabled ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            reply(process.terminationStatus == 0)
        } catch {
            reply(false)
        }
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private var liveConnections = 0
    private var pendingExit: DispatchWorkItem?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard CodeSigning.currentCodeIsIntact() else { exit(0) }
        if let requirement = CodeSigning.sameTeamRequirement(identifier: HelperConstants.appIdentifier) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connectionEnded() }
        }
        DispatchQueue.main.async { self.connectionStarted() }
        connection.resume()
        return true
    }

    private func connectionStarted() {
        liveConnections += 1
        pendingExit?.cancel()
    }

    // Exit when idle so launchd respawns us from the current bundle after an update; 30s clears its ~10s respawn throttle.
    private func connectionEnded() {
        liveConnections -= 1
        guard liveConnections == 0 else { return }
        let exitWork = DispatchWorkItem { exit(0) }
        pendingExit = exitWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: exitWork)
    }
}
