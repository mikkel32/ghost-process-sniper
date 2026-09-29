import AppKit
import Darwin
import Foundation

public protocol ProcessLookup: Sendable {
    func processes() async throws -> [ProcessMetrics]
    func killSnapshot(policy: KillSnapshotPolicy) async throws -> KillProcessSnapshot
}

public extension ProcessLookup {
    func killSnapshot(policy: KillSnapshotPolicy) async throws -> KillProcessSnapshot {
        let started = Date()
        let processes = try await processes()
        return KillProcessSnapshot(
            processes: processes,
            sampledAt: Date(),
            policy: policy,
            elapsedMilliseconds: Date().timeIntervalSince(started) * 1_000,
            usedCheapPath: false,
            expensiveCallCount: 0,
            arena: KillGraphArena(processes: processes.map { KillProcessLite(process: $0) }, sampledAt: Date(), pidReadCount: processes.count)
        )
    }
}

public struct SignalFailure: Error, Equatable, Sendable {
    public let pid: Int32
    public let signal: Int32
    public let errnoCode: Int32
    public let message: String
    /// The PID now belongs to a different process than the one approved.
    public let isRecycled: Bool

    public init(pid: Int32, signal: Int32, errnoCode: Int32, message: String, isRecycled: Bool = false) {
        self.pid = pid
        self.signal = signal
        self.errnoCode = errnoCode
        self.message = message
        self.isRecycled = isRecycled
    }
}

extension SignalFailure: LocalizedError {
    public var errorDescription: String? { message }
}

public protocol ProcessSignaling: Sendable {
    var usesDarwinProcessNamespace: Bool { get }
    func send(signal: Int32, to pid: Int32) throws
    /// Signals the process only if the PID still belongs to `identity`.
    func send(signal: Int32, to identity: ProcessIdentity) throws
    func exists(pid: Int32) -> Bool
    /// True for a process that has exited, including a zombie its parent
    /// has not collected yet, which `exists` still reports.
    func isZombieOrGone(pid: Int32) -> Bool
    /// Asks a GUI app to quit the way ⌘Q does. Returns false when the
    /// process is not a running app, so the caller falls back to signals.
    func requestQuit(pid: Int32) async -> Bool
    func requestQuit(identity: ProcessIdentity) async -> Bool
}

public extension ProcessSignaling {
    var usesDarwinProcessNamespace: Bool { false }
    func requestQuit(pid: Int32) async -> Bool { false }

    func send(signal: Int32, to identity: ProcessIdentity) throws {
        try send(signal: signal, to: identity.pid)
    }

    func isZombieOrGone(pid: Int32) -> Bool {
        !exists(pid: pid)
    }

    func requestQuit(identity: ProcessIdentity) async -> Bool {
        await requestQuit(pid: identity.pid)
    }
}

public struct DarwinProcessSignaler: ProcessSignaling {
    public var usesDarwinProcessNamespace: Bool { true }

    public init() {}

    public func send(signal: Int32, to pid: Int32) throws {
        // kill(0) signals Ghost's own process group and kill(-1) every
        // process the user owns; no plan may ever reach either.
        guard pid > 1, pid != getpid() else {
            throw SignalFailure(pid: pid, signal: signal, errnoCode: EINVAL, message: "Refused: protected PID")
        }
        guard kill(pid, signal) == 0 else {
            let code = errno
            throw SignalFailure(
                pid: pid,
                signal: signal,
                errnoCode: code,
                message: String(cString: strerror(code))
            )
        }
    }

    public func send(signal: Int32, to identity: ProcessIdentity) throws {
        switch Self.check(identity) {
        case .gone:
            throw SignalFailure(pid: identity.pid, signal: signal, errnoCode: ESRCH, message: "No such process")
        case .recycled:
            throw SignalFailure(pid: identity.pid, signal: signal, errnoCode: ESRCH,
                                message: "PID was reused by another process", isRecycled: true)
        case .same, .unknown:
            try send(signal: signal, to: identity.pid)
        }
    }

    public func exists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public func isZombieOrGone(pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return !exists(pid: pid)
        }
        return info.pbi_status == KillProcessLite.zombieStatus
    }

    public func requestQuit(pid: Int32) async -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return app.terminate()
        }
    }

    public func requestQuit(identity: ProcessIdentity) async -> Bool {
        guard identity.pid > 1, identity.pid != getpid() else { return false }
        return await MainActor.run {
            // Checked on the main actor, next to the quit: checking before the
            // hop left a busy main thread's delay between the check and it.
            switch Self.check(identity) {
            case .gone, .recycled:
                return false
            case .same, .unknown:
                guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated else { return false }
                return app.terminate()
            }
        }
    }

    private enum IdentityCheck {
        case same, gone, recycled, unknown
    }

    /// Reads the start time right before a signal, so a PID reused since
    /// the last snapshot is never hit.
    private static func check(_ identity: ProcessIdentity) -> IdentityCheck {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return errno == ESRCH ? .gone : .unknown
        }
        let same = info.pbi_start_tvsec == identity.startTimeSeconds && info.pbi_start_tvusec == identity.startTimeMicroseconds
        return same ? .same : .recycled
    }
}
