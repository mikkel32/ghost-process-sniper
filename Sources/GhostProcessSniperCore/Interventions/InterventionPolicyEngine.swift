import Darwin
import Foundation

public struct InterventionPolicyEvaluation: Equatable, Sendable {
    public let decisionScore: KillDecisionScore
    public let recommendation: KillStrategyRecommendation
    public let profile: KillStrategyProfile
    public let simulation: KillStrategySimulation
    public let calibration: KillCalibrationSnapshot
    public let risk: KillRiskAssessment

    public init(
        decisionScore: KillDecisionScore,
        recommendation: KillStrategyRecommendation,
        profile: KillStrategyProfile,
        simulation: KillStrategySimulation,
        calibration: KillCalibrationSnapshot = .empty,
        risk: KillRiskAssessment = .none
    ) {
        self.decisionScore = decisionScore
        self.recommendation = recommendation
        self.profile = profile
        self.simulation = simulation
        self.calibration = calibration
        self.risk = risk
    }
}

public struct InterventionPolicyEngine: Sendable {
    private let simulator = KillStrategySimulator()
    private let calibrator = KillStrategyCalibrator()
    private let riskAssessor = KillRiskAssessor()

    public init() {}

    public func evaluate(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        reclaim: KillReclaimEstimate,
        diff: KillTargetDiff,
        nearbyCount: Int,
        forceKillDelay: TimeInterval
    ) -> InterventionPolicyEvaluation {
        let risk = riskAssessor.assess(plan.workload ?? .empty)
        let decisionScore = decisionScore(
            plan: plan,
            targets: targets,
            locked: locked,
            stale: stale,
            recycled: recycled,
            reclaim: reclaim,
            diff: diff,
            nearbyCount: nearbyCount,
            risk: risk
        )
        let recommendation = strategyRecommendation(
            plan: plan,
            targets: targets,
            locked: locked,
            decisionScore: decisionScore,
            risk: risk
        )
        let baseProfile = strategyProfile(
            recommendation: recommendation,
            forceKillDelay: forceKillDelay,
            risk: risk
        )
        let baseSimulation = simulator.simulate(
            recommendation: recommendation,
            profile: baseProfile,
            plan: plan,
            targets: targets,
            locked: locked,
            decisionScore: decisionScore
        )
        let calibration = plan.calibration(for: recommendation.strategy)
        let profile = calibrator.tunedProfile(
            base: baseProfile,
            calibration: calibration,
            forceKillDelay: forceKillDelay
        )
        let simulation = calibrator.calibratedSimulation(
            base: baseSimulation,
            calibration: calibration
        )
        return InterventionPolicyEvaluation(
            decisionScore: decisionScore,
            recommendation: recommendation,
            profile: profile,
            simulation: simulation,
            calibration: calibration,
            risk: risk
        )
    }

