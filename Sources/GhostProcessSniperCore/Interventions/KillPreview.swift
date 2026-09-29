import Foundation

public struct KillPreview: Equatable, Sendable {
    public static let verificationPlanText = "Confirm uses a fresh complete arena; pre-force and final settle use target-only verification unless watcher drift triggers a full arena."

    public let displayName: String
    public let rootPID: Int32
    public let protectedPIDs: [Int32]
    public let forceKillDelay: TimeInterval
    public let targets: [KillTarget]
    public let lockedTargets: [KillTarget]
    public let staleTargets: [KillTarget]
    public let recycledTargets: [KillTarget]
    /// Already exited but not yet collected by their parent (zombies):
    /// nothing is left to signal.
    public let exitedTargets: [KillTarget]
    public let readiness: KillReadiness
    public let usedCheapSnapshot: Bool
    public let reclaimEstimate: KillReclaimEstimate
    public let scopePreview: KillScopePreview
    public let strategyRecommendation: KillStrategyRecommendation
    public let targetDiff: KillTargetDiff
    public let decisionScore: KillDecisionScore
    public let strategyProfile: KillStrategyProfile
    public let performanceReport: KillPerformanceReport
    /// What this family's past stops predict for the recommended strategy.
    public let strategyForecast: KillStrategyForecast
    public let watcherAvailable: Bool
    public let arenaStats: KillGraphArenaStats
    /// What the stop interrupts and what could go wrong.
    public let riskAssessment: KillRiskAssessment
    /// Better stops than this one: the supervisor that restarts it, or only
    /// the helper that holds most of it.
    public let alternatives: [KillAlternative]
    /// The launchd job that runs the root, when launchd started it.
    public let launchdJob: LaunchdJob?
    /// The children of a single-process stop that it does not touch: they
    /// lose their parent and may keep running. Apart from `lockedTargets`,
    /// which belong to other users and feed `deniedPIDs`.
    public let leftBehind: [KillTarget]

    public var targetIdentities: [ProcessIdentity] { targets.map(\.identity) }
    public var targetPIDs: [Int32] { targets.map(\.pid) }
    public var deniedPIDs: [Int32] { Array(Set(lockedTargets.map(\.pid))).sorted() }
    public var stalePIDs: [Int32] { Array(Set(staleTargets.map(\.pid))).sorted() }
    public var recycledPIDs: [Int32] { Array(Set(recycledTargets.map(\.pid))).sorted() }
    public var estimatedMemoryReclaimBytes: UInt64 { reclaimEstimate.memoryBytes }
    public var estimatedCPUReclaimPercent: Double { reclaimEstimate.cpuPercent }
    public var preflightMilliseconds: Double { performanceReport.snapshotMilliseconds }
    public var targetConversionCount: Int { performanceReport.targetConversionCount }
    public var forcePolicyText: String { strategyRecommendation.previewText }
    public var whyKillEvidence: [KillDecisionFactor] { decisionScore.whyKill }
    public var whyWaitEvidence: [KillDecisionFactor] { decisionScore.whyWait }
    public var recommendedGraceSeconds: TimeInterval { strategyProfile.graceSeconds }
    public var verificationPlanText: String { Self.verificationPlanText }
    public var recommendedAlternative: KillAlternative? { alternatives.first(where: \.isRecommended) }
    /// launchd restarts the root, and the job is known by its live PID, so
    /// stopping the job itself is the stop that lasts.
    public var offersLaunchdStop: Bool {
        guard let launchdJob, launchdJob.keepAlive, launchdJob.pid == rootPID else { return false }
        return canKill
    }

    public var canKill: Bool {
        !targets.isEmpty && readiness != .locked
    }

    /// Why Confirm is disabled, in one line; nil while it can stop.
    public var confirmBlockedReason: String? {
        guard !canKill else { return nil }
        if targets.isEmpty { return "Nothing left to stop" }
        return decisionScore.factors.first { $0.kind == .blocking }?.detail ?? riskSummary
    }

    public var riskSummary: String {
        if !canKill {
            return "No owned live processes match this kill plan."
        }
        if readiness == .caution {
            let skipped = Set(protectedPIDs + deniedPIDs + stalePIDs + recycledPIDs).count
            return "\(targetPIDs.count) owned target\(targetPIDs.count == 1 ? "" : "s"), \(skipped) locked or stale skipped."
        }
        return "\(targetPIDs.count) owned target\(targetPIDs.count == 1 ? "" : "s") ready."
    }

    public init(
        displayName: String,
        rootPID: Int32,
        protectedPIDs: [Int32],
        forceKillDelay: TimeInterval,
        targets: [KillTarget] = [],
        lockedTargets: [KillTarget] = [],
        staleTargets: [KillTarget] = [],
        recycledTargets: [KillTarget] = [],
        exitedTargets: [KillTarget] = [],
        readiness: KillReadiness = .ready,
        usedCheapSnapshot: Bool = false,
        reclaimEstimate: KillReclaimEstimate = .empty,
        scopePreview: KillScopePreview = .empty,
        strategyRecommendation: KillStrategyRecommendation = .standard,
        targetDiff: KillTargetDiff = .empty,
        decisionScore: KillDecisionScore = .empty,
        strategyProfile: KillStrategyProfile = .standard,
        performanceReport: KillPerformanceReport = .empty,
        strategyForecast: KillStrategyForecast = .none,
        watcherAvailable: Bool = false,
        arenaStats: KillGraphArenaStats = .empty,
        riskAssessment: KillRiskAssessment = .none,
        alternatives: [KillAlternative] = [],
        launchdJob: LaunchdJob? = nil,
        leftBehind: [KillTarget] = []
    ) {
        self.displayName = displayName
        self.rootPID = rootPID
        self.protectedPIDs = protectedPIDs
        self.forceKillDelay = forceKillDelay
        self.targets = targets
        self.lockedTargets = lockedTargets
        self.staleTargets = staleTargets
        self.recycledTargets = recycledTargets
        self.exitedTargets = exitedTargets
        self.readiness = readiness
        self.usedCheapSnapshot = usedCheapSnapshot
        self.reclaimEstimate = reclaimEstimate
        self.scopePreview = scopePreview
        self.strategyRecommendation = strategyRecommendation
        self.targetDiff = targetDiff
        self.decisionScore = decisionScore
        self.strategyProfile = strategyProfile
        self.performanceReport = performanceReport
        self.strategyForecast = strategyForecast
        self.watcherAvailable = watcherAvailable
        self.arenaStats = arenaStats
        self.riskAssessment = riskAssessment
        self.alternatives = alternatives
        self.launchdJob = launchdJob
        self.leftBehind = leftBehind
    }
}
