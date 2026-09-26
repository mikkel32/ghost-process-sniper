import Dispatch
import Foundation

public enum KillExitEventKind: String, Codable, Sendable {
    case exit
    case fork
    case exec
    case signal
    case unavailable
}

public struct KillExitEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(operationID.rawValue)-\(pid)-\(kind.rawValue)-\(Int(observedAt.timeIntervalSince1970 * 1_000))" }

    public let operationID: KillOperationID
    public let pid: Int32
    public let identity: ProcessIdentity
    public let kind: KillExitEventKind
    public let message: String
    public let observedAt: Date

    public init(
        operationID: KillOperationID,
        pid: Int32,
        identity: ProcessIdentity,
        kind: KillExitEventKind,
        message: String,
        observedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.pid = pid
        self.identity = identity
        self.kind = kind
        self.message = message
        self.observedAt = observedAt
    }
}

public enum KillWatcherHintKind: String, Codable, Sendable {
    case exit
    case fork
    case exec
    case signal
    case unavailable

    public var requiresCompleteVerification: Bool {
        switch self {
        case .fork, .exec, .signal:
            true
        case .exit, .unavailable:
            false
        }
    }
}

public struct KillWatcherHint: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(operationID.rawValue)-\(pid)-\(kind.rawValue)-\(Int(observedAt.timeIntervalSince1970 * 1_000))" }

    public let operationID: KillOperationID
    public let pid: Int32
    public let identity: ProcessIdentity
    public let kind: KillWatcherHintKind
    public let message: String
    public let observedAt: Date

    public init(
        operationID: KillOperationID,
        pid: Int32,
        identity: ProcessIdentity,
        kind: KillWatcherHintKind,
        message: String,
        observedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.pid = pid
        self.identity = identity
        self.kind = kind
        self.message = message
        self.observedAt = observedAt
    }

    public var exitEvent: KillExitEvent {
        KillExitEvent(
            operationID: operationID,
            pid: pid,
            identity: identity,
            kind: KillExitEventKind(rawValue: kind.rawValue) ?? .unavailable,
            message: message,
            observedAt: observedAt
        )
    }
}

private final class KillExitWatcherToken: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceProcess] = []

    func append(_ source: DispatchSourceProcess) {
        lock.lock()
        sources.append(source)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let current = sources
        sources.removeAll()
        lock.unlock()
        for source in current {
            source.cancel()
        }
    }
}

/// Streams kernel exit, fork, exec and signal hints for the targets of one stop.
public struct KillExitWatcher: Sendable {
    public static func watchHints(
        operationID: KillOperationID,
        targets: [KillTarget],
        maxTargets: Int = 128
    ) -> AsyncStream<KillWatcherHint> {
        AsyncStream { continuation in
            guard !targets.isEmpty else {
                continuation.finish()
                return
            }

            let token = KillExitWatcherToken()
            let queue = DispatchQueue(label: "com.local.GhostProcessSniper.kill-exit-watcher", qos: .utility)
            for target in targets.prefix(max(0, maxTargets)) {
                let source = DispatchSource.makeProcessSource(
                    identifier: pid_t(target.pid),
                    eventMask: [.exit, .fork, .exec, .signal],
                    queue: queue
                )
                source.setEventHandler {
                    let event = DispatchSource.ProcessEvent(rawValue: source.data)
                    let hints = Self.hints(
                        from: event,
                        operationID: operationID,
                        target: target
                    )
                    for hint in hints {
                        continuation.yield(hint)
                    }
                }
                source.setCancelHandler {}
                token.append(source)
                source.resume()
            }
            continuation.onTermination = { _ in
                token.cancel()
            }
        }
    }

    private static func hints(
        from event: DispatchSource.ProcessEvent,
        operationID: KillOperationID,
        target: KillTarget
    ) -> [KillWatcherHint] {
        var hints: [KillWatcherHint] = []
        if event.contains(.exit) {
            hints.append(
                KillWatcherHint(
                    operationID: operationID,
                    pid: target.pid,
                    identity: target.identity,
                    kind: .exit,
                    message: "Exit observed for \(target.name)."
                )
            )
        }
        if event.contains(.fork) {
            hints.append(
                KillWatcherHint(
                    operationID: operationID,
                    pid: target.pid,
                    identity: target.identity,
                    kind: .fork,
                    message: "Fork hint observed for \(target.name); complete verification will refresh the tree."
                )
            )
        }
        if event.contains(.exec) {
            hints.append(
                KillWatcherHint(
                    operationID: operationID,
                    pid: target.pid,
                    identity: target.identity,
                    kind: .exec,
                    message: "Exec hint observed for \(target.name); identity verification remains authoritative."
                )
            )
        }
        if event.contains(.signal) {
            hints.append(
                KillWatcherHint(
                    operationID: operationID,
                    pid: target.pid,
                    identity: target.identity,
                    kind: .signal,
                    message: "Signal hint observed for \(target.name)."
                )
            )
        }
        if hints.isEmpty {
            hints.append(
                KillWatcherHint(
                    operationID: operationID,
                    pid: target.pid,
                    identity: target.identity,
                    kind: .unavailable,
                    message: "Watcher reported an unavailable process event for \(target.name)."
                )
            )
        }
        return hints
    }
}

