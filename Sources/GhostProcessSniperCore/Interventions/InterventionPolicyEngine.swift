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
            factors.append(contentsOf: radarFactors(metadata))
        }
        if !locked.isEmpty {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Protected descendants", detail: "\(locked.count) locked or foreign process\(locked.count == 1 ? "" : "es") will be skipped.", weight: -min(24, Double(locked.count) * 6)))
        }
        if !stale.isEmpty || !recycled.isEmpty || !diff.isEmpty {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Tree drift", detail: diff.summary, weight: -min(20, Double(stale.count + recycled.count + diff.reparentedPIDs.count) * 5)))
        }
        if let history = plan.killHistory {
            factors.append(contentsOf: historyFactors(history))
        }

        factors.append(contentsOf: riskFactors(risk))

        let raw = factors.reduce(42.0) { $0 + $1.weight }
        let blockingPenalty = factors.contains { $0.kind == .blocking } ? 35.0 : 0
        let confidence = min(1, max(0.2, 0.45 + Double(targets.count) * 0.08 + reclaim.confidence * 0.25 - Double(locked.count) * 0.04))
        return KillDecisionScore(value: raw - blockingPenalty, confidence: confidence, factors: factors)
    }

    /// History informs the decision but never blocks it: one survivor held
    /// on purpose, or a refused child, must not lock a family out of
    /// stopping. It speaks only once there are a few stops to go by.
    private func historyFactors(_ history: KillHistorySummary) -> [KillDecisionFactor] {
        var factors: [KillDecisionFactor] = []
        let count = history.operationCount
        if count >= 3 {
            let survived = Int((history.survivorRate * Double(count)).rounded())
            if survived > 0 {
                factors.append(KillDecisionFactor(kind: .whyWait, title: "Past stops left something running",
                                                  detail: "\(survived) of the last \(count) stops left a process running.",
                                                  weight: -12 * history.survivorRate, source: .history))
            }
            if history.forceRate >= 0.5 {
                factors.append(KillDecisionFactor(kind: .whyWait, title: "Force history",
                                                  detail: "\(Int((history.forceRate * 100).rounded()))% of recent stops needed force.",
                                                  weight: -6, source: .history))
            }
        }
        if count > 0, history.gracefulSuccessRate >= 0.65 {
            factors.append(KillDecisionFactor(kind: .whyKill, title: "Graceful history",
                                              detail: "\(Int((history.gracefulSuccessRate * 100).rounded()))% of recent stops ended cleanly.",
                                              weight: 8, source: .history))
        }
        return factors
    }

    /// What the radar saw, named for what it is. The forecast states are
    /// ordered by display, not by urgency, so they are matched explicitly:
    /// a forgotten (stale) family is not a runaway.
    private func radarFactors(_ metadata: KillFamilyMetadata) -> [KillDecisionFactor] {
        let state = "\(metadata.scoreLevel.label), forecast \(metadata.forecastState.label.lowercased())."
        var factors: [KillDecisionFactor] = []
        if [.runaway, .critical].contains(metadata.forecastState) || metadata.scoreLevel >= .critical {
            factors.append(KillDecisionFactor(kind: .whyKill, title: "Runaway", detail: state, weight: 22, source: .radar))
        } else if metadata.forecastState == .leaking {
            factors.append(KillDecisionFactor(kind: .whyKill, title: "Leaking memory", detail: state, weight: 14, source: .radar))
        }
        if metadata.forecastState == .stale {
            let detail = metadata.forecastReason.isEmpty ? "Idle and likely forgotten." : metadata.forecastReason
            factors.append(KillDecisionFactor(kind: .whyKill, title: "Forgotten", detail: detail, weight: 10, source: .radar))
        }
        return factors
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
            return KillDecisionFactor(kind: item.isBenefit ? .whyKill : .whyWait, title: item.title, detail: item.detail, weight: weight, source: .risk)
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
                previewText: "Quit like \u{2318}Q, then SIGTERM anything left; SIGKILL only for same-identity survivors."
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
        if Self.mayForceQuickly(risk), let history = plan.killHistory, history.operationCount >= 4, history.forceRate >= 0.75 {
            return KillStrategyRecommendation(
                strategy: .stubbornRunaway,
                confidence: max(0.74, decisionScore.confidence),
                reasons: ["This family often survives graceful shutdown; expect force verification."],
                previewText: "SIGTERM, verify, then SIGKILL same-identity survivors if needed."
            )
        }
        if risk.kind == .devServer {
            return KillStrategyRecommendation(
                strategy: .gentleDevServer,
                confidence: max(0.76, decisionScore.confidence),
                reasons: ["Looks like a dev server; try SIGINT before SIGTERM."],
                previewText: "SIGINT, verify, then SIGTERM; SIGKILL only for same-identity survivors."
            )
        }
        return KillStrategyRecommendation(
            strategy: .standard,
            confidence: max(0.65, decisionScore.confidence),
            reasons: ["Balanced default based on current evidence."],
            previewText: "SIGTERM, verify, then SIGKILL surviving same-identity targets."
        )
    }

    /// A quick SIGKILL is only for work that loses nothing when forced;
    /// a big footprint or a high score says nothing about ignoring SIGTERM.
    static func mayForceQuickly(_ risk: KillRiskAssessment) -> Bool {
        !risk.forceNeedsConfirmation && [.general, .devServer, .build, .modelRunner].contains(risk.kind)
    }

    /// The first wait of each strategy before learning. The workload's own
    /// shutdown time (git 5 s, installs 4 s, databases 12 s) is a floor for
    /// every strategy, not only for apps and databases.
    static func defaultGrace(_ strategy: KillStrategy, forceKillDelay: TimeInterval, risk: KillRiskAssessment) -> TimeInterval {
        let base: TimeInterval = switch strategy {
        case .standard, .quitApp, .carefulShutdown: forceKillDelay
        case .gentleDevServer: min(forceKillDelay, 1.2)
        case .stubbornRunaway: min(forceKillDelay, 0.8)
        case .inspectOnly: 0
        }
        return strategy == .inspectOnly ? 0 : max(base, risk.graceSeconds ?? 0)
    }

    private func strategyProfile(
        recommendation: KillStrategyRecommendation,
        forceKillDelay: TimeInterval,
        risk: KillRiskAssessment
    ) -> KillStrategyProfile {
        let grace = Self.defaultGrace(recommendation.strategy, forceKillDelay: forceKillDelay, risk: risk)
        let schedule: KillVerificationSchedule
        let phases: [KillSignalPhase]
        switch recommendation.strategy {
        case .standard:
            schedule = KillVerificationSchedule(graceSeconds: grace, secondaryGraceSeconds: 0.15, settleSeconds: 0.35)
            phases = [
                KillSignalPhase(order: 0, label: "Ask target to terminate", signal: SIGTERM, waitAfterSeconds: grace, isForce: false),
                KillSignalPhase(order: 1, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .gentleDevServer:
            schedule = KillVerificationSchedule(graceSeconds: grace, secondaryGraceSeconds: 0.45, settleSeconds: 0.35)
            phases = [
                KillSignalPhase(order: 0, label: "Interrupt dev server cleanly", signal: SIGINT, waitAfterSeconds: grace, isForce: false),
                KillSignalPhase(order: 1, label: "Terminate survivors", signal: SIGTERM, waitAfterSeconds: 0.45, isForce: false),
                KillSignalPhase(order: 2, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .stubbornRunaway:
            schedule = KillVerificationSchedule(graceSeconds: grace, secondaryGraceSeconds: 0.1, settleSeconds: 0.25)
            phases = [
                KillSignalPhase(order: 0, label: "Terminate runaway", signal: SIGTERM, waitAfterSeconds: grace, isForce: false),
                KillSignalPhase(order: 1, label: "Force verified survivors", signal: SIGKILL, waitAfterSeconds: 0.25, isForce: true)
            ]
        case .quitApp:
            schedule = KillVerificationSchedule(graceSeconds: grace, secondaryGraceSeconds: 1.5, settleSeconds: 0.35)
            phases = [
                KillSignalPhase(order: 0, label: "Ask the app to quit, like \u{2318}Q", signal: KillSignalPhase.quitRequest, waitAfterSeconds: grace, isForce: false),
                KillSignalPhase(order: 1, label: "Terminate what is left", signal: SIGTERM, waitAfterSeconds: 1.5, isForce: false),
                KillSignalPhase(order: 2, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .carefulShutdown:
            schedule = KillVerificationSchedule(graceSeconds: grace, secondaryGraceSeconds: 0.2, settleSeconds: 0.5)
            phases = [
                KillSignalPhase(order: 0, label: "Request a clean shutdown", signal: SIGTERM, waitAfterSeconds: grace, isForce: false),
                KillSignalPhase(order: 1, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.5, isForce: true)
            ]
        case .inspectOnly:
            schedule = KillVerificationSchedule(graceSeconds: 0, secondaryGraceSeconds: 0, settleSeconds: 0)
            phases = []
        }
        return KillStrategyProfile(
            strategy: recommendation.strategy,
            confidence: recommendation.confidence,
            phases: phases,
            verificationSchedule: schedule,
            summary: recommendation.previewText
        )
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: [String]) -> [String] {
        isEmpty ? fallback : self
    }
}
