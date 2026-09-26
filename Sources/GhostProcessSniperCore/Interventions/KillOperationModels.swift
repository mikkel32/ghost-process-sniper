import Darwin
import Foundation

public struct KillOperationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

public enum KillOperationEventKind: String, Codable, Sendable {
    case queued
    case preflight
    case targetUpdated
    case signaled
    case graceWaiting
    case forcePending
    case forceSkipped
    case verified
    case completed
    case failed
}

public struct KillOperationEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let operationID: KillOperationID
    public let kind: KillOperationEventKind
    public let pid: Int32?
    public let signalName: String?
    public let targetState: KillTargetState?
    public let message: String
    public let createdAt: Date
    /// Set on the graceful wait only: how long it may last and when it ends
    /// at the latest, for a countdown.
    public let waitSeconds: TimeInterval?
    public let deadline: Date?

    public init(
        id: UUID = UUID(),
        operationID: KillOperationID,
        kind: KillOperationEventKind,
        pid: Int32? = nil,
        signalName: String? = nil,
        targetState: KillTargetState? = nil,
        message: String,
        createdAt: Date = Date(),
        waitSeconds: TimeInterval? = nil,
        deadline: Date? = nil
    ) {
        self.id = id
        self.operationID = operationID
        self.kind = kind
        self.pid = pid
        self.signalName = signalName
        self.targetState = targetState
        self.message = message
        self.createdAt = createdAt
        self.waitSeconds = waitSeconds
        self.deadline = deadline
    }
}

/// What the user asks of a running stop. Holding force and ending a wait
/// are separate: holding force must never cut a graceful wait short.
public actor KillOperationControl {
    private var forceHeld = false
    private var waitingStopped = false

    public init() {}

    /// Never escalate to force. The graceful waits still run in full.
    public func holdForce() {
        forceHeld = true
    }

    public func isForceHeld() -> Bool {
        forceHeld
    }

    /// Ends the wait in progress, and any later one, and holds force.
    public func stopWaiting() {
        waitingStopped = true
        forceHeld = true
    }

    public func shouldStopWaiting() -> Bool {
        waitingStopped
    }
}

public actor KillOperationRunner {
    public init() {}

    public func runReport(
        plan: KillPlan,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval = 2,
        control: KillOperationControl = KillOperationControl(),
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        await killer.kill(
            plan: plan,
            forceKillDelay: forceKillDelay,
            stopWaitingCheck: { await control.shouldStopWaiting() },
            forceHeldCheck: { await control.isForceHeld() },
            eventSink: eventSink
        )
    }
}

public struct KillExecutionTimeline: Equatable, Sendable {
    public let preflightMilliseconds: Double
    public let signalMilliseconds: Double
    public let verificationMilliseconds: Double
    public let totalMilliseconds: Double

    public static let empty = KillExecutionTimeline(
        preflightMilliseconds: 0,
        signalMilliseconds: 0,
        verificationMilliseconds: 0,
        totalMilliseconds: 0
    )

