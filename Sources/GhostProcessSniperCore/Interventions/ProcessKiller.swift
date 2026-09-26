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

public protocol ProcessSignaling: Sendable {
    var usesDarwinProcessNamespace: Bool { get }
    func send(signal: Int32, to pid: Int32) throws
    func exists(pid: Int32) -> Bool
}

public extension ProcessSignaling {
    var usesDarwinProcessNamespace: Bool { false }
}

public struct DarwinProcessSignaler: ProcessSignaling {
    public var usesDarwinProcessNamespace: Bool { true }

    public init() {}

    public func send(signal: Int32, to pid: Int32) throws {
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
}

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
        if !survivorPIDs.isEmpty {
            return "Survivors: \(survivorPIDs.sorted().map(String.init).joined(separator: ", "))."
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

public final class ProcessKiller: @unchecked Sendable {
    private let snapshotProvider: KillSnapshotProviding
    private let signaler: ProcessSignaling
    private let currentUserID: UInt32
    private let sleeper: @Sendable (UInt64) async -> Void
    private let confidenceModel = KillConfidenceModel()
    private let safetyGate = KillSafetyGate()
    private let reclaimEstimator = KillReclaimEstimator()
    private let outcomeClassifier = KillOutcomeClassifier()
    private let interventionBrain: KillInterventionBrain
    private let policyEngine = InterventionPolicyEngine()
    private let deltaEngine = KillGraphDeltaEngine()

    public init(
        lookup: ProcessLookup? = nil,
        snapshotProvider: KillSnapshotProviding? = nil,
        signaler: ProcessSignaling = DarwinProcessSignaler(),
        currentUserID: UInt32 = UInt32(geteuid()),
        interventionBrain: KillInterventionBrain = KillInterventionBrain(),
        sleeper: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        if let snapshotProvider {
            self.snapshotProvider = snapshotProvider
        } else if let lookup {
            self.snapshotProvider = ProcessLookupKillSnapshotProvider(lookup: lookup)
        } else {
            self.snapshotProvider = NativeKillSnapshotProvider()
        }
        self.signaler = signaler
        self.currentUserID = currentUserID
        self.interventionBrain = interventionBrain
        self.sleeper = sleeper
    }

    public func preview(plan: KillPlan, forceKillDelay: TimeInterval = 2) async -> KillPreview {
        await preview(
            plan: plan,
            snapshotPolicy: .preflight,
            profile: .default(gracefulSignal: plan.gracefulSignal, forceKillDelay: forceKillDelay)
        )
    }

    public func preview(
        plan: KillPlan,
        snapshotPolicy: KillSnapshotPolicy,
        profile: KillEscalationProfile
    ) async -> KillPreview {
        do {
            let snapshot = try await interventionBrain.snapshot(
                plan: plan,
                policy: snapshotPolicy,
                provider: snapshotProvider
            )
            let preflight = buildPreflight(plan: plan, snapshot: snapshot, profile: profile)
            RadarLogger.kill.debug("Kill preview \(plan.displayName, privacy: .public) targets \(preflight.preview.targetPIDs.count, privacy: .public) cost \(preflight.preview.preflightMilliseconds, privacy: .public)ms cheap \(preflight.preview.usedCheapSnapshot, privacy: .public)")
            return preflight.preview
        } catch {
            return KillPreview(
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                targetIdentities: [],
                protectedPIDs: plan.protectedPIDs.sorted(),
                deniedPIDs: [],
                stalePIDs: plan.targetIdentities.map(\.pid),
                recycledPIDs: [],
                forceKillDelay: profile.forceKillDelay,
                readiness: .locked,
                readinessReasons: [error.localizedDescription],
                decisionEvidence: [
                    KillDecisionEvidence(
                        kind: .blocking,
                        title: "Preflight failed",
                        detail: error.localizedDescription
                    )
                ]
            )
        }
    }

    public func kill(
        plan: KillPlan,
        forceKillDelay: TimeInterval = 2,
        escalationSignals: [Int32]? = nil,
        skipForce: Bool = false,
        skipForceCheck: (@Sendable () async -> Bool)? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        if let signals = escalationSignals, signals.isEmpty {
            return KillReport(displayName: plan.displayName, rootPID: plan.rootIdentity.pid)
        }
        if let signals = escalationSignals, signals.count == 1 {
            return await kill(
                plan: plan,
                profile: KillEscalationProfile(
                    gracefulSignal: signals[0],
                    forcedSignal: signals[0],
                    forceKillDelay: 0
                ),
                forceSingleSignalOnly: true,
                skipForce: skipForce,
                skipForceCheck: skipForceCheck,
                eventSink: eventSink
            )
        }
        if let signals = escalationSignals, let first = signals.first, let last = signals.last {
            return await kill(
                plan: plan,
                profile: KillEscalationProfile(
                    gracefulSignal: first,
                    forcedSignal: last,
                    forceKillDelay: forceKillDelay
                ),
                skipForce: skipForce,
                skipForceCheck: skipForceCheck,
                eventSink: eventSink
            )
        }
        return await kill(
            plan: plan,
            profile: .default(gracefulSignal: plan.gracefulSignal, forceKillDelay: forceKillDelay),
            skipForce: skipForce,
            skipForceCheck: skipForceCheck,
            eventSink: eventSink
        )
    }

    public func kill(
        plan: KillPlan,
        profile: KillEscalationProfile,
        skipForce: Bool = false,
        skipForceCheck: (@Sendable () async -> Bool)? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        await kill(
            plan: plan,
            profile: profile,
            forceSingleSignalOnly: false,
            skipForce: skipForce,
            skipForceCheck: skipForceCheck,
            eventSink: eventSink
        )
    }

    private func kill(
        plan: KillPlan,
        profile: KillEscalationProfile,
        forceSingleSignalOnly: Bool,
        skipForce: Bool,
        skipForceCheck: (@Sendable () async -> Bool)?,
        eventSink: (@Sendable (KillOperationEvent) -> Void)?
    ) async -> KillReport {
        let totalStart = Date()
        let operationID = KillOperationID()
        let operationState = KillOperationStateMachine(operationID: operationID)
        let reactor = KillInterventionReactor(operationID: operationID)
        let verificationPlanner = KillVerificationPlanner()
        let graceCoordinator = KillGraceCoordinator()
        var watcherTask: Task<Void, Never>?
        do {
            await reactor.beginPhase("confirm-preflight")
            let preflightSnapshot = try await interventionBrain.snapshot(
                plan: plan,
                policy: .confirm,
                provider: snapshotProvider,
                verificationMode: .completeArena
            )
            await reactor.endPhase("confirm-preflight")
            let preflight = buildPreflight(plan: plan, snapshot: preflightSnapshot, profile: profile)
            await reactor.recordArenaStats(preflight.preview.arenaStats)
            await reactor.recordCalibration(preflight.preview.strategySimulation)
            let freshStrategy = preflight.preview.strategyRecommendation.strategy
            let strategy = freshStrategy == .inspectOnly ? freshStrategy : plan.approvedStrategy ?? freshStrategy
            let strategySignals = strategy.signals(gracefulSignal: profile.gracefulSignal)
            let gracefulSignal = strategySignals.first ?? profile.gracefulSignal
            let escalationSignal = strategy == .gentleDevServer ? SIGTERM : profile.forcedSignal
            let schedule = preflight.preview.strategyProfile.verificationSchedule
            var report = KillReport(
                operationID: operationID,
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                deniedPIDs: preflight.preview.deniedPIDs,
                stalePIDs: preflight.preview.stalePIDs,
                targetResults: preflight.locked + preflight.stale + preflight.recycled,
                recycledPIDs: preflight.preview.recycledPIDs,
                estimatedMemoryReclaimBytes: preflight.preview.estimatedMemoryReclaimBytes,
                estimatedCPUReclaimPercent: preflight.preview.estimatedCPUReclaimPercent,
                skipForceRequested: skipForce,
                strategyUsed: strategy,
                scopeUsed: plan.scope,
                targetDiff: preflight.preview.targetDiff,
                strategyHistoryInput: plan.killHistory ?? .empty,
                performanceReport: preflight.preview.performanceReport
            )
            appendEvent(.queued, operationID: operationID, message: "Queued \(strategy.label) intervention.", report: &report, eventSink: eventSink)
            appendEvent(.preflight, operationID: operationID, message: preflight.preview.scopePreview.summary, report: &report, eventSink: eventSink)
            appendEvent(.preflight, operationID: operationID, message: preflight.preview.targetDiff.summary, report: &report, eventSink: eventSink)

            if let expiry = plan.approvalExpiresAt, Date() > expiry {
                report.failures.append("This preview expired. Open a fresh preview before confirming; no signal was sent.")
                return report
            }
            guard preflight.preview.canKill, strategy != .inspectOnly else {
                if strategy == .inspectOnly {
                    report.failures.append("Inspect-only strategy recommended; no signal sent.")
                }
                report.timeline = KillExecutionTimeline(
                    preflightMilliseconds: preflightSnapshot.elapsedMilliseconds,
                    signalMilliseconds: 0,
                    verificationMilliseconds: 0,
                    totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000
                )
                return report
            }

            let signalStart = Date()
            let targets = preflight.targets.sorted(by: Self.signalOrder)
            if signaler.usesDarwinProcessNamespace {
                let exitWatcher = KillExitWatcher()
                let hintStream = await exitWatcher.watchHints(operationID: operationID, targets: targets)
                watcherTask = Task {
                    for await hint in hintStream {
                        await reactor.recordHint(hint)
                        if hint.kind == .exit {
                            let update = await operationState.recordExit(hint.exitEvent)
                            eventSink?(update)
                        } else {
                            eventSink?(
                                KillOperationEvent(
                                    operationID: operationID,
                                    kind: .targetUpdated,
                                    pid: hint.pid,
                                    message: hint.message,
                                    createdAt: hint.observedAt
                                )
                            )
                        }
                    }
                }
            }
            let gracefulWaveStarted = Date()
            let attemptsBeforeGrace = report.attempts.count
            for target in targets {
                appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .ready, message: "Queued \(target.name).", report: &report, eventSink: eventSink)
                send(gracefulSignal, to: target, stage: "graceful", operationID: operationID, report: &report, eventSink: eventSink)
            }
            await reactor.recordWave(
                signalWave(
                    stage: "graceful",
                    signal: gracefulSignal,
                    targets: targets,
                    startedAt: gracefulWaveStarted,
                    attempts: Array(report.attempts.dropFirst(attemptsBeforeGrace))
                )
            )

            var latestLiveTargets: [KillTarget] = []
            if !forceSingleSignalOnly {
                appendEvent(.graceWaiting, operationID: operationID, message: "Waiting \(String(format: "%.1f", schedule.graceSeconds))s before force verification.", report: &report, eventSink: eventSink)
                let graceResult = await graceCoordinator.wait(
                    seconds: schedule.graceSeconds,
                    sleeper: sleeper,
                    skipForceCheck: skipForceCheck
                ) {
                    let states = await operationState.targetStates()
                    return !targets.isEmpty && targets.allSatisfy { states[$0.pid] == .terminated }
                }
                if graceResult.endedEarly && !graceResult.skipForceRequested {
                    await reactor.recordEarlyExitSavings(max(0, schedule.graceSeconds - graceResult.waitedSeconds))
                }
                let preForceHints = await reactor.hintSnapshot()
                let preForceMode = verificationPlanner.mode(
                    stage: "pre-force",
                    hints: preForceHints
                )
                let preForce = try await verify(stage: "pre-force", plan: plan, targets: targets, operationStart: totalStart, mode: preForceMode, reactor: reactor)
                report.verificationPasses.append(preForce.pass)
                appendUnique(survivors: preForce.recycled.map(\.pid), to: &report.recycledPIDs)
                latestLiveTargets = preForce.live
                appendEvent(.verified, operationID: operationID, message: "Pre-force verification: \(preForce.pass.livePIDs.count) live, \(preForce.pass.recycledPIDs.count) recycled.", report: &report, eventSink: eventSink)

                var shouldSkipForce = skipForce || graceResult.skipForceRequested
                if !shouldSkipForce, let skipForceCheck {
                    shouldSkipForce = await skipForceCheck()
                }
                report.skipForceRequested = shouldSkipForce
                if shouldSkipForce {
                    report.survivorPIDs = latestLiveTargets.map(\.pid).sorted()
                    appendEvent(.forceSkipped, operationID: operationID, message: "Force escalation skipped by user.", report: &report, eventSink: eventSink)
                } else if !latestLiveTargets.isEmpty {
                    appendEvent(.forcePending, operationID: operationID, message: "\(latestLiveTargets.count) same-identity target\(latestLiveTargets.count == 1 ? "" : "s") still live.", report: &report, eventSink: eventSink)
                    let escalationWaveStarted = Date()
                    let attemptsBeforeEscalation = report.attempts.count
                    for target in latestLiveTargets {
                        send(escalationSignal, to: target, stage: strategy == .gentleDevServer ? "secondary" : "forced", operationID: operationID, report: &report, eventSink: eventSink)
                    }
                    await reactor.recordWave(
                        signalWave(
                            stage: strategy == .gentleDevServer ? "secondary" : "forced",
                            signal: escalationSignal,
                            targets: latestLiveTargets,
                            startedAt: escalationWaveStarted,
                            attempts: Array(report.attempts.dropFirst(attemptsBeforeEscalation))
                        )
                    )
                    let secondaryTargets = latestLiveTargets
                    let secondaryGrace = await graceCoordinator.wait(seconds: schedule.secondaryGraceSeconds, sleeper: sleeper) {
                        let states = await operationState.targetStates()
                        return !secondaryTargets.isEmpty && secondaryTargets.allSatisfy { states[$0.pid] == .terminated }
                    }
                    if secondaryGrace.endedEarly {
                        await reactor.recordEarlyExitSavings(max(0, schedule.secondaryGraceSeconds - secondaryGrace.waitedSeconds))
                    }
                    let postForceHints = await reactor.hintSnapshot()
                    let postForceMode = verificationPlanner.mode(
                        stage: "post-force",
                        hints: postForceHints
                    )
                    let postForce = try await verify(stage: "post-force", plan: plan, targets: targets, operationStart: totalStart, mode: postForceMode, reactor: reactor)
                    report.verificationPasses.append(postForce.pass)
                    appendUnique(survivors: postForce.recycled.map(\.pid), to: &report.recycledPIDs)
                    latestLiveTargets = postForce.live
                    appendEvent(.verified, operationID: operationID, message: "Post-force verification: \(postForce.pass.livePIDs.count) live.", report: &report, eventSink: eventSink)
                    if strategy == .gentleDevServer && !latestLiveTargets.isEmpty {
                        appendEvent(.forcePending, operationID: operationID, message: "Gentle stop left \(latestLiveTargets.count) target\(latestLiveTargets.count == 1 ? "" : "s"); preparing SIGKILL.", report: &report, eventSink: eventSink)
                        let forceWaveStarted = Date()
                        let attemptsBeforeForce = report.attempts.count
                        for target in latestLiveTargets {
                            send(profile.forcedSignal, to: target, stage: "forced", operationID: operationID, report: &report, eventSink: eventSink)
                        }
                        await reactor.recordWave(
                            signalWave(
                                stage: "forced",
                                signal: profile.forcedSignal,
                                targets: latestLiveTargets,
                                startedAt: forceWaveStarted,
                                attempts: Array(report.attempts.dropFirst(attemptsBeforeForce))
                            )
                        )
                    }
                    _ = await graceCoordinator.wait(seconds: schedule.settleSeconds, sleeper: sleeper) {
                        let states = await operationState.targetStates()
                        return !targets.isEmpty && targets.allSatisfy { states[$0.pid] == .terminated }
                    }
                }
            } else {
                let singlePass = try await verify(stage: "single-signal", plan: plan, targets: targets, operationStart: totalStart, mode: .targetOnly, reactor: reactor)
                report.verificationPasses.append(singlePass.pass)
                appendUnique(survivors: singlePass.recycled.map(\.pid), to: &report.recycledPIDs)
                latestLiveTargets = singlePass.live
            }

            let signalMilliseconds = Date().timeIntervalSince(signalStart) * 1_000
            let verifyStart = Date()
            let finalHints = await reactor.hintSnapshot()
            let finalMode = verificationPlanner.mode(
                stage: "final-settle",
                hints: finalHints
            )
            let finalVerification = try await verify(stage: "final-settle", plan: plan, targets: targets, operationStart: totalStart, mode: finalMode, reactor: reactor)
            report.verificationPasses.append(finalVerification.pass)
            appendUnique(survivors: finalVerification.recycled.map(\.pid), to: &report.recycledPIDs)
            let finalSurvivors = finalVerification.live
            report.survivorPIDs = finalSurvivors.map(\.pid).sorted()
            report.targetResults.append(contentsOf: finalResults(for: targets, report: report))
            report.realizedMemoryReclaimBytes = reclaimEstimator.realizedEstimate(
                from: preflight.preview.reclaimEstimate,
                targets: report.targetResults
            )
            report.timeline = KillExecutionTimeline(
                preflightMilliseconds: preflightSnapshot.elapsedMilliseconds,
                signalMilliseconds: signalMilliseconds,
                verificationMilliseconds: Date().timeIntervalSince(verifyStart) * 1_000,
                totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000
            )
            report.targetDiff = KillTargetDiff(
                addedPIDs: preflight.preview.targetDiff.addedPIDs,
                exitedPIDs: report.stalePIDs + report.exitedBeforeSignalPIDs,
                recycledPIDs: report.recycledPIDs,
                reparentedPIDs: preflight.preview.targetDiff.reparentedPIDs,
                survivorPIDs: report.survivorPIDs
            )
            report.finalGraphDelta = KillGraphDelta(
                previewTargetPIDs: preflight.preview.targetPIDs,
                confirmTargetPIDs: targets.map(\.pid),
                finalSurvivorPIDs: report.survivorPIDs,
                drift: report.targetDiff
            )
            report.graphSliceDeltas = [report.finalGraphDelta]
            report.learning = KillOutcomeLearning(
                history: plan.killHistory ?? .empty,
                recommendationHint: report.forcedPIDs.isEmpty && report.survivorPIDs.isEmpty ? "Graceful strategy worked for this family." : "Future previews should mention prior force/survivor behavior."
            )
            report.eventCoalescingCount = max(0, report.eventHistory.count - 6)
            report.verificationSnapshotCount = report.verificationPasses.count
            report.signalOutcomeCounts = Dictionary(
                grouping: report.attempts,
                by: \.signalName
            ).mapValues { attempts in
                attempts.filter(\.succeeded).count
            }
            report.calibratedReclaimBytes = report.realizedMemoryReclaimBytes > 0 ?
                report.realizedMemoryReclaimBytes :
                UInt64(Double(report.estimatedMemoryReclaimBytes) * (1 - preflight.preview.survivorRisk))
            watcherTask?.cancel()
            report.watcherEvents = await operationState.exitEventSnapshot()
            report.reactorReport = await reactor.report()
            report.performanceReport = KillPerformanceReport(
                snapshotMilliseconds: preflight.preview.performanceReport.snapshotMilliseconds,
                graphReadCount: preflight.preview.performanceReport.graphReadCount,
                heavyMetricReadCount: preflight.preview.performanceReport.heavyMetricReadCount,
                targetConversionCount: preflight.preview.performanceReport.targetConversionCount,
                cacheStatus: preflight.preview.performanceReport.cacheStatus,
                didHitBudget: preflight.preview.performanceReport.didHitBudget,
                skippedOptionalWorkCount: preflight.preview.performanceReport.skippedOptionalWorkCount,
                eventCoalescingCount: report.eventCoalescingCount,
                arenaStats: preflight.preview.arenaStats,
                watcherHintCount: report.reactorReport.watcherHints.count,
                earlyGraceExitCount: report.reactorReport.earlyExitSavingsSeconds > 0 ? 1 : 0,
                targetOnlyVerificationCount: report.reactorReport.verificationModeCounts[KillVerificationMode.targetOnly.rawValue, default: 0],
                completeVerificationCount: report.reactorReport.verificationModeCounts[KillVerificationMode.completeArena.rawValue, default: 0],
                eventTriggeredVerificationCount: report.reactorReport.verificationModeCounts[KillVerificationMode.eventTriggeredComplete.rawValue, default: 0]
            )
            appendEvent(.completed, operationID: operationID, message: report.summary, report: &report, eventSink: eventSink)
            RadarLogger.kill.info("Kill operation \(operationID.rawValue, privacy: .public) \(plan.displayName, privacy: .public) finished in \(report.timeline.totalMilliseconds, privacy: .public)ms, forced \(report.forcedPIDs.count, privacy: .public), survivors \(report.survivorPIDs.count, privacy: .public)")
            return report
        } catch {
            watcherTask?.cancel()
            RadarLogger.kill.error("Kill operation \(operationID.rawValue, privacy: .public) failed for \(plan.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return KillReport(
                operationID: operationID,
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                failures: [error.localizedDescription],
                timeline: KillExecutionTimeline(
                    preflightMilliseconds: 0,
                    signalMilliseconds: 0,
                    verificationMilliseconds: 0,
                    totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000
                ),
                eventHistory: [
                    KillOperationEvent(operationID: operationID, kind: .failed, message: error.localizedDescription)
                ],
                scopeUsed: plan.scope
            )
        }
    }

    public func kill(identity: ProcessIdentity, displayName: String, forceKillDelay: TimeInterval = 2) async -> KillReport {
        await kill(
            plan: KillPlan(
                rootIdentity: identity,
                targetIdentities: [identity],
                protectedPIDs: [],
                displayName: displayName
            ),
            forceKillDelay: forceKillDelay
        )
    }

    private struct Preflight {
        let preview: KillPreview
        let targets: [KillTarget]
        let locked: [KillTarget]
        let stale: [KillTarget]
        let recycled: [KillTarget]
    }

    private func buildPreflight(
        plan: KillPlan,
        snapshot: KillProcessSnapshot,
        profile: KillEscalationProfile
    ) -> Preflight {
        let index = KillProcessIndex(snapshot: snapshot)
        let arena = snapshot.arena ?? KillGraphArena(
            processes: snapshot.graph?.processes ?? snapshot.processes.map { KillProcessLite(process: $0) },
            sampledAt: snapshot.sampledAt,
            pidReadCount: snapshot.graphReadCount
        )
        let slice = arena.slice(plan: plan, currentUserID: currentUserID)
        let treeIdentities = slice.treeIdentities
        var targets: [KillTarget] = []
        var locked: [KillTarget] = []
        var stale: [KillTarget] = []
        var recycled: [KillTarget] = []
        var seen = Set<ProcessIdentity>()

        if slice.targetMembers.isEmpty && slice.lockedMembers.isEmpty {
            classifyPlanIdentities(plan, index: index, targets: &targets, locked: &locked, stale: &stale, recycled: &recycled, seen: &seen)
        } else {
            for member in slice.targetMembers {
                targets.append(KillTarget(process: member.process, depth: member.depth, state: .ready, reason: "Owned live descendant", rootIdentity: plan.rootIdentity))
                seen.insert(member.process.identity)
            }
            for member in slice.lockedMembers {
                locked.append(KillTarget(process: member.process, depth: member.depth, state: .locked, reason: "Owned by \(member.process.ownerName)", rootIdentity: plan.rootIdentity))
            }
            classifyPlanIdentities(
                plan,
                index: index,
                targets: &targets,
                locked: &locked,
                stale: &stale,
                recycled: &recycled,
                seen: &seen,
                allowReadyOutsideTree: false,
                treeIdentities: treeIdentities
            )
        }

        for pid in plan.protectedPIDs where !locked.contains(where: { $0.pid == pid }) {
            locked.append(
                KillTarget(
                    identity: ProcessIdentity(pid: pid, startTimeSeconds: 0, startTimeMicroseconds: 0),
                    parentPID: nil,
                    name: "Protected PID \(pid)",
                    ownerName: "protected",
                    depth: 0,
                    memoryBytes: 0,
                    cpuPercent: 0,
                    state: .locked,
                    reason: "Protected by source family",
                    isRoot: false
                )
            )
        }

        if let approved = plan.approvedIdentities {
            let additions = targets.filter { !approved.contains($0.identity) }
            locked.append(contentsOf: additions.map { $0.updating(state: .locked, reason: "Not included in the confirmed preview") })
            targets.removeAll { !approved.contains($0.identity) }
        }
        targets = targets.sorted(by: Self.signalOrder)
        locked.sort { $0.pid < $1.pid }
        stale.sort { $0.pid < $1.pid }
        recycled.sort { $0.pid < $1.pid }

        let denied = Array(Set(locked.map(\.pid))).sorted()
        let stalePIDs = Array(Set(stale.map(\.pid))).sorted()
        let recycledPIDs = Array(Set(recycled.map(\.pid))).sorted()
        let reclaim = reclaimEstimator.estimate(plan: plan, targets: targets)
        let nearby = slice.nearbyCandidates
        let diff = deltaEngine.diff(plan: plan, targets: targets, stale: stale, recycled: recycled, locked: locked, treeIdentities: treeIdentities)
        let scopePreview = KillScopePreview(
            scope: plan.scope,
            targetCount: targets.count,
            lockedCount: locked.count,
            nearbyCandidates: Array(nearby),
            drift: diff,
            summary: "\(targets.count) target\(targets.count == 1 ? "" : "s"), \(locked.count + stale.count + recycled.count) skipped, \(nearby.count) nearby."
        )
        let policy = policyEngine.evaluate(
            plan: plan,
            targets: targets,
            locked: locked,
            stale: stale,
            recycled: recycled,
            reclaim: reclaim,
            diff: diff,
            nearbyCount: nearby.count,
            forceKillDelay: profile.forceKillDelay
        )
        let decisionScore = policy.decisionScore
        let strategy = policy.recommendation
        let strategyProfile = policy.profile
        let evidence = decisionScore.factors.map(Self.evidence(from:)) + confidenceModel.evidence(
            plan: plan,
            targets: targets,
            locked: locked,
            stale: stale,
            recycled: recycled,
            reclaim: reclaim
        )
        let readiness = safetyGate.readiness(hasTargets: !targets.isEmpty, evidence: evidence)
        let performanceReport = interventionBrain.performanceReport(snapshot: snapshot)

        let preview = KillPreview(
            displayName: plan.displayName,
            rootPID: plan.rootIdentity.pid,
            targetIdentities: targets.map(\.identity),
            protectedPIDs: plan.protectedPIDs.sorted(),
            deniedPIDs: denied,
            stalePIDs: stalePIDs,
            recycledPIDs: recycledPIDs,
            forceKillDelay: profile.forceKillDelay,
            targets: targets,
            lockedTargets: locked,
            staleTargets: stale,
            recycledTargets: recycled,
            readiness: readiness,
            readinessReasons: evidence.map { "\($0.title): \($0.detail)" },
            estimatedMemoryReclaimBytes: reclaim.memoryBytes,
            estimatedCPUReclaimPercent: reclaim.cpuPercent,
            preflightMilliseconds: snapshot.elapsedMilliseconds,
            usedCheapSnapshot: snapshot.usedCheapPath,
            reclaimEstimate: reclaim,
            decisionEvidence: evidence,
            forcePolicyText: strategy.previewText,
            scopePreview: scopePreview,
            strategyRecommendation: strategy,
            targetDiff: diff,
            decisionScore: decisionScore,
            whyKillEvidence: decisionScore.whyKill,
            whyWaitEvidence: decisionScore.whyWait,
            targetConversionCount: snapshot.targetConversionCount,
            cacheStatus: snapshot.cacheStatus,
            strategyProfile: strategyProfile,
            performanceReport: performanceReport,
            strategySimulation: policy.simulation,
            watcherAvailable: !targets.isEmpty && signaler.usesDarwinProcessNamespace,
            arenaStats: arena.stats,
            calibratedGracefulSuccess: policy.simulation.expectedGracefulSuccess,
            calibratedForceProbability: policy.simulation.forceProbability,
            calibratedSurvivorRisk: policy.simulation.survivorRisk,
            recommendedGraceSeconds: policy.profile.verificationSchedule.graceSeconds,
            verificationPlanText: "Confirm uses a fresh complete arena; pre-force and final settle use target-only verification unless watcher drift triggers a full arena."
        )
        return Preflight(preview: preview, targets: targets, locked: locked, stale: stale, recycled: recycled)
    }

    private func classifyPlanIdentities(
        _ plan: KillPlan,
        index: KillProcessIndex,
        targets: inout [KillTarget],
        locked: inout [KillTarget],
        stale: inout [KillTarget],
        recycled: inout [KillTarget],
        seen: inout Set<ProcessIdentity>,
        allowReadyOutsideTree: Bool = true,
        treeIdentities: Set<ProcessIdentity> = []
    ) {
        for identity in plan.targetIdentities where !seen.contains(identity) {
            guard let process = index.liteProcess(for: identity) else {
                let target = placeholder(identity: identity, state: index.hasRecycledPID(for: identity) ? .recycled : .stale, reason: index.hasRecycledPID(for: identity) ? "PID was reused by another process" : "Identity is no longer live")
                if target.state == .recycled {
                    recycled.append(target)
                } else {
                    stale.append(target)
                }
                continue
            }
            if !allowReadyOutsideTree && !treeIdentities.contains(identity) {
                locked.append(KillTarget(process: process, depth: 0, state: .locked, reason: "Outside selected family tree", rootIdentity: plan.rootIdentity))
                continue
            }
            if process.userID == currentUserID {
                targets.append(KillTarget(process: process, depth: identity == plan.rootIdentity ? 0 : 1, state: .ready, reason: "Owned live plan target", rootIdentity: plan.rootIdentity))
                seen.insert(identity)
            } else {
                locked.append(KillTarget(process: process, depth: 0, state: .locked, reason: "Owned by \(process.ownerName)", rootIdentity: plan.rootIdentity))
            }
        }
    }

    private func placeholder(identity: ProcessIdentity, state: KillTargetState, reason: String) -> KillTarget {
        KillTarget(
            identity: identity,
            parentPID: nil,
            name: "PID \(identity.pid)",
            ownerName: "unknown",
            depth: 0,
            memoryBytes: 0,
            cpuPercent: 0,
            state: state,
            reason: reason,
            isRoot: false
        )
    }

    private func targetDiff(
        plan: KillPlan,
        targets: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        locked: [KillTarget],
        treeIdentities: Set<ProcessIdentity>
    ) -> KillTargetDiff {
        let planned = Set(plan.targetIdentities)
        let current = Set(targets.map(\.identity))
        let added = current.subtracting(planned).map(\.pid)
        let reparented = locked
            .filter { target in
                plan.targetIdentities.contains(target.identity) && !treeIdentities.isEmpty && !treeIdentities.contains(target.identity)
            }
            .map(\.pid)
        return KillTargetDiff(
            addedPIDs: added,
            exitedPIDs: stale.map(\.pid),
            recycledPIDs: recycled.map(\.pid),
            reparentedPIDs: reparented,
            survivorPIDs: []
        )
    }

    private static func evidence(from factor: KillDecisionFactor) -> KillDecisionEvidence {
        let kind: KillDecisionEvidenceKind = switch factor.kind {
        case .whyKill: .positive
        case .whyWait: .caution
        case .blocking: .blocking
        }
        return KillDecisionEvidence(kind: kind, title: factor.title, detail: factor.detail)
    }

    private func strategyRecommendation(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget]
    ) -> KillStrategyRecommendation {
        if targets.isEmpty || locked.count >= max(3, targets.count) {
            return KillStrategyRecommendation(
                strategy: .inspectOnly,
                confidence: 0.84,
                reasons: ["Low confidence or too many protected descendants."],
                previewText: "Inspect only; no signal should be sent until ownership is clearer."
            )
        }

        if let history = plan.killHistory, history.operationCount >= 2 {
            if history.survivorRate >= 0.35 || history.commonDenialCount >= 2 {
                return KillStrategyRecommendation(
                    strategy: .inspectOnly,
                    confidence: 0.78,
                    reasons: ["Recent history shows survivors or denied signals for this family."],
                    previewText: "Inspect history before another intervention; no signal is the safest default."
                )
            }
            if history.forceRate >= 0.5 {
                return KillStrategyRecommendation(
                    strategy: .stubbornRunaway,
                    confidence: 0.74,
                    reasons: ["This family often survives graceful shutdown; expect force verification."],
                    previewText: "SIGTERM, verify, then SIGKILL same-identity survivors if needed."
                )
            }
        }

        let kind = plan.familyMetadata?.devKindLabel.lowercased() ?? plan.displayName.lowercased()
        let devServerHints = ["node", "vite", "python", "ruby", "swift", "server", "bun", "deno"]
        if devServerHints.contains(where: { kind.contains($0) || plan.displayName.lowercased().contains($0) }) {
            return KillStrategyRecommendation(
                strategy: .gentleDevServer,
                confidence: 0.76,
                reasons: ["Looks like a dev server; try SIGINT before SIGTERM."],
                previewText: "SIGINT, verify, then SIGTERM; SIGKILL only for same-identity survivors."
            )
        }

        if plan.familyMetadata?.forecastState == .runaway || plan.familyMetadata?.scoreLevel == .critical {
            return KillStrategyRecommendation(
                strategy: .stubbornRunaway,
                confidence: 0.72,
                reasons: ["Critical or runaway process family; expect possible force escalation."],
                previewText: "SIGTERM, short verification, then SIGKILL same-identity survivors."
            )
        }

        return .standard
    }