    private func decisionScore(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        reclaim: KillReclaimEstimate,
        diff: KillTargetDiff,
        nearbyCount: Int,
        risk: KillRiskAssessment
    ) -> KillDecisionScore {
        var factors: [KillDecisionFactor] = []
        if targets.isEmpty {
            factors.append(KillDecisionFactor(kind: .blocking, title: "No owned targets", detail: "No same-user live identity matched the selected tree.", weight: -100))
        } else {
            factors.append(KillDecisionFactor(kind: .whyKill, title: "Identity verified", detail: "\(targets.count) target\(targets.count == 1 ? "" : "s") matched PID plus start time.", weight: 24))
        }
        if reclaim.memoryBytes > 0 || reclaim.cpuPercent > 0 {
            let reclaimWeight = min(18, Double(reclaim.memoryBytes) / Double(256 * 1_048_576) * 3 + reclaim.cpuPercent / 8)
            factors.append(KillDecisionFactor(kind: .whyKill, title: "Likely reclaim", detail: "\(RadarFormat.bytes(reclaim.memoryBytes)), \(Int(reclaim.cpuPercent.rounded()))% CPU.", weight: reclaimWeight))
        }
        if let metadata = plan.familyMetadata {
            if metadata.scoreLevel >= .hot || metadata.forecastState >= .leaking {
                let weight: Double = metadata.scoreLevel >= .critical || metadata.forecastState >= .runaway ? 22 : 14
                factors.append(KillDecisionFactor(kind: .whyKill, title: "High-risk radar state", detail: "\(metadata.scoreLevel.label), forecast \(metadata.forecastState.label).", weight: weight))
            }
            if metadata.isBackgroundOrOrphan {
                factors.append(KillDecisionFactor(kind: .whyKill, title: "Background candidate", detail: "The root appears orphaned or backgrounded.", weight: 10))
            }
            if metadata.devKindLabel.localizedCaseInsensitiveContains("build") && metadata.scoreLevel < .critical {
                factors.append(KillDecisionFactor(kind: .whyWait, title: "Active build caution", detail: "Build-like process; interrupt only when stale or critical.", weight: -24))
            }
        }
        if !locked.isEmpty {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Protected descendants", detail: "\(locked.count) locked or foreign process\(locked.count == 1 ? "" : "es") will be skipped.", weight: -min(24, Double(locked.count) * 6)))
        }
        if !stale.isEmpty || !recycled.isEmpty || !diff.isEmpty {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Tree drift", detail: diff.summary, weight: -min(20, Double(stale.count + recycled.count + diff.reparentedPIDs.count) * 5)))
        }
        if nearbyCount > 0 {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Nearby process group", detail: "\(nearbyCount) same-user neighbor\(nearbyCount == 1 ? "" : "s") shown but not targeted.", weight: -4))
        }
        if let history = plan.killHistory, history.operationCount > 0 {
            if history.forceRate >= 0.5 {
                factors.append(KillDecisionFactor(kind: .whyWait, title: "Force history", detail: "\(Int((history.forceRate * 100).rounded()))% of recent interventions required force.", weight: -10))
            }
            if history.gracefulSuccessRate >= 0.65 {
                factors.append(KillDecisionFactor(kind: .whyKill, title: "Graceful history", detail: "\(Int((history.gracefulSuccessRate * 100).rounded()))% recent graceful success.", weight: 8))
            }
            if history.survivorRate >= 0.35 || history.commonDenialCount >= 2 {
                factors.append(KillDecisionFactor(kind: .blocking, title: "Poor intervention history", detail: "Recent interventions had survivors or repeated denials.", weight: -35))
            }
        }

        factors.append(contentsOf: riskFactors(risk))

        let raw = factors.reduce(42.0) { $0 + $1.weight }
        let blockingPenalty = factors.contains { $0.kind == .blocking } ? 35.0 : 0
        let confidence = min(1, max(0.2, 0.45 + Double(targets.count) * 0.08 + reclaim.confidence * 0.25 - Double(locked.count) * 0.04))
        return KillDecisionScore(value: raw - blockingPenalty, confidence: confidence, factors: factors)
    }

    /// Consequences weigh on the decision without blocking it: the user may
    /// well want a restarting process restarted, or a stuck database gone.
    private func riskFactors(_ risk: KillRiskAssessment) -> [KillDecisionFactor] {
        risk.risks.map { item in
            let weight: Double = switch (item.isBenefit, item.kind, item.severity) {
            case (true, .orphaned, _): 8
            case (true, _, _): 4
            case (false, .respawn, _): -12
            case (false, _, .danger): -14
            case (false, _, .caution): -6
            case (false, _, .info): -1
            }
            return KillDecisionFactor(kind: item.isBenefit ? .whyKill : .whyWait, title: item.title, detail: item.detail, weight: weight)
        }
    }

