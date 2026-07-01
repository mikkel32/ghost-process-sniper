import Darwin
import Foundation

public struct KillStrategySimulation: Codable, Equatable, Sendable {
    public let strategy: KillStrategy
    public let expectedGracefulSuccess: Double
    public let forceProbability: Double
    public let survivorRisk: Double
    public let expectedDurationSeconds: TimeInterval
    public let summary: String

    public static let standard = KillStrategySimulation(
        strategy: .standard,
        expectedGracefulSuccess: 0.62,
        forceProbability: 0.28,
        survivorRisk: 0.06,
        expectedDurationSeconds: 2.35,
        summary: "Balanced SIGTERM-first intervention."
    )

    public init(
        strategy: KillStrategy,
        expectedGracefulSuccess: Double,
        forceProbability: Double,
        survivorRisk: Double,
        expectedDurationSeconds: TimeInterval,
        summary: String
    ) {
        self.strategy = strategy
        self.expectedGracefulSuccess = min(1, max(0, expectedGracefulSuccess))
        self.forceProbability = min(1, max(0, forceProbability))
        self.survivorRisk = min(1, max(0, survivorRisk))
        self.expectedDurationSeconds = max(0, expectedDurationSeconds)
        self.summary = summary
    }
}

public struct KillCalibrationSnapshot: Codable, Equatable, Sendable {
    public let signatureID: String?
    public let devKind: String?
    public let strategy: KillStrategy?
    public let operationCount: Int
    public let gracefulSuccessRate: Double
    public let forceRate: Double
    public let survivorRate: Double
    public let averageGraceSeconds: TimeInterval
    public let reclaimAccuracy: Double
    public let denialPenalty: Double
    public let updatedAt: Date?

    public static let empty = KillCalibrationSnapshot(
        signatureID: nil,
        devKind: nil,
        strategy: nil,
        operationCount: 0,
        gracefulSuccessRate: 0,
        forceRate: 0,
        survivorRate: 0,
        averageGraceSeconds: 0,
        reclaimAccuracy: 1,
        denialPenalty: 0,
        updatedAt: nil
    )

    public init(
        signatureID: String?,
        devKind: String?,
        strategy: KillStrategy?,
        operationCount: Int,
        gracefulSuccessRate: Double,
        forceRate: Double,
        survivorRate: Double,
        averageGraceSeconds: TimeInterval,
        reclaimAccuracy: Double,
        denialPenalty: Double,
        updatedAt: Date?
    ) {
        self.signatureID = signatureID
        self.devKind = devKind
        self.strategy = strategy
        self.operationCount = max(0, operationCount)
        self.gracefulSuccessRate = min(1, max(0, gracefulSuccessRate))
        self.forceRate = min(1, max(0, forceRate))
        self.survivorRate = min(1, max(0, survivorRate))
        self.averageGraceSeconds = max(0, averageGraceSeconds)
        self.reclaimAccuracy = min(1.5, max(0, reclaimAccuracy))
        self.denialPenalty = min(1, max(0, denialPenalty))
        self.updatedAt = updatedAt
    }
}

public struct InterventionPolicyEvaluation: Equatable, Sendable {
    public let decisionScore: KillDecisionScore
    public let recommendation: KillStrategyRecommendation
    public let profile: KillStrategyProfile
    public let simulation: KillStrategySimulation
    public let calibration: KillCalibrationSnapshot

    public init(
        decisionScore: KillDecisionScore,
        recommendation: KillStrategyRecommendation,
        profile: KillStrategyProfile,
        simulation: KillStrategySimulation,
        calibration: KillCalibrationSnapshot = .empty
    ) {
        self.decisionScore = decisionScore
        self.recommendation = recommendation
        self.profile = profile
        self.simulation = simulation
        self.calibration = calibration
    }
}

public struct KillStrategySimulator: Sendable {
    public init() {}

