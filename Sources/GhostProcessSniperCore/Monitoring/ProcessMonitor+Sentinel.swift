import Foundation

/// Lets the spawn watcher ask the monitor for a prompt refresh without
/// holding it; the monitor installs the handler once it exists.
final class SentinelWakeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var lastFired = Date.distantPast

    func setHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Several spawns in a burst share one early scan.
    func fire() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(lastFired) >= 0.25 else { return nil }
            lastFired = now
            return self.handler
        }
        handler?()
    }
}

extension ProcessMonitor {
    func wakeForSentinel() {
        guard isRunning else { return }
        wake()
    }

    /// Hides one finding. The same program starting again is judged afresh.
    public func dismissSentinelFinding(_ id: String) {
        guard let sentinelEngine else { return }
        Task { @MainActor in
            await sentinelEngine.dismiss(findingID: id)
            sentinel = await sentinelEngine.currentReport
        }
    }

    /// Trusts what the finding's Trust item names: a signer, a build, or one
    /// script or command of a shell. The name trusted, for the confirmation.
    public func trustSentinelFinding(_ id: String) async -> SentinelTrustEntry? {
        guard let sentinelEngine else { return nil }
        let entry = await sentinelEngine.trust(findingID: id)
        sentinel = await sentinelEngine.currentReport
        return entry
    }

    public func revokeSentinelTrust(_ id: String) {
        guard let sentinelEngine else { return }
        Task { @MainActor in
            await sentinelEngine.revokeTrust(id: id)
            sentinel = await sentinelEngine.currentReport
        }
    }
}