    private func strategyRecommendation(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        decisionScore: KillDecisionScore,
        risk: KillRiskAssessment
    ) -> KillStrategyRecommendation {
        if targets.isEmpty || decisionScore.factors.contains(where: { $0.kind == .blocking }) || locked.count >= max(3, targets.count) {
            return KillStrategyRecommendation(
                strategy: .inspectOnly,
                confidence: max(0.72, decisionScore.confidence),
                reasons: decisionScore.whyWait.prefix(2).map(\.detail).ifEmpty(["Low confidence or too many protected descendants."]),
                previewText: "Inspect only; no signal should be sent until ownership is clearer."
            )
        }
        if let quitPID = risk.appQuitPID, targets.contains(where: { $0.pid == quitPID }) {
            return KillStrategyRecommendation(
                strategy: .quitApp,
                confidence: max(0.82, decisionScore.confidence),
                reasons: ["\(risk.kind.label): quitting lets it save state and close its own helpers."],
                previewText: "Quit like \u{2318}Q, then SIGTERM leftover helpers; SIGKILL only for same-identity survivors."
            )
        }
        if risk.kind == .dataStore || risk.kind == .containerRuntime {
            return KillStrategyRecommendation(
                strategy: .carefulShutdown,
                confidence: max(0.8, decisionScore.confidence),
                reasons: ["\(risk.kind.label): needs time to flush data before it exits."],
                previewText: "SIGTERM with a long grace period; SIGKILL only if you allow it."
            )
        }
        if let history = plan.killHistory, history.operationCount >= 2, history.forceRate >= 0.5 {
            return KillStrategyRecommendation(
                strategy: .stubbornRunaway,
                confidence: max(0.74, decisionScore.confidence),
                reasons: ["This family often survives graceful shutdown; expect force verification."],
                previewText: "SIGTERM, verify, then SIGKILL same-identity survivors if needed."
            )
        }
        let kind = plan.familyMetadata?.devKindLabel.lowercased() ?? plan.displayName.lowercased()
        let devServerHints = ["node", "vite", "python", "ruby", "swift", "server", "bun", "deno", "go service", "php", "dotnet"]
        let looksLikeDevServer = risk.kind == .devServer ||
            (risk.kind == .general && devServerHints.contains(where: { kind.contains($0) || plan.displayName.lowercased().contains($0) }))
        if looksLikeDevServer {
            return KillStrategyRecommendation(
                strategy: .gentleDevServer,
                confidence: max(0.76, decisionScore.confidence),
                reasons: ["Looks like a dev server; try SIGINT before SIGTERM."],
                previewText: "SIGINT, verify, then SIGTERM; SIGKILL only for same-identity survivors."
            )
        }
        if plan.familyMetadata?.forecastState == .runaway || plan.familyMetadata?.scoreLevel == .critical || decisionScore.value >= 82 {
            return KillStrategyRecommendation(
                strategy: .stubbornRunaway,
                confidence: max(0.72, decisionScore.confidence),
                reasons: ["Critical, runaway, or high-confidence ghost process; expect possible force escalation."],
                previewText: "SIGTERM, short verification, then SIGKILL same-identity survivors."
            )
        }
        return KillStrategyRecommendation(
            strategy: .standard,
            confidence: max(0.65, decisionScore.confidence),
            reasons: ["Balanced default based on current evidence."],
            previewText: "SIGTERM, verify, then SIGKILL surviving same-identity targets."
        )
    }

    private func strategyProfile(
        recommendation: KillStrategyRecommendation,
        forceKillDelay: TimeInterval,
        risk: KillRiskAssessment
    ) -> KillStrategyProfile {
        let cleanShutdownGrace = max(forceKillDelay, risk.graceSeconds ?? forceKillDelay)
        let phases: [KillSignalPhase] = switch recommendation.strategy {
        case .standard: [
            KillSignalPhase(order: 0, label: "Ask target to terminate", action: .signal(SIGTERM), waitAfterSeconds: forceKillDelay),
            KillSignalPhase(order: 1, label: "Force same-identity survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ]
        case .gentleDevServer: [
            KillSignalPhase(order: 0, label: "Interrupt dev server cleanly", action: .signal(SIGINT), waitAfterSeconds: min(forceKillDelay, 1.2)),
            KillSignalPhase(order: 1, label: "Terminate survivors", action: .signal(SIGTERM), waitAfterSeconds: 0.45),
            KillSignalPhase(order: 2, label: "Force same-identity survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ]
        case .stubbornRunaway: [
            KillSignalPhase(order: 0, label: "Terminate runaway", action: .signal(SIGTERM), waitAfterSeconds: min(forceKillDelay, 0.8)),
            KillSignalPhase(order: 1, label: "Force verified survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.25)
        ]
        // The app itself is never sent SIGTERM: it would close past a
        // save prompt. Only its leftover helpers are, and the app is forced.
        case .quitApp: [
            KillSignalPhase(order: 0, label: "Ask the app to quit, like \u{2318}Q", action: .quitRequest, waitAfterSeconds: cleanShutdownGrace),
            KillSignalPhase(order: 1, label: "Terminate leftover helpers", action: .signal(SIGTERM), waitAfterSeconds: 1.5),
            KillSignalPhase(order: 2, label: "Force same-identity survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ]
        case .carefulShutdown: [
            KillSignalPhase(order: 0, label: "Request a clean shutdown", action: .signal(SIGTERM), waitAfterSeconds: cleanShutdownGrace),
            KillSignalPhase(order: 1, label: "Force same-identity survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.5)
        ]
        case .inspectOnly: []
        }
        return KillStrategyProfile(
            strategy: recommendation.strategy,
            confidence: recommendation.confidence,
            phases: phases,
            summary: recommendation.previewText
        )
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: [String]) -> [String] {
        isEmpty ? fallback : self
    }
}
