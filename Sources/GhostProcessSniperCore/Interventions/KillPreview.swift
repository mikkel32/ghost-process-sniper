import Foundation

public struct KillPreview: Equatable, Sendable {
    public let displayName: String
    public let rootPID: Int32
    public let targetIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let deniedPIDs: [Int32]
    public let stalePIDs: [Int32]
    public let recycledPIDs: [Int32]
    public let forceKillDelay: TimeInterval
    public let targets: [KillTarget]
    public let lockedTargets: [KillTarget]
    public let staleTargets: [KillTarget]
    public let recycledTargets: [KillTarget]
    public let readiness: KillReadiness
    public let readinessReasons: [String]
    public let estimatedMemoryReclaimBytes: UInt64
    public let estimatedCPUReclaimPercent: Double
    public let preflightMilliseconds: Double
    public let usedCheapSnapshot: Bool
    public let reclaimEstimate: KillReclaimEstimate
    public let decisionEvidence: [KillDecisionEvidence]
    public let forcePolicyText: String
    public let scopePreview: KillScopePreview
    public let strategyRecommendation: KillStrategyRecommendation
    public let targetDiff: KillTargetDiff
    public let previewReportText: String
    public let decisionScore: KillDecisionScore
    public let whyKillEvidence: [KillDecisionFactor]
    public let whyWaitEvidence: [KillDecisionFactor]
    public let targetConversionCount: Int
    public let cacheStatus: KillSnapshotCacheStatus
    public let strategyProfile: KillStrategyProfile
    public let performanceReport: KillPerformanceReport
    public let strategySimulation: KillStrategySimulation
    public let watcherAvailable: Bool
    public let arenaStats: KillGraphArenaStats
    public let calibratedGracefulSuccess: Double
    public let calibratedForceProbability: Double
    public let calibratedSurvivorRisk: Double
    public let recommendedGraceSeconds: TimeInterval
    public let verificationPlanText: String
    /// What the stop interrupts and what could go wrong.
    public let riskAssessment: KillRiskAssessment

    public var targetPIDs: [Int32] {
        targetIdentities.map(\.pid)
    }

    public var expectedGracefulSuccess: Double {
        calibratedGracefulSuccess
    }

    public var forceProbability: Double {
        calibratedForceProbability
    }

    public var survivorRisk: Double {
        calibratedSurvivorRisk
    }