    public func simulate(
        recommendation: KillStrategyRecommendation,
        profile: KillStrategyProfile,
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        decisionScore: KillDecisionScore
    ) -> KillStrategySimulation {
        let history = plan.killHistory ?? .empty
        let baseGrace: Double
        let baseForce: Double
        let baseSurvivor: Double
        let baseDuration: TimeInterval

        switch recommendation.strategy {
        case .gentleDevServer:
            baseGrace = 0.76
            baseForce = 0.18
            baseSurvivor = 0.05
            baseDuration = profile.verificationSchedule.graceSeconds + profile.verificationSchedule.secondaryGraceSeconds + 0.2
        case .stubbornRunaway:
            baseGrace = 0.42
            baseForce = 0.54
            baseSurvivor = 0.08
            baseDuration = profile.verificationSchedule.graceSeconds + profile.verificationSchedule.settleSeconds
        case .inspectOnly:
            return KillStrategySimulation(
                strategy: .inspectOnly,
                expectedGracefulSuccess: 0,
                forceProbability: 0,
                survivorRisk: 0,
                expectedDurationSeconds: 0,
                summary: "No signal recommended; inspect the family before intervening."
            )
        case .standard:
            baseGrace = 0.62
            baseForce = 0.28
            baseSurvivor = 0.06
            baseDuration = profile.verificationSchedule.graceSeconds + profile.verificationSchedule.settleSeconds
        }

        let targetPenalty = min(0.18, Double(max(0, targets.count - 1)) * 0.025)
        let lockedPenalty = min(0.22, Double(locked.count) * 0.055)
        let scoreBoost = min(0.12, max(0, decisionScore.value - 55) / 400)
        let historyGrace = history.operationCount > 0 ? history.gracefulSuccessRate : baseGrace
        let historyForce = history.operationCount > 0 ? history.forceRate : baseForce
        let historySurvivor = history.operationCount > 0 ? history.survivorRate : baseSurvivor

        let graceful = (baseGrace * 0.68) + (historyGrace * 0.24) + scoreBoost - targetPenalty - lockedPenalty
        let force = (baseForce * 0.7) + (historyForce * 0.25) + targetPenalty + lockedPenalty
        let survivor = (baseSurvivor * 0.72) + (historySurvivor * 0.22) + lockedPenalty * 0.5

        return KillStrategySimulation(
            strategy: recommendation.strategy,
            expectedGracefulSuccess: graceful,
            forceProbability: force,
            survivorRisk: survivor,
            expectedDurationSeconds: baseDuration,
            summary: "Expected graceful \(Int((min(1, max(0, graceful)) * 100).rounded()))%, force \(Int((min(1, max(0, force)) * 100).rounded()))%, survivor \(Int((min(1, max(0, survivor)) * 100).rounded()))%."
        )
    }
}

public struct KillStrategyCalibrator: Sendable {
    public init() {}

    public func calibratedSimulation(
        base: KillStrategySimulation,
        calibration: KillCalibrationSnapshot
    ) -> KillStrategySimulation {
        guard calibration.operationCount > 0 else {
            return base
        }
        let weight = min(0.42, Double(calibration.operationCount) / 10 * 0.42)
        let graceful = base.expectedGracefulSuccess * (1 - weight) + calibration.gracefulSuccessRate * weight - calibration.denialPenalty * 0.08
        let force = base.forceProbability * (1 - weight) + calibration.forceRate * weight + calibration.denialPenalty * 0.04
        let survivor = base.survivorRisk * (1 - weight) + calibration.survivorRate * weight + calibration.denialPenalty * 0.08
        let duration = calibration.averageGraceSeconds > 0
            ? base.expectedDurationSeconds * 0.72 + calibration.averageGraceSeconds * 0.28
            : base.expectedDurationSeconds
        return KillStrategySimulation(
            strategy: base.strategy,
            expectedGracefulSuccess: graceful,
            forceProbability: force,
            survivorRisk: survivor,
            expectedDurationSeconds: duration,
            summary: "Calibrated graceful \(Int((min(1, max(0, graceful)) * 100).rounded()))%, force \(Int((min(1, max(0, force)) * 100).rounded()))%, survivor \(Int((min(1, max(0, survivor)) * 100).rounded()))% from \(calibration.operationCount) local outcome\(calibration.operationCount == 1 ? "" : "s")."
        )
    }

    public func tunedProfile(
        base: KillStrategyProfile,
        calibration: KillCalibrationSnapshot,
        forceKillDelay: TimeInterval
    ) -> KillStrategyProfile {
        guard calibration.operationCount > 0, base.strategy != .inspectOnly else {
            return base
        }
        let learnedGrace = calibration.averageGraceSeconds > 0 ? calibration.averageGraceSeconds : base.verificationSchedule.graceSeconds
        let forceBias = calibration.forceRate >= 0.45 || calibration.survivorRate >= 0.25
        let reclaimBias = calibration.reclaimAccuracy < 0.45
        let lowerBound = base.strategy == .gentleDevServer ? 0.45 : 0.25
        let upperBound = max(lowerBound, forceKillDelay)
        let tunedGrace = min(upperBound, max(lowerBound, forceBias || reclaimBias ? learnedGrace * 0.8 : learnedGrace * 1.08))
        let schedule = KillVerificationSchedule(
            graceSeconds: tunedGrace,
            secondaryGraceSeconds: base.verificationSchedule.secondaryGraceSeconds,
            settleSeconds: base.verificationSchedule.settleSeconds,
            allowsSkipForce: base.verificationSchedule.allowsSkipForce
        )
        let phases = base.phases.map { phase in
            guard phase.order == 0, phase.signal != nil, !phase.isForce else {
                return phase
            }
            return KillSignalPhase(
                order: phase.order,
                label: phase.label,
                signal: phase.signal,
                waitAfterSeconds: tunedGrace,
                isForce: phase.isForce
            )
        }
        return KillStrategyProfile(
            strategy: base.strategy,
            confidence: min(1, base.confidence + min(0.08, Double(calibration.operationCount) * 0.01)),
            phases: phases,
            verificationSchedule: schedule,
            summary: "\(base.summary) Grace calibrated to \(String(format: "%.2f", tunedGrace))s from local outcomes."
        )
    }
}

