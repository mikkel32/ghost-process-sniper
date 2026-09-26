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

/// What one stop says about how the family stops. Only stops that signalled
/// and ran their course count: a held force, a refused signal or a
/// supervisor restarting the process says nothing about SIGTERM.
public struct KillOutcomeObservation: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Every target exited within the grace, without force.
        case clean
        /// Something needed force, survived or failed.
        case dirty
        /// A supervisor started it again; counted apart.
        case respawned
        /// Nothing to learn from.
        case excluded
    }

    public let strategy: KillStrategy
    public let outcome: Outcome
    /// How long the graceful wait lasted.
    public let latencySeconds: TimeInterval
    /// The wait ran out: the true exit time is longer than the latency.
    public let censored: Bool

    public init(strategy: KillStrategy, outcome: Outcome, latencySeconds: TimeInterval, censored: Bool) {
        self.strategy = strategy
        self.outcome = outcome
        self.latencySeconds = max(0, latencySeconds)
        self.censored = censored
    }

    public init(report: KillReport) {
        let outcome: Outcome
        if report.attempts.isEmpty || report.strategyUsed == .inspectOnly || report.skipForceRequested || !report.signalDeniedPIDs.isEmpty
            || report.graceWatchedNothing {
            outcome = .excluded
        } else if !report.respawnedPIDs.isEmpty {
            outcome = .respawned
        } else if report.forcedPIDs.isEmpty, report.survivorPIDs.isEmpty, report.failures.isEmpty, report.graceEndedEarly {
            outcome = .clean
        } else {
            outcome = .dirty
        }
        self.init(strategy: report.strategyUsed, outcome: outcome, latencySeconds: report.graceWaitedSeconds,
                  censored: !report.graceEndedEarly)
    }
}

/// A Beta posterior over "stops cleanly" plus a histogram of exit times,
/// both decayed so recent stops weigh more than old ones.
public struct KillOutcomePosterior: Codable, Equatable, Sendable {
    public static let decay = 0.9
    /// Upper edges of the exit-time buckets; the last bucket is open.
    public static let latencyEdges: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8, 16]
    static let openBucketCeiling: TimeInterval = 32

    public private(set) var observationCount: Int
    /// Clean stops, undecayed, so the evidence can state a true count.
    public private(set) var cleanCount: Int
    public private(set) var cleanWeight: Double
    public private(set) var totalWeight: Double
    public private(set) var latencyBuckets: [Double]
    /// Stops in a row that a supervisor undid.
    public private(set) var respawnRun: Int
    /// Stops in a row whose wait ran out.
    public private(set) var censoredRun: Int
    public private(set) var updatedAt: Date?

    public static let empty = KillOutcomePosterior(
        observationCount: 0, cleanCount: 0, cleanWeight: 0, totalWeight: 0, latencyBuckets: [], respawnRun: 0, censoredRun: 0, updatedAt: nil
    )

    public init(
        observationCount: Int,
        cleanCount: Int,
        cleanWeight: Double,
        totalWeight: Double,
        latencyBuckets: [Double],
        respawnRun: Int,
        censoredRun: Int,
        updatedAt: Date?
    ) {
        self.observationCount = max(0, observationCount)
        self.cleanCount = min(self.observationCount, max(0, cleanCount))
        self.totalWeight = max(0, totalWeight)
        self.cleanWeight = min(self.totalWeight, max(0, cleanWeight))
        let count = Self.latencyEdges.count + 1
        self.latencyBuckets = latencyBuckets.count == count ? latencyBuckets.map { max(0, $0) } : Array(repeating: 0, count: count)
        self.respawnRun = max(0, respawnRun)
        self.censoredRun = max(0, censoredRun)
        self.updatedAt = updatedAt
    }

    public var hasEvidence: Bool { totalWeight > 0 }

    public func updating(with observation: KillOutcomeObservation, at date: Date) -> KillOutcomePosterior {
        var next = self
        switch observation.outcome {
        case .excluded:
            return self
        case .respawned:
            next.respawnRun += 1
        case .clean, .dirty:
            let clean = observation.outcome == .clean
            next.observationCount += 1
            next.cleanCount += clean ? 1 : 0
            next.cleanWeight = cleanWeight * Self.decay + (clean ? 1 : 0)
            next.totalWeight = totalWeight * Self.decay + 1
            next.latencyBuckets = latencyBuckets.map { $0 * Self.decay }
            next.latencyBuckets[Self.bucket(for: observation)] += 1
            next.censoredRun = observation.censored ? censoredRun + 1 : 0
            next.respawnRun = 0
        }
        next.updatedAt = date
        return next
    }

    /// Clean exits at the observed time; a wait that ran out in the first
    /// bucket above its grace, since the exit would have come later.
    static func bucket(for observation: KillOutcomeObservation) -> Int {
        let latency = observation.latencySeconds
        let index = observation.censored
            ? latencyEdges.firstIndex { $0 > latency }
            : latencyEdges.firstIndex { latency <= $0 }
        return index ?? latencyEdges.count
    }

    /// Exit time below which `fraction` of the stops fall, interpolated
    /// within its bucket. Nil without evidence.
    public func latencyQuantile(_ fraction: Double) -> TimeInterval? {
        let total = latencyBuckets.reduce(0, +)
        guard total > 0 else { return nil }
        let target = min(1, max(0, fraction)) * total
        var below = 0.0
        for (index, weight) in latencyBuckets.enumerated() where weight > 0 {
            if below + weight >= target {
                let lower = index == 0 ? 0 : Self.latencyEdges[index - 1]
                let upper = index < Self.latencyEdges.count ? Self.latencyEdges[index] : Self.openBucketCeiling
                return lower + (target - below) / weight * (upper - lower)
            }
            below += weight
        }
        return Self.openBucketCeiling
    }

    /// Stubborn stops count toward SIGTERM's record: their clean exits do,
    /// their quick SIGKILLs do not, so a family can earn its way back to a
    /// normal grace.
    func addingCleanExits(of stubborn: KillOutcomePosterior) -> KillOutcomePosterior {
        guard stubborn.observationCount > 0 else { return self }
        let allCensored = stubborn.censoredRun == stubborn.observationCount
        return KillOutcomePosterior(
            observationCount: observationCount + stubborn.cleanCount,
            cleanCount: cleanCount + stubborn.cleanCount,
            cleanWeight: cleanWeight + stubborn.cleanWeight,
            totalWeight: totalWeight + stubborn.cleanWeight,
            latencyBuckets: latencyBuckets,
            respawnRun: respawnRun,
            censoredRun: allCensored ? censoredRun + stubborn.censoredRun : stubborn.censoredRun,
            updatedAt: [updatedAt, stubborn.updatedAt].compactMap { $0 }.max()
        )
    }
}

/// Outcome posteriors for one family, per strategy, and for its kind of
/// family, which serves as the prior while the family itself is new.
public struct KillOutcomeHistory: Equatable, Sendable {
    public var signature: [KillStrategy: KillOutcomePosterior]
    public var kind: [KillStrategy: KillOutcomePosterior]

    public static let empty = KillOutcomeHistory(signature: [:], kind: [:])

    public init(signature: [KillStrategy: KillOutcomePosterior] = [:], kind: [KillStrategy: KillOutcomePosterior] = [:]) {
        self.signature = signature
        self.kind = kind
    }

    /// The family's most recent stop was undone by a supervisor.
    public var lastStopRespawned: Bool {
        signature.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }.map { $0.respawnRun > 0 } ?? false
    }
}
