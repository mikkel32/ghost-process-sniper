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

public struct DefaultProcessLookup: ProcessLookup {
    private let sampler: ProcessSampling

    public init(sampler: ProcessSampling = NativeProcessSampler()) {
        self.sampler = sampler
    }

    public func processes() async throws -> [ProcessMetrics] {
        try await sampler.sample()
    }

    public func killSnapshot(policy: KillSnapshotPolicy) async throws -> KillProcessSnapshot {
        let started = Date()
        let budget = ScannerBudget(
            targetMilliseconds: 18,
            optionalMilliseconds: 0,
            maxTelemetryRefreshes: 0,
            maxForensicsRefreshes: 0,
            negativeForensicsTTL: 300,
            staleTelemetryGrace: 300
        )
        let batch = try await sampler.sample(
            plan: SamplingPlan(
                sampledAt: started,
                performanceMode: .batterySaver,
                commandRefreshInterval: 3_600,
                includeForensicsFor: [],
                includeForensicsForPIDs: [],
                forceCommandRefresh: false,
                allowsOptionalForensics: false,
                maxForensicsPerRefresh: 0,
                reason: "kill-\(policy.rawValue)",
                scannerBudget: budget,
                lanePriorities: [.cheapMetrics, .telemetryCache, .deadlineSkipped]
            )
        )
        return KillProcessSnapshot(
            processes: batch.processes,
            sampledAt: batch.sampledAt,
            policy: policy,
            elapsedMilliseconds: Date().timeIntervalSince(started) * 1_000,
            usedCheapPath: true,
            expensiveCallCount: batch.stats.expensiveCallCount,
            arena: KillGraphArena(processes: batch.processes.map { KillProcessLite(process: $0) }, sampledAt: batch.sampledAt, pidReadCount: batch.processes.count)
        )
    }
}

public struct SignalFailure: Error, Equatable, Sendable {
    public let pid: Int32
    public let signal: Int32
    public let errnoCode: Int32
    public let message: String

    public init(pid: Int32, signal: Int32, errnoCode: Int32, message: String) {
        self.pid = pid
        self.signal = signal
        self.errnoCode = errnoCode
        self.message = message
    }
}

extension SignalFailure: LocalizedError {
    public var errorDescription: String? { message }
}

public protocol ProcessSignaling: Sendable {
    var usesDarwinProcessNamespace: Bool { get }
    func send(signal: Int32, to pid: Int32) throws
    func exists(pid: Int32) -> Bool
    /// Asks a GUI app to quit the way ⌘Q does. Returns false when the
    /// process is not a running app, so the caller falls back to signals.
    func requestQuit(pid: Int32) async -> Bool
}

public extension ProcessSignaling {
    var usesDarwinProcessNamespace: Bool { false }
    func requestQuit(pid: Int32) async -> Bool { false }
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

    public func exists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public func requestQuit(pid: Int32) async -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return app.terminate()
        }
    }
}