public struct InterventionPolicyEngine: Sendable {
    private let simulator = KillStrategySimulator()
    private let calibrator = KillStrategyCalibrator()

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
        let decisionScore = decisionScore(
            plan: plan,
            targets: targets,
            locked: locked,
            stale: stale,
            recycled: recycled,
            reclaim: reclaim,
            diff: diff,
            nearbyCount: nearbyCount
        )
        let recommendation = strategyRecommendation(
            plan: plan,
            targets: targets,
            locked: locked,
            decisionScore: decisionScore
        )
        let baseProfile = strategyProfile(
            recommendation: recommendation,
            forceKillDelay: forceKillDelay
        )
        let baseSimulation = simulator.simulate(
            recommendation: recommendation,
            profile: baseProfile,
            plan: plan,
            targets: targets,
            locked: locked,
            decisionScore: decisionScore
        )
        let calibration = plan.killCalibration ?? .empty
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
            calibration: calibration
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
        nearbyCount: Int
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

        let raw = factors.reduce(42.0) { $0 + $1.weight }
        let blockingPenalty = factors.contains { $0.kind == .blocking } ? 35.0 : 0
        let confidence = min(1, max(0.2, 0.45 + Double(targets.count) * 0.08 + reclaim.confidence * 0.25 - Double(locked.count) * 0.04))
        return KillDecisionScore(value: raw - blockingPenalty, confidence: confidence, factors: factors)
    }

    private func strategyRecommendation(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        decisionScore: KillDecisionScore
    ) -> KillStrategyRecommendation {
        if targets.isEmpty || decisionScore.factors.contains(where: { $0.kind == .blocking }) || locked.count >= max(3, targets.count) {
            return KillStrategyRecommendation(
                strategy: .inspectOnly,
                confidence: max(0.72, decisionScore.confidence),
                reasons: decisionScore.whyWait.prefix(2).map(\.detail).ifEmpty(["Low confidence or too many protected descendants."]),
                previewText: "Inspect only; no signal should be sent until ownership is clearer."
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
        if devServerHints.contains(where: { kind.contains($0) || plan.displayName.lowercased().contains($0) }) {
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
        forceKillDelay: TimeInterval
    ) -> KillStrategyProfile {
        let schedule: KillVerificationSchedule
        let phases: [KillSignalPhase]
        switch recommendation.strategy {
        case .standard:
            schedule = KillVerificationSchedule(graceSeconds: forceKillDelay, secondaryGraceSeconds: 0.15, settleSeconds: 0.35, allowsSkipForce: true)
            phases = [
                KillSignalPhase(order: 0, label: "Ask target to terminate", signal: SIGTERM, waitAfterSeconds: forceKillDelay, isForce: false),
                KillSignalPhase(order: 1, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .gentleDevServer:
            schedule = KillVerificationSchedule(graceSeconds: min(forceKillDelay, 1.2), secondaryGraceSeconds: 0.45, settleSeconds: 0.35, allowsSkipForce: true)
            phases = [
                KillSignalPhase(order: 0, label: "Interrupt dev server cleanly", signal: SIGINT, waitAfterSeconds: min(forceKillDelay, 1.2), isForce: false),
                KillSignalPhase(order: 1, label: "Terminate survivors", signal: SIGTERM, waitAfterSeconds: 0.45, isForce: false),
                KillSignalPhase(order: 2, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .stubbornRunaway:
            schedule = KillVerificationSchedule(graceSeconds: min(forceKillDelay, 0.8), secondaryGraceSeconds: 0.1, settleSeconds: 0.25, allowsSkipForce: true)
            phases = [
                KillSignalPhase(order: 0, label: "Terminate runaway", signal: SIGTERM, waitAfterSeconds: min(forceKillDelay, 0.8), isForce: false),
                KillSignalPhase(order: 1, label: "Force verified survivors", signal: SIGKILL, waitAfterSeconds: 0.25, isForce: true)
            ]
        case .inspectOnly:
            schedule = KillVerificationSchedule(graceSeconds: 0, secondaryGraceSeconds: 0, settleSeconds: 0, allowsSkipForce: false)
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
