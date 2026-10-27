import Foundation
import ServiceManagement

enum HelperAdoption {
    /// The helper for this build is approved and answering.
    case ready
    /// macOS still has to allow the helper in Login Items & Extensions.
    case needsApproval
    /// Never registered, registration failed, or the helper won't start even after registering again.
    case unavailable
}

final class HelperClient {
    static let shared = HelperClient()
    private init() {}

    private static let adoptedBuildKey = "helperAdoptedBuild"

    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }
    private var adoptTask: Task<HelperAdoption, Never>?

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

    /// Setup registered this build. Remember it so the next lid toggle doesn't register it again.
    func noteCurrentBuildRegistered() {
        guard status == .enabled || status == .requiresApproval else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        UserDefaults.standard.set(build, forKey: Self.adoptedBuildKey)
    }

    /// The approval is pinned to the helper executable that registered it. A new build is a new
    /// executable, and launchd keeps refusing to start the old one until Restless registers again.
    @MainActor
    func adoptCurrentBuild() async -> HelperAdoption {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if UserDefaults.standard.string(forKey: Self.adoptedBuildKey) == build {
            return classify()
        }
        if let adoptTask { return await adoptTask.value }
        let task = Task { @MainActor in await self.performAdopt(build: build) }
        adoptTask = task
        let result = await task.value
        adoptTask = nil
        return result
    }

    @MainActor
    private func performAdopt(build: String) async -> HelperAdoption {
        // Only an enabled helper can be stale. Not registered, or switched off in Login Items: leave it to the user.
        guard status == .enabled else { return classify() }
        if await responds() {
            UserDefaults.standard.set(build, forKey: Self.adoptedBuildKey)
            return .ready
        }
        // Once per build, so a helper that still won't start doesn't get re-registered on every toggle.
        UserDefaults.standard.set(build, forKey: Self.adoptedBuildKey)
        _ = unregister()
        register()
        if status == .enabled, !(await responds()) { return .unavailable }
        return classify()
    }

    private func classify() -> HelperAdoption {
        switch status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        default: return .unavailable
        }
    }

    private enum Outcome {
        case done(Bool)
        /// The connection dropped before a reply, which is what a helper left over from an update does.
        case dropped
        case timedOut
    }

    func setDisableSleep(_ enabled: Bool) async -> Bool {
        guard isEnabled else { return false }
        var outcome = await send(enabled)
        if case .dropped = outcome {
            // The stale helper exits on that first connection and launchd spawns the current one.
            try? await Task.sleep(nanoseconds: 300_000_000)
            outcome = await send(enabled)
        }
        if case .done(let success) = outcome { return success }
        return false
    }

    /// Quitting can't wait for an async call, so this blocks. Replies arrive on XPC's own queue.
    func setDisableSleepBlocking(_ enabled: Bool) -> Bool {
        guard isEnabled else { return false }
        var outcome = sendBlocking(enabled)
        if case .dropped = outcome {
            Thread.sleep(forTimeInterval: 0.3)
            outcome = sendBlocking(enabled)
        }
        if case .done(let success) = outcome { return success }
        return false
    }

    /// True when the current helper accepts a connection. A refused spawn fails this.
    private func responds() async -> Bool {
        var outcome = await ping()
        if case .dropped = outcome {
            try? await Task.sleep(nanoseconds: 300_000_000)
            outcome = await ping()
        }
        if case .done(true) = outcome { return true }
        return false
    }

    private func ping() async -> Outcome {
        await withCheckedContinuation { continuation in
            call(timeout: 5, body: { proxy, finish in proxy.ping { finish(.done(true)) } }) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func send(_ enabled: Bool) async -> Outcome {
        await withCheckedContinuation { continuation in
            call(timeout: 5, body: { proxy, finish in
                proxy.setDisableSleep(enabled) { success in finish(.done(success)) }
            }) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func sendBlocking(_ enabled: Bool) -> Outcome {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = Outcome.timedOut
        call(timeout: 5, body: { proxy, finish in
            proxy.setDisableSleep(enabled) { success in finish(.done(success)) }
        }) {
            outcome = $0
            semaphore.signal()
        }
        semaphore.wait()
        return outcome
    }

    /// Calls `completion` exactly once: with the reply, when the connection drops, or at the timeout.
    private func call(
        timeout: TimeInterval,
        body: (HelperProtocol, @escaping (Outcome) -> Void) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        let once = Once()
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if let requirement = CodeSigning.sameTeamRequirement(identifier: HelperConstants.helperIdentifier) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.resume()
        let finish: (Outcome) -> Void = { outcome in
            once.run {
                connection.invalidate()
                completion(outcome)
            }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            finish(.dropped)
        } as? HelperProtocol
        guard let proxy else {
            finish(.done(false))
            return
        }
        body(proxy, finish)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.timedOut)
        }
    }
}

/// Resumes an XPC reply once. Invalidating the connection also fires the error handler.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        guard first else { return }
        body()
    }
}
