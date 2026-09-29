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
    public var finalGraphDelta: KillGraphDelta
    public var performanceReport: KillPerformanceReport
    public var watcherEvents: [KillExitEvent]
    public var verificationSnapshotCount: Int
    public var calibratedReclaimBytes: UInt64
    public var reactorReport: KillReactorReport
    /// New processes that replaced the stopped ones: a supervisor restarted them.
    public var respawnedPIDs: [Int32] = []
    public var respawnedBy: String?
    /// Plain follow-ups worth knowing, such as a file watcher that will
    /// start the app again on the next save.
    public var notes: [String] = []
    /// PIDs macOS refused to signal (EPERM), tried once each.
    public var signalDeniedPIDs: [Int32] = []
    /// The app accepted the quit request but was still open at the end,
    /// usually because it is showing a save prompt.
    public var appStillOpen = false
    /// Forced the survivors of an earlier held stop; not a new outcome to learn from.
    public var isForceFollowUp = false
    /// The parent an already-exited (zombie) target waits on to collect it.
    public var zombieParentName: String?
    /// Survivors already exiting in the kernel, held up by disk or network I/O.
    public var stuckExitingPIDs: [Int32] = []
    /// Processes that started after the stop was approved. Stopped with the
    /// rest, or, with force held, only reported (state `.locked`).
    public var lateTargets: [KillTarget] = []
    /// Processes the stop left alone that lost their parent to it and now
    /// run on under launchd.
    public var leftRunning: [KillTarget] = []
    /// Processes frozen with SIGSTOP right before SIGKILL.
    public var frozenCount = 0
    /// New processes kept appearing faster than the force stage could look.
    public var forkStorm = false
    /// How long the graceful wait lasted, and whether it ended because every
    /// target exited (rather than running out): the family's exit time.
    public var graceWaitedSeconds: TimeInterval = 0
    public var graceEndedEarly = false
    /// Every target was in a debugger, so the graceful wait watched nothing
    /// and says nothing about how the family exits.
    public var graceWatchedNothing = false
    /// The launchd job booted out instead of signalling the root.
    public var launchdBootout: LaunchdBootout?
    /// The launchd job that runs the root, when one was found; it names the
    /// command that keeps a restarted job stopped.
    public var launchdJob: LaunchdJob?
    /// Whether the ports the workload listened on are really free now.
    public var portOutcomes: [KillPortOutcome] = []

    public var partiallySucceeded: Bool {
        !gracefulPIDs.isEmpty || !forcedPIDs.isEmpty
    }

    public var succeeded: Bool {
        partiallySucceeded && deniedPIDs.isEmpty && survivorPIDs.isEmpty && failures.isEmpty
    }

    /// The outcome in plain words; see `narrative` for its parts.
    public var summary: String {
        narrative.text
    }

    public var diagnosticText: String {
        let story = narrative
        var lines = ["Ghost Process Sniper Stop Report", story.headline]
        lines += story.nextStep.map { ["Next: \($0)"] } ?? []
        lines += story.details
        let outcomes = KillOutcomeRows.make(report: self)
        if !outcomes.isEmpty {
            lines.append("Processes:")
            lines += outcomes.map { "- \($0.name) (PID \($0.pid)) \u{2192} \($0.state.label), \($0.reason)" }
        }
        lines += [
            "Diagnostics:",
            "Family: \(displayName)",
            "Root PID: \(rootPID)",
            "Operation: \(operationID.rawValue)",
            "Duration: \(Int(timeline.totalMilliseconds.rounded())) ms",
            "Estimated reclaim: \(RadarFormat.bytes(estimatedMemoryReclaimBytes)), \(Int(estimatedCPUReclaimPercent.rounded()))% CPU",
            "Realized reclaim: \(RadarFormat.bytes(realizedMemoryReclaimBytes))",
            "Strategy: \(strategyUsed.label)",
            "Scope: \(scopeUsed.label)",
            "Target drift: \(targetDiff.summary)",
            "Graph delta: \(finalGraphDelta.summary)",
            "Stop performance: \(Int(performanceReport.snapshotMilliseconds.rounded()))ms, graph \(performanceReport.graphReadCount), heavy \(performanceReport.heavyMetricReadCount), converted \(performanceReport.targetConversionCount)",
            "Arena: \(performanceReport.arenaStats.processCount) processes, build \(Int(performanceReport.arenaStats.arenaBuildMilliseconds.rounded())) ms, adjacency \(Int(performanceReport.arenaStats.adjacencyBuildMilliseconds.rounded())) ms",
            "Watcher exits: \(watcherEvents.count), verification snapshots: \(verificationSnapshotCount)",
            "Watcher hints: \(reactorReport.watcherHints.count), early grace saved \(String(format: "%.2f", reactorReport.earlyExitSavingsSeconds))s",
            "Verification modes: \(reactorReport.verificationModeCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ").ifEmpty("none"))",
            "Signal waves: \(reactorReport.signalWaves.count), arena reuse \(reactorReport.arenaReuseCount)",
            "Calibrated reclaim: \(RadarFormat.bytes(calibratedReclaimBytes))",
            "Left running: \(leftRunning.map { String($0.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Late: \(lateTargets.map { "\($0.pid) \($0.state.rawValue)" }.joined(separator: ", ").ifEmpty("none")), frozen \(frozenCount)\(forkStorm ? ", fork storm" : "")",
            "Force skipped: \(skipForceRequested ? "yes" : "no")\(appStillOpen ? ", app still open" : "")\(isForceFollowUp ? " (force follow-up)" : "")",
            "Refused by macOS: \(signalDeniedPIDs.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))",
            "launchd: \(launchdBootout.map { "\($0.accepted ? "booted out" : "bootout failed (\($0.status))") \($0.job.domainTarget)\($0.disabled ? ", disabled" : "")" } ?? "not used")",
            "Ports: \(portOutcomes.map(\.text).joined(separator: " ").ifEmpty("not checked"))",
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
        finalGraphDelta: KillGraphDelta = .empty,
        performanceReport: KillPerformanceReport = .empty,
        watcherEvents: [KillExitEvent] = [],
        verificationSnapshotCount: Int = 0,
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
        self.finalGraphDelta = finalGraphDelta
        self.performanceReport = performanceReport
        self.watcherEvents = watcherEvents
        self.verificationSnapshotCount = verificationSnapshotCount
        self.calibratedReclaimBytes = calibratedReclaimBytes
        self.reactorReport = reactorReport
    }
}

extension KillReport {
    /// What a quit says when the app was still answering it and its helpers
    /// were therefore left running; the settled report drops it again.
    static func helpersLeftAloneNote(app: String) -> String {
        "Left the helpers of \(app) running while it answers the quit request."
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
