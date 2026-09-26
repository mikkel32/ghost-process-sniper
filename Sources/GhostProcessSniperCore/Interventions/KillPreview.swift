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
    public let readiness: KillReadiness
    public let usedCheapSnapshot: Bool
    public let reclaimEstimate: KillReclaimEstimate
    public let scopePreview: KillScopePreview
    public let strategyRecommendation: KillStrategyRecommendation
    public let targetDiff: KillTargetDiff
    public let decisionScore: KillDecisionScore
    public let strategyProfile: KillStrategyProfile
    public let performanceReport: KillPerformanceReport
    public let strategySimulation: KillStrategySimulation
    public let watcherAvailable: Bool
    public let arenaStats: KillGraphArenaStats
    /// What the stop interrupts and what could go wrong.
    public let riskAssessment: KillRiskAssessment

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
    public var recommendedGraceSeconds: TimeInterval { strategyProfile.verificationSchedule.graceSeconds }
    public var expectedGracefulSuccess: Double { strategySimulation.expectedGracefulSuccess }
    public var forceProbability: Double { strategySimulation.forceProbability }
    public var survivorRisk: Double { strategySimulation.survivorRisk }
    public var verificationPlanText: String { Self.verificationPlanText }

    public var canKill: Bool {
        !targets.isEmpty && readiness != .locked
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
        readiness: KillReadiness = .ready,
        usedCheapSnapshot: Bool = false,
        reclaimEstimate: KillReclaimEstimate = .empty,
        scopePreview: KillScopePreview = .empty,
        strategyRecommendation: KillStrategyRecommendation = .standard,
        targetDiff: KillTargetDiff = .empty,
        decisionScore: KillDecisionScore = .empty,
        strategyProfile: KillStrategyProfile = .standard,
        performanceReport: KillPerformanceReport = .empty,
        strategySimulation: KillStrategySimulation = .standard,
        watcherAvailable: Bool = false,
        arenaStats: KillGraphArenaStats = .empty,
        riskAssessment: KillRiskAssessment = .none
    ) {
        self.displayName = displayName
        self.rootPID = rootPID
        self.protectedPIDs = protectedPIDs
        self.forceKillDelay = forceKillDelay
        self.targets = targets
        self.lockedTargets = lockedTargets
        self.staleTargets = staleTargets
        self.recycledTargets = recycledTargets
        self.readiness = readiness
        self.usedCheapSnapshot = usedCheapSnapshot
        self.reclaimEstimate = reclaimEstimate
        self.scopePreview = scopePreview
        self.strategyRecommendation = strategyRecommendation
        self.targetDiff = targetDiff
        self.decisionScore = decisionScore
        self.strategyProfile = strategyProfile
        self.performanceReport = performanceReport
        self.strategySimulation = strategySimulation
        self.watcherAvailable = watcherAvailable
        self.arenaStats = arenaStats
        self.riskAssessment = riskAssessment
    }
}
