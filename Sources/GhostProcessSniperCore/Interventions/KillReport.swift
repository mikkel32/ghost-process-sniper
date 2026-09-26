import Foundation

public struct KillReport: Equatable, Sendable {
    public let operationID: KillOperationID
    public let displayName: String
    public let rootPID: Int32
    public var gracefulPIDs: [Int32]
    public var forcedPIDs: [Int32]
    public var deniedPIDs: [Int32]
    public var stalePIDs: [Int32]
    public var exitedBeforeSignalPIDs: [Int32]
    public var failures: [String]
    public var targetResults: [KillTarget]
    public var survivorPIDs: [Int32]
    public var recycledPIDs: [Int32]
    public var attempts: [KillAttempt]
    public var timeline: KillExecutionTimeline
    public var estimatedMemoryReclaimBytes: UInt64
    public var estimatedCPUReclaimPercent: Double
    public var realizedMemoryReclaimBytes: UInt64
    public var skipForceRequested: Bool
    public var verificationPasses: [KillVerificationPass]
    public var eventHistory: [KillOperationEvent]
    public var strategyUsed: KillStrategy
    public var scopeUsed: KillScope
    public var targetDiff: KillTargetDiff
    public var learning: KillOutcomeLearning
    public var finalGraphDelta: KillGraphDelta
    public var eventCoalescingCount: Int
    public var strategyHistoryInput: KillHistorySummary
    public var performanceReport: KillPerformanceReport
    public var watcherEvents: [KillExitEvent]
    public var verificationSnapshotCount: Int
    public var graphSliceDeltas: [KillGraphDelta]
    public var signalOutcomeCounts: [String: Int]
    public var calibratedReclaimBytes: UInt64
    public var reactorReport: KillReactorReport
    /// New processes that replaced the stopped ones: a supervisor restarted them.
    public var respawnedPIDs: [Int32] = []
    public var respawnedBy: String?

    public var partiallySucceeded: Bool {
        !gracefulPIDs.isEmpty || !forcedPIDs.isEmpty
    }

    public var succeeded: Bool {
        partiallySucceeded && deniedPIDs.isEmpty && survivorPIDs.isEmpty && failures.isEmpty
    }

    public var summary: String {
        if !failures.isEmpty && !partiallySucceeded {
            return failures.joined(separator: "\n")
        }
        if !respawnedPIDs.isEmpty {
            let pids = respawnedPIDs.sorted().map(String.init).joined(separator: ", ")
            return "Stopped, but \(respawnedBy ?? "a supervisor") started it again (PID \(pids)). Stop \(respawnedBy ?? "the supervisor") instead."
        }
        if !survivorPIDs.isEmpty {
            let pids = survivorPIDs.sorted().map(String.init).joined(separator: ", ")
            return skipForceRequested
                ? "Still running: PID \(pids). It may be waiting on you, such as a save prompt; force-stop only if you are sure."
                : "Survivors: \(pids)."
        }
        if !forcedPIDs.isEmpty {
            return "Force-killed \(forcedPIDs.count) stubborn process\(forcedPIDs.count == 1 ? "" : "es")."
        }
        if !gracefulPIDs.isEmpty {
            let locked = Set(deniedPIDs).count
            let suffix = locked > 0 ? " \(locked) locked skipped." : ""
            return "Terminated \(gracefulPIDs.count) process\(gracefulPIDs.count == 1 ? "" : "es").\(suffix)"
        }
        if !deniedPIDs.isEmpty {
            return "Locked: \(deniedPIDs.count) protected process\(deniedPIDs.count == 1 ? "" : "es")."
        }
        if stalePIDs.contains(rootPID) {
            return "Already gone."
        }
        if !stalePIDs.isEmpty || !recycledPIDs.isEmpty {
            return "No safe live targets. Stale or recycled PIDs skipped."
        }
        return "No owned live processes matched this kill plan."
    }