public struct KillSignalWave: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(stage)-\(signalName)-\(Int(startedAt.timeIntervalSince1970 * 1_000))" }

    public let stage: String
    public let signalName: String
    public let targetPIDs: [Int32]
    public let startedAt: Date
    public let finishedAt: Date
    public let sentCount: Int
    public let failedCount: Int

    public init(
        stage: String,
        signalName: String,
        targetPIDs: [Int32],
        startedAt: Date = Date(),
        finishedAt: Date = Date(),
        sentCount: Int,
        failedCount: Int
    ) {
        self.stage = stage
        self.signalName = signalName
        self.targetPIDs = targetPIDs.sorted()
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sentCount = sentCount
        self.failedCount = failedCount
    }
}

public struct KillGraceResult: Codable, Equatable, Sendable {
    public let waitedSeconds: TimeInterval
    public let endedEarly: Bool
    public let skipForceRequested: Bool

    public static let empty = KillGraceResult(waitedSeconds: 0, endedEarly: false, skipForceRequested: false)
}

public struct KillGraceCoordinator: Sendable {
    public init() {}

    public func wait(
        seconds: TimeInterval,
        sleeper: @escaping @Sendable (UInt64) async -> Void,
        skipForceCheck: (@Sendable () async -> Bool)? = nil,
        shouldEndEarly: @escaping @Sendable () async -> Bool
    ) async -> KillGraceResult {
        guard seconds > 0 else {
            return KillGraceResult(
                waitedSeconds: 0,
                endedEarly: await shouldEndEarly(),
                skipForceRequested: await skipForceCheck?() ?? false
            )
        }

        let started = Date()
        let step = min(0.075, max(0.02, seconds / 8))
        while Date().timeIntervalSince(started) < seconds {
            if await skipForceCheck?() == true {
                return KillGraceResult(
                    waitedSeconds: Date().timeIntervalSince(started),
                    endedEarly: true,
                    skipForceRequested: true
                )
            }
            if await shouldEndEarly() {
                return KillGraceResult(
                    waitedSeconds: Date().timeIntervalSince(started),
                    endedEarly: true,
                    skipForceRequested: false
                )
            }
            await sleeper(UInt64(step * 1_000_000_000))
        }
        return KillGraceResult(
            waitedSeconds: Date().timeIntervalSince(started),
            endedEarly: false,
            skipForceRequested: await skipForceCheck?() ?? false
        )
    }
}

public struct KillVerificationPlanner: Sendable {
    public init() {}

    public func mode(
        stage: String,
        hints: [KillWatcherHint],
        targetMismatch: Bool = false
    ) -> KillVerificationMode {
        if stage == "confirm" {
            return .completeArena
        }
        if targetMismatch || hints.contains(where: { $0.kind.requiresCompleteVerification }) {
            return .eventTriggeredComplete
        }
        return .targetOnly
    }
}

public struct KillReactorReport: Codable, Equatable, Sendable {
    public let phaseTimingsMilliseconds: [String: Double]
    public let watcherHints: [KillWatcherHint]
    public let signalWaves: [KillSignalWave]
    public let earlyExitSavingsSeconds: TimeInterval
    public let verificationModeCounts: [String: Int]
    public let arenaReuseCount: Int
    public let calibratedGracefulOdds: Double
    public let calibratedForceOdds: Double
    public let calibratedSurvivorOdds: Double

    public static let empty = KillReactorReport(
        phaseTimingsMilliseconds: [:],
        watcherHints: [],
        signalWaves: [],
        earlyExitSavingsSeconds: 0,
        verificationModeCounts: [:],
        arenaReuseCount: 0,
        calibratedGracefulOdds: 0,
        calibratedForceOdds: 0,
        calibratedSurvivorOdds: 0
    )