    public init(
        preflightMilliseconds: Double,
        signalMilliseconds: Double,
        verificationMilliseconds: Double,
        totalMilliseconds: Double
    ) {
        self.preflightMilliseconds = preflightMilliseconds
        self.signalMilliseconds = signalMilliseconds
        self.verificationMilliseconds = verificationMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

public struct KillPerformanceReport: Codable, Equatable, Sendable {
    public let snapshotMilliseconds: Double
    public let graphReadCount: Int
    public let heavyMetricReadCount: Int
    public let targetConversionCount: Int
    public let didHitBudget: Bool
    public let skippedOptionalWorkCount: Int
    public let arenaStats: KillGraphArenaStats
    public let watcherHintCount: Int
    public let earlyGraceExitCount: Int
    public let targetOnlyVerificationCount: Int
    public let completeVerificationCount: Int
    public let eventTriggeredVerificationCount: Int

    public static let empty = KillPerformanceReport(
        snapshotMilliseconds: 0,
        graphReadCount: 0,
        heavyMetricReadCount: 0,
        targetConversionCount: 0,
        didHitBudget: false,
        skippedOptionalWorkCount: 0,
        arenaStats: .empty,
        watcherHintCount: 0,
        earlyGraceExitCount: 0,
        targetOnlyVerificationCount: 0,
        completeVerificationCount: 0,
        eventTriggeredVerificationCount: 0
    )

    public init(
        snapshotMilliseconds: Double,
        graphReadCount: Int,
        heavyMetricReadCount: Int,
        targetConversionCount: Int,
        didHitBudget: Bool,
        skippedOptionalWorkCount: Int = 0,
        arenaStats: KillGraphArenaStats = .empty,
        watcherHintCount: Int = 0,
        earlyGraceExitCount: Int = 0,
        targetOnlyVerificationCount: Int = 0,
        completeVerificationCount: Int = 0,
        eventTriggeredVerificationCount: Int = 0
    ) {
        self.snapshotMilliseconds = snapshotMilliseconds
        self.graphReadCount = graphReadCount
        self.heavyMetricReadCount = heavyMetricReadCount
        self.targetConversionCount = targetConversionCount
        self.didHitBudget = didHitBudget
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
        self.arenaStats = arenaStats
        self.watcherHintCount = watcherHintCount
        self.earlyGraceExitCount = earlyGraceExitCount
        self.targetOnlyVerificationCount = targetOnlyVerificationCount
        self.completeVerificationCount = completeVerificationCount
        self.eventTriggeredVerificationCount = eventTriggeredVerificationCount
    }

    public init(snapshot: KillProcessSnapshot) {
        self.init(
            snapshotMilliseconds: snapshot.elapsedMilliseconds,
            graphReadCount: snapshot.graphReadCount,
            heavyMetricReadCount: snapshot.heavyMetricReadCount,
            targetConversionCount: snapshot.targetConversionCount,
            didHitBudget: snapshot.didHitBudget,
            skippedOptionalWorkCount: snapshot.skippedOptionalWorkCount,
            arenaStats: snapshot.arena?.stats ?? .empty
        )
    }
}

public struct KillOperationRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: KillOperationID
    public let signatureID: String?
    public let displayName: String
    public let rootPID: Int32
    public let summary: String
    public let estimatedMemoryReclaimBytes: UInt64
    public let realizedMemoryReclaimBytes: UInt64
    public let gracefulCount: Int
    public let forcedCount: Int
    public let survivorCount: Int
    public let lockedCount: Int
    public let staleCount: Int
    public let recycledCount: Int
    public let durationMilliseconds: Double
    public let createdAt: Date
    public let strategy: KillStrategy
    public let scope: KillScope

    public init(
        id: KillOperationID,
        signatureID: String?,
        displayName: String,
        rootPID: Int32,
        summary: String,
        estimatedMemoryReclaimBytes: UInt64,
        realizedMemoryReclaimBytes: UInt64,
        gracefulCount: Int,
        forcedCount: Int,
        survivorCount: Int,
        lockedCount: Int,
        staleCount: Int,
        recycledCount: Int,
        durationMilliseconds: Double,
        createdAt: Date,
        strategy: KillStrategy = .standard,
        scope: KillScope = .ownedFamily
    ) {
        self.id = id
        self.signatureID = signatureID
        self.displayName = displayName
        self.rootPID = rootPID
        self.summary = summary
        self.estimatedMemoryReclaimBytes = estimatedMemoryReclaimBytes
        self.realizedMemoryReclaimBytes = realizedMemoryReclaimBytes
        self.gracefulCount = gracefulCount
        self.forcedCount = forcedCount
        self.survivorCount = survivorCount
        self.lockedCount = lockedCount
        self.staleCount = staleCount
        self.recycledCount = recycledCount
        self.durationMilliseconds = durationMilliseconds
        self.createdAt = createdAt
        self.strategy = strategy
        self.scope = scope
    }

    public init(report: KillReport, family: ProcessFamily?, createdAt: Date = Date()) {
        self.init(
            id: report.operationID,
            signatureID: family?.signature.id,
            displayName: report.displayName,
            rootPID: report.rootPID,
            summary: report.summary,
            estimatedMemoryReclaimBytes: report.estimatedMemoryReclaimBytes,
            realizedMemoryReclaimBytes: report.realizedMemoryReclaimBytes,
            gracefulCount: report.gracefulPIDs.count,
            forcedCount: report.forcedPIDs.count,
            survivorCount: report.survivorPIDs.count,
            lockedCount: report.deniedPIDs.count,
            staleCount: report.stalePIDs.count,
            recycledCount: report.recycledPIDs.count,
            durationMilliseconds: report.timeline.totalMilliseconds,
            createdAt: createdAt,
            strategy: report.strategyUsed,
            scope: report.scopeUsed
        )
    }
}