    public var canKill: Bool {
        !targetIdentities.isEmpty && readiness != .locked
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
        targetIdentities: [ProcessIdentity],
        protectedPIDs: [Int32],
        deniedPIDs: [Int32],
        stalePIDs: [Int32],
        recycledPIDs: [Int32],
        forceKillDelay: TimeInterval,
        targets: [KillTarget] = [],
        lockedTargets: [KillTarget] = [],
        staleTargets: [KillTarget] = [],
        recycledTargets: [KillTarget] = [],
        readiness: KillReadiness = .ready,
        readinessReasons: [String] = [],
        estimatedMemoryReclaimBytes: UInt64 = 0,
        estimatedCPUReclaimPercent: Double = 0,
        preflightMilliseconds: Double = 0,
        usedCheapSnapshot: Bool = false,
        reclaimEstimate: KillReclaimEstimate = .empty,
        decisionEvidence: [KillDecisionEvidence] = [],
        forcePolicyText: String = "SIGTERM, verify, then SIGKILL surviving same-identity targets",
        scopePreview: KillScopePreview = .empty,
        strategyRecommendation: KillStrategyRecommendation = .standard,
        targetDiff: KillTargetDiff = .empty,
        previewReportText: String = "",
        decisionScore: KillDecisionScore = .empty,
        whyKillEvidence: [KillDecisionFactor] = [],
        whyWaitEvidence: [KillDecisionFactor] = [],
        targetConversionCount: Int = 0,
        cacheStatus: KillSnapshotCacheStatus = .none,
        strategyProfile: KillStrategyProfile = .standard,
        performanceReport: KillPerformanceReport = .empty,
        strategySimulation: KillStrategySimulation = .standard,
        watcherAvailable: Bool = false,
        arenaStats: KillGraphArenaStats = .empty,
        calibratedGracefulSuccess: Double? = nil,
        calibratedForceProbability: Double? = nil,
        calibratedSurvivorRisk: Double? = nil,
        recommendedGraceSeconds: TimeInterval? = nil,
        verificationPlanText: String = "Confirm uses a complete arena; pre-force and final verification use target-only reads unless watcher drift asks for a fresh arena.",
        riskAssessment: KillRiskAssessment = .none
    ) {
        self.displayName = displayName
        self.rootPID = rootPID
        self.targetIdentities = targetIdentities
        self.protectedPIDs = protectedPIDs
        self.deniedPIDs = deniedPIDs
        self.stalePIDs = stalePIDs
        self.recycledPIDs = recycledPIDs
        self.forceKillDelay = forceKillDelay
        self.targets = targets
        self.lockedTargets = lockedTargets
        self.staleTargets = staleTargets
        self.recycledTargets = recycledTargets
        self.readiness = readiness
        self.readinessReasons = readinessReasons
        self.estimatedMemoryReclaimBytes = estimatedMemoryReclaimBytes
        self.estimatedCPUReclaimPercent = estimatedCPUReclaimPercent
        self.preflightMilliseconds = preflightMilliseconds
        self.usedCheapSnapshot = usedCheapSnapshot
        self.reclaimEstimate = reclaimEstimate
        self.decisionEvidence = decisionEvidence
        self.forcePolicyText = forcePolicyText
        self.scopePreview = scopePreview
        self.strategyRecommendation = strategyRecommendation
        self.targetDiff = targetDiff
        self.decisionScore = decisionScore
        self.whyKillEvidence = whyKillEvidence
        self.whyWaitEvidence = whyWaitEvidence
        self.targetConversionCount = targetConversionCount
        self.cacheStatus = cacheStatus
        self.strategyProfile = strategyProfile
        self.performanceReport = performanceReport
        self.strategySimulation = strategySimulation
        self.watcherAvailable = watcherAvailable
        self.arenaStats = arenaStats
        self.calibratedGracefulSuccess = min(1, max(0, calibratedGracefulSuccess ?? strategySimulation.expectedGracefulSuccess))
        self.calibratedForceProbability = min(1, max(0, calibratedForceProbability ?? strategySimulation.forceProbability))
        self.calibratedSurvivorRisk = min(1, max(0, calibratedSurvivorRisk ?? strategySimulation.survivorRisk))
        self.recommendedGraceSeconds = max(0, recommendedGraceSeconds ?? strategyProfile.verificationSchedule.graceSeconds)
        self.verificationPlanText = verificationPlanText
        self.riskAssessment = riskAssessment
        self.previewReportText = previewReportText.isEmpty ? Self.makePreviewReport(
            displayName: displayName,
            readiness: readiness,
            targets: targets,
            lockedTargets: lockedTargets,
            staleTargets: staleTargets,
            recycledTargets: recycledTargets,
            reclaimEstimate: reclaimEstimate,
            strategy: strategyRecommendation,
            scope: scopePreview,
            recommendedGraceSeconds: max(0, recommendedGraceSeconds ?? strategyProfile.verificationSchedule.graceSeconds),
            verificationPlanText: verificationPlanText,
            risk: riskAssessment
        ) : previewReportText
    }

    private static func makePreviewReport(
        displayName: String,
        readiness: KillReadiness,
        targets: [KillTarget],
        lockedTargets: [KillTarget],
        staleTargets: [KillTarget],
        recycledTargets: [KillTarget],
        reclaimEstimate: KillReclaimEstimate,
        strategy: KillStrategyRecommendation,
        scope: KillScopePreview,
        recommendedGraceSeconds: TimeInterval,
        verificationPlanText: String,
        risk: KillRiskAssessment
    ) -> String {
        [
            "Ghost Process Sniper Kill Preview",
            "Family: \(displayName)",
            "Workload: \(risk.kind.label)\(risk.headline.map { " - \($0)" } ?? "")",
            "Risks: \(risk.risks.map { "\($0.title) (\($0.detail))" }.joined(separator: "; ").ifEmpty("none"))",
            "Readiness: \(readiness.label)",
            "Strategy: \(strategy.strategy.label) (\(Int((strategy.confidence * 100).rounded()))%)",
            "Recommended grace: \(String(format: "%.2f", recommendedGraceSeconds))s",
            "Verification: \(verificationPlanText)",
            "Scope: \(scope.scope.label) - \(scope.summary)",
            "Will signal: \(targets.map { String($0.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Will skip: \((lockedTargets + staleTargets + recycledTargets).map { String($0.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Nearby: \(scope.nearbyCandidates.map { String($0.identity.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Estimated reclaim: \(RadarFormat.bytes(reclaimEstimate.memoryBytes)), \(Int(reclaimEstimate.cpuPercent.rounded()))% CPU"
        ].joined(separator: "\n")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