    public init(
        phaseTimingsMilliseconds: [String: Double],
        watcherHints: [KillWatcherHint],
        signalWaves: [KillSignalWave],
        earlyExitSavingsSeconds: TimeInterval,
        verificationModeCounts: [String: Int],
        arenaReuseCount: Int,
        calibratedGracefulOdds: Double,
        calibratedForceOdds: Double,
        calibratedSurvivorOdds: Double
    ) {
        self.phaseTimingsMilliseconds = phaseTimingsMilliseconds
        self.watcherHints = watcherHints
        self.signalWaves = signalWaves
        self.earlyExitSavingsSeconds = max(0, earlyExitSavingsSeconds)
        self.verificationModeCounts = verificationModeCounts
        self.arenaReuseCount = max(0, arenaReuseCount)
        self.calibratedGracefulOdds = min(1, max(0, calibratedGracefulOdds))
        self.calibratedForceOdds = min(1, max(0, calibratedForceOdds))
        self.calibratedSurvivorOdds = min(1, max(0, calibratedSurvivorOdds))
    }
}

public actor KillInterventionReactor {
    private let operationID: KillOperationID
    private var phaseStarts: [String: Date] = [:]
    private var phaseTimings: [String: Double] = [:]
    private var hints: [KillWatcherHint] = []
    private var waves: [KillSignalWave] = []
    private var verificationModeCounts: [String: Int] = [:]
    private var earlyExitSavingsSeconds: TimeInterval = 0
    private var arenaReuseCount = 0
    private var calibratedGracefulOdds = 0.0
    private var calibratedForceOdds = 0.0
    private var calibratedSurvivorOdds = 0.0

    public init(operationID: KillOperationID) {
        self.operationID = operationID
    }

    public func beginPhase(_ name: String, at date: Date = Date()) {
        phaseStarts[name] = date
    }

    public func endPhase(_ name: String, at date: Date = Date()) {
        guard let started = phaseStarts.removeValue(forKey: name) else {
            return
        }
        phaseTimings[name] = max(0, date.timeIntervalSince(started) * 1_000)
    }

    public func recordHint(_ hint: KillWatcherHint) {
        guard hint.operationID == operationID else {
            return
        }
        hints.append(hint)
    }

    public func recordWave(_ wave: KillSignalWave) {
        waves.append(wave)
    }

    public func recordVerification(mode: KillVerificationMode) {
        verificationModeCounts[mode.rawValue, default: 0] += 1
    }

    public func recordEarlyExitSavings(_ seconds: TimeInterval) {
        earlyExitSavingsSeconds += max(0, seconds)
    }

    public func recordArenaStats(_ stats: KillGraphArenaStats) {
        arenaReuseCount += stats.arenaReuseCount
    }

    public func recordCalibration(_ simulation: KillStrategySimulation) {
        calibratedGracefulOdds = simulation.expectedGracefulSuccess
        calibratedForceOdds = simulation.forceProbability
        calibratedSurvivorOdds = simulation.survivorRisk
    }

    public func hintSnapshot() -> [KillWatcherHint] {
        hints
    }

    public func report() -> KillReactorReport {
        KillReactorReport(
            phaseTimingsMilliseconds: phaseTimings,
            watcherHints: hints,
            signalWaves: waves,
            earlyExitSavingsSeconds: earlyExitSavingsSeconds,
            verificationModeCounts: verificationModeCounts,
            arenaReuseCount: arenaReuseCount,
            calibratedGracefulOdds: calibratedGracefulOdds,
            calibratedForceOdds: calibratedForceOdds,
            calibratedSurvivorOdds: calibratedSurvivorOdds
        )
    }
}

public struct KillTargetStateStore: Equatable, Sendable {
    private var states: [Int32: KillTargetState]

    public init(states: [Int32: KillTargetState] = [:]) {
        self.states = states
    }

    public subscript(pid: Int32) -> KillTargetState? {
        states[pid]
    }

    public mutating func update(pid: Int32, state: KillTargetState) {
        states[pid] = state
    }

    public var snapshot: [Int32: KillTargetState] {
        states
    }
}

public actor KillOperationStateMachine {
    private let operationID: KillOperationID
    private var stateStore = KillTargetStateStore()
    private var exitEvents: [KillExitEvent] = []

    public init(operationID: KillOperationID) {
        self.operationID = operationID
    }

    public func recordExit(_ event: KillExitEvent) -> KillOperationEvent {
        exitEvents.append(event)
        stateStore.update(pid: event.pid, state: .terminated)
        return KillOperationEvent(
            operationID: operationID,
            kind: .targetUpdated,
            pid: event.pid,
            targetState: .terminated,
            message: event.message,
            createdAt: event.observedAt
        )
    }

    public func exitEventSnapshot() -> [KillExitEvent] {
        exitEvents
    }

    public func targetStates() -> [Int32: KillTargetState] {
        stateStore.snapshot
    }
}