    private func appendEvent(
        _ kind: KillOperationEventKind,
        operationID: KillOperationID,
        pid: Int32? = nil,
        signalName: String? = nil,
        targetState: KillTargetState? = nil,
        message: String,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) {
        let event = KillOperationEvent(
            operationID: operationID,
            kind: kind,
            pid: pid,
            signalName: signalName,
            targetState: targetState,
            message: message
        )
        report.eventHistory.append(event)
        eventSink?(event)
    }

    private func send(
        _ signal: Int32,
        to target: KillTarget,
        stage: String,
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) {
        do {
            try signaler.send(signal: signal, to: target.pid)
            let attempt = KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: true)
            report.attempts.append(attempt)
            appendEvent(.signaled, operationID: operationID, pid: target.pid, signalName: attempt.signalName, targetState: stage == "forced" ? .forceKilled : .terminated, message: "\(attempt.signalName) sent to \(target.name).", report: &report, eventSink: eventSink)
            if stage == "forced" {
                if !report.forcedPIDs.contains(target.pid) {
                    report.forcedPIDs.append(target.pid)
                }
            } else if !report.gracefulPIDs.contains(target.pid) {
                report.gracefulPIDs.append(target.pid)
            }
        } catch let failure as SignalFailure where failure.errnoCode == ESRCH {
            report.attempts.append(KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: false, message: failure.message))
            if !report.stalePIDs.contains(target.pid) {
                report.stalePIDs.append(target.pid)
            }
            if !report.exitedBeforeSignalPIDs.contains(target.pid) {
                report.exitedBeforeSignalPIDs.append(target.pid)
            }
            appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .exitedBeforeSignal, message: "PID exited before signal.", report: &report, eventSink: eventSink)
        } catch let failure as SignalFailure where failure.errnoCode == EPERM {
            report.attempts.append(KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: false, message: failure.message))
            if !report.deniedPIDs.contains(target.pid) {
                report.deniedPIDs.append(target.pid)
            }
            appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .locked, message: "Signal denied: \(failure.message)", report: &report, eventSink: eventSink)
        } catch {
            report.attempts.append(KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: false, message: error.localizedDescription))
            report.failures.append("PID \(target.pid) (\(KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: false).signalName)): \(error.localizedDescription)")
            appendEvent(.failed, operationID: operationID, pid: target.pid, targetState: .failed, message: error.localizedDescription, report: &report, eventSink: eventSink)
        }
    }

    private func finalResults(for targets: [KillTarget], report: KillReport) -> [KillTarget] {
        targets.map { outcomeClassifier.classify(target: $0, report: report) }
    }

    private func signalWave(
        stage: String,
        signal: Int32,
        targets: [KillTarget],
        startedAt: Date,
        attempts: [KillAttempt]
    ) -> KillSignalWave {
        let signalName = KillAttempt(pid: 0, signal: signal, stage: stage, succeeded: true).signalName
        return KillSignalWave(
            stage: stage,
            signalName: signalName,
            targetPIDs: targets.map(\.pid),
            startedAt: startedAt,
            finishedAt: Date(),
            sentCount: attempts.filter(\.succeeded).count,
            failedCount: attempts.filter { !$0.succeeded }.count
        )
    }

    private struct VerificationResult {
        let pass: KillVerificationPass
        let live: [KillTarget]
        let recycled: [KillTarget]
        let exited: [KillTarget]
    }

    private func verify(
        stage: String,
        plan: KillPlan,
        targets: [KillTarget],
        operationStart: Date,
        mode: KillVerificationMode = .completeArena,
        reactor: KillInterventionReactor? = nil
    ) async throws -> VerificationResult {
        await reactor?.beginPhase("verify-\(stage)")
        let request = KillSnapshotRequest(
            policy: .verify,
            rootIdentity: plan.rootIdentity,
            targetIdentities: targets.map(\.identity),
            protectedPIDs: plan.protectedPIDs,
            scope: plan.scope,
            budget: .verify,
            includeHeavyMetricsForTargets: false,
            cachePolicy: .disabled,
            requiresCompleteGraph: mode != .targetOnly,
            conversionBudget: .targetsOnly,
            verificationMode: mode
        )
        let snapshot = try await snapshotProvider.snapshot(request: request)
        await reactor?.endPhase("verify-\(stage)")
        await reactor?.recordVerification(mode: mode)
        if let stats = snapshot.arena?.stats {
            await reactor?.recordArenaStats(stats)
        }
        let index = KillProcessIndex(snapshot: snapshot)
        var live: [KillTarget] = []
        var recycled: [KillTarget] = []
        var exited: [KillTarget] = []

        for target in targets {
            if index.hasRecycledPID(for: target.identity) {
                recycled.append(target)
            } else if index.process(for: target.identity) != nil && signaler.exists(pid: target.pid) {
                live.append(target)
            } else {
                exited.append(target)
            }
        }

        return VerificationResult(
            pass: KillVerificationPass(
                stage: stage,
                sampledAt: snapshot.sampledAt,
                sampleMilliseconds: snapshot.elapsedMilliseconds,
                elapsedMilliseconds: Date().timeIntervalSince(operationStart) * 1_000,
                livePIDs: live.map(\.pid),
                recycledPIDs: recycled.map(\.pid),
                exitedPIDs: exited.map(\.pid)
            ),
            live: live,
            recycled: recycled,
            exited: exited
        )
    }

    private static func signalOrder(_ lhs: KillTarget, _ rhs: KillTarget) -> Bool {
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }
        if lhs.isRoot != rhs.isRoot {
            return !lhs.isRoot
        }
        return lhs.pid > rhs.pid
    }

    private func appendUnique(survivors pids: [Int32], to output: inout [Int32]) {
        for pid in pids where !output.contains(pid) {
            output.append(pid)
        }
        output.sort()
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