    public var diagnosticText: String {
        var lines = [
            "Ghost Process Sniper Kill Report",
            "Family: \(displayName)",
            "Root PID: \(rootPID)",
            "Operation: \(operationID.rawValue)",
            "Summary: \(summary)",
            "Duration: \(Int(timeline.totalMilliseconds.rounded())) ms",
            "Estimated reclaim: \(RadarFormat.bytes(estimatedMemoryReclaimBytes)), \(Int(estimatedCPUReclaimPercent.rounded()))% CPU",
            "Realized reclaim: \(RadarFormat.bytes(realizedMemoryReclaimBytes))",
            "Strategy: \(strategyUsed.label)",
            "Scope: \(scopeUsed.label)",
            "Target drift: \(targetDiff.summary)",
            "Graph delta: \(finalGraphDelta.summary)",
            "Kill performance: \(Int(performanceReport.snapshotMilliseconds.rounded()))ms, graph \(performanceReport.graphReadCount), heavy \(performanceReport.heavyMetricReadCount), converted \(performanceReport.targetConversionCount), cache \(performanceReport.cacheStatus.label)",
            "Arena: \(performanceReport.arenaStats.processCount) processes, build \(Int(performanceReport.arenaStats.arenaBuildMilliseconds.rounded())) ms, adjacency \(Int(performanceReport.arenaStats.adjacencyBuildMilliseconds.rounded())) ms",
            "Watcher exits: \(watcherEvents.count), verification snapshots: \(verificationSnapshotCount)",
            "Watcher hints: \(reactorReport.watcherHints.count), early grace saved \(String(format: "%.2f", reactorReport.earlyExitSavingsSeconds))s",
            "Verification modes: \(reactorReport.verificationModeCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ").ifEmpty("none"))",
            "Signal waves: \(reactorReport.signalWaves.count), arena reuse \(reactorReport.arenaReuseCount), slice cache \(reactorReport.sliceCacheHitCount)",
            "Calibrated reclaim: \(RadarFormat.bytes(calibratedReclaimBytes))",
            "Force skipped: \(skipForceRequested ? "yes" : "no")",
            "Respawned: \(respawnedPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))\(respawnedBy.map { " by \($0)" } ?? "")",
            "Graceful: \(gracefulPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))",
            "Forced: \(forcedPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))",
            "Survivors: \(survivorPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))",
            "Locked: \(deniedPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))",
            "Stale: \(stalePIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))",
            "Recycled: \(recycledPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))"
        ]
        if !verificationPasses.isEmpty {
            lines.append("Verification:")
            for pass in verificationPasses {
                lines.append("- \(pass.stage): live \(pass.livePIDs.map(String.init).joined(separator: ", ").ifEmpty("none")), recycled \(pass.recycledPIDs.map(String.init).joined(separator: ", ").ifEmpty("none")), exited \(pass.exitedPIDs.map(String.init).joined(separator: ", ").ifEmpty("none"))")
            }
        }
        if !attempts.isEmpty {
            lines.append("Attempts:")
            for attempt in attempts {
                lines.append("- PID \(attempt.pid) \(attempt.signalName) \(attempt.succeeded ? "ok" : "failed") \(attempt.message)")
            }
        }
        if !eventHistory.isEmpty {
            lines.append("Events:")
            for event in eventHistory.prefix(24) {
                lines.append("- \(event.kind.rawValue) \(event.pid.map { "PID \($0)" } ?? "") \(event.message)")
            }
        }
        if !watcherEvents.isEmpty {
            lines.append("Exit watcher:")
            for event in watcherEvents.prefix(24) {
                lines.append("- PID \(event.pid) \(event.kind.rawValue): \(event.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public init(
        operationID: KillOperationID = KillOperationID(),
        displayName: String,
        rootPID: Int32,
        gracefulPIDs: [Int32] = [],
        forcedPIDs: [Int32] = [],
        deniedPIDs: [Int32] = [],
        stalePIDs: [Int32] = [],
        exitedBeforeSignalPIDs: [Int32] = [],
        failures: [String] = [],
        targetResults: [KillTarget] = [],
        survivorPIDs: [Int32] = [],
        recycledPIDs: [Int32] = [],
        attempts: [KillAttempt] = [],
        timeline: KillExecutionTimeline = .empty,
        estimatedMemoryReclaimBytes: UInt64 = 0,
        estimatedCPUReclaimPercent: Double = 0,
        realizedMemoryReclaimBytes: UInt64 = 0,
        skipForceRequested: Bool = false,
        verificationPasses: [KillVerificationPass] = [],
        eventHistory: [KillOperationEvent] = [],
        strategyUsed: KillStrategy = .standard,
        scopeUsed: KillScope = .ownedFamily,
        targetDiff: KillTargetDiff = .empty,
        learning: KillOutcomeLearning = .empty,
        finalGraphDelta: KillGraphDelta = .empty,
        eventCoalescingCount: Int = 0,
        strategyHistoryInput: KillHistorySummary = .empty,
        performanceReport: KillPerformanceReport = .empty,
        watcherEvents: [KillExitEvent] = [],
        verificationSnapshotCount: Int = 0,
        graphSliceDeltas: [KillGraphDelta] = [],
        signalOutcomeCounts: [String: Int] = [:],
        calibratedReclaimBytes: UInt64 = 0,
        reactorReport: KillReactorReport = .empty
    ) {
        self.operationID = operationID
        self.displayName = displayName
        self.rootPID = rootPID
        self.gracefulPIDs = gracefulPIDs
        self.forcedPIDs = forcedPIDs
        self.deniedPIDs = deniedPIDs
        self.stalePIDs = stalePIDs
        self.exitedBeforeSignalPIDs = exitedBeforeSignalPIDs
        self.failures = failures
        self.targetResults = targetResults
        self.survivorPIDs = survivorPIDs
        self.recycledPIDs = recycledPIDs
        self.attempts = attempts
        self.timeline = timeline
        self.estimatedMemoryReclaimBytes = estimatedMemoryReclaimBytes
        self.estimatedCPUReclaimPercent = estimatedCPUReclaimPercent
        self.realizedMemoryReclaimBytes = realizedMemoryReclaimBytes
        self.skipForceRequested = skipForceRequested
        self.verificationPasses = verificationPasses
        self.eventHistory = eventHistory
        self.strategyUsed = strategyUsed
        self.scopeUsed = scopeUsed
        self.targetDiff = targetDiff
        self.learning = learning
        self.finalGraphDelta = finalGraphDelta
        self.eventCoalescingCount = eventCoalescingCount
        self.strategyHistoryInput = strategyHistoryInput
        self.performanceReport = performanceReport
        self.watcherEvents = watcherEvents
        self.verificationSnapshotCount = verificationSnapshotCount
        self.graphSliceDeltas = graphSliceDeltas
        self.signalOutcomeCounts = signalOutcomeCounts
        self.calibratedReclaimBytes = calibratedReclaimBytes
        self.reactorReport = reactorReport
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
