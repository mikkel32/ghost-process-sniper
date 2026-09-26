import Darwin
import Foundation

public struct KillHistorySummary: Codable, Equatable, Sendable {
    public let signatureID: String?
    public let operationCount: Int
    public let gracefulSuccessRate: Double
    public let forceRate: Double
    public let survivorRate: Double
    public let averageReclaimBytes: UInt64
    public let commonDenialCount: Int

    public static let empty = KillHistorySummary(
        signatureID: nil,
        operationCount: 0,
        gracefulSuccessRate: 0,
        forceRate: 0,
        survivorRate: 0,
        averageReclaimBytes: 0,
        commonDenialCount: 0
    )

    public init(
        signatureID: String?,
        operationCount: Int,
        gracefulSuccessRate: Double,
        forceRate: Double,
        survivorRate: Double,
        averageReclaimBytes: UInt64,
        commonDenialCount: Int
    ) {
        self.signatureID = signatureID
        self.operationCount = operationCount
        self.gracefulSuccessRate = min(1, max(0, gracefulSuccessRate))
        self.forceRate = min(1, max(0, forceRate))
        self.survivorRate = min(1, max(0, survivorRate))
        self.averageReclaimBytes = averageReclaimBytes
        self.commonDenialCount = commonDenialCount
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
            baseDuration = profile.graceSeconds + profile.secondaryGraceSeconds + 0.2
        case .stubbornRunaway:
            baseGrace = 0.42
            baseForce = 0.54
            baseSurvivor = 0.08
            baseDuration = profile.graceSeconds + profile.settleSeconds
        case .quitApp:
            // Apps answer a quit request well, but may pause on a save prompt.
            baseGrace = 0.84
            baseForce = 0.08
            baseSurvivor = 0.1
            baseDuration = profile.graceSeconds * 0.4 + profile.secondaryGraceSeconds
        case .carefulShutdown:
            baseGrace = 0.8
            baseForce = 0.12
            baseSurvivor = 0.08
            baseDuration = profile.graceSeconds * 0.5 + profile.settleSeconds
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
            baseDuration = profile.graceSeconds + profile.settleSeconds
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
        let learnedGrace = calibration.averageGraceSeconds > 0 ? calibration.averageGraceSeconds : base.graceSeconds
        let forceBias = calibration.forceRate >= 0.45 || calibration.survivorRate >= 0.25
        let reclaimBias = calibration.reclaimAccuracy < 0.45
        // Apps and databases get their clean-shutdown time as a floor: the
        // wait ends as soon as they exit, so a long ceiling costs nothing when
        // history says they are quick, and learning never cuts it short.
        let lowerBound: Double = switch base.strategy {
        case .quitApp, .carefulShutdown: base.graceSeconds
        case .gentleDevServer: 0.45
        default: 0.25
        }
        let upperBound = max(lowerBound, forceKillDelay)
        let tunedGrace = min(upperBound, max(lowerBound, forceBias || reclaimBias ? learnedGrace * 0.8 : learnedGrace * 1.08))
        let phases = base.phases.map { phase in
            guard phase.order == 0, !phase.isForce else {
                return phase
            }
            return phase.waiting(tunedGrace)
        }
        return KillStrategyProfile(
            strategy: base.strategy,
            confidence: min(1, base.confidence + min(0.08, Double(calibration.operationCount) * 0.01)),
            phases: phases,
            summary: "\(base.summary) Grace calibrated to \(String(format: "%.2f", tunedGrace))s from local outcomes."
        )
    }
}
