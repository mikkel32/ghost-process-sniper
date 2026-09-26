import Foundation

/// What past stops predict for the next one, in terms a person can check.
public struct KillStrategyForecast: Equatable, Sendable {
    public let strategy: KillStrategy
    /// Posterior mean of "every target exits within the grace, unforced".
    public let pClean: Double
    /// The value pClean stays below with 80% confidence.
    public let pCleanUpper80: Double
    /// Median exit time, when there are exits to go by.
    public let typicalExitSeconds: TimeInterval?
    /// How long to wait for a clean exit before any force.
    public let graceSeconds: TimeInterval
    /// Stops of this family behind the numbers, not counting its kind.
    public let observationCount: Int
    public let evidenceText: String

    public static let none = KillStrategyForecast(
        strategy: .inspectOnly, pClean: 0, pCleanUpper80: 0, typicalExitSeconds: nil, graceSeconds: 0,
        observationCount: 0, evidenceText: "No signal will be sent."
    )

    public init(
        strategy: KillStrategy,
        pClean: Double,
        pCleanUpper80: Double,
        typicalExitSeconds: TimeInterval?,
        graceSeconds: TimeInterval,
        observationCount: Int,
        evidenceText: String
    ) {
        self.strategy = strategy
        self.pClean = min(1, max(0, pClean))
        self.pCleanUpper80 = min(1, max(self.pClean, pCleanUpper80))
        self.typicalExitSeconds = typicalExitSeconds
        self.graceSeconds = max(0, graceSeconds)
        self.observationCount = max(0, observationCount)
        self.evidenceText = evidenceText
    }
}

/// Beta-Binomial learning of how a family stops, with the family's kind as
/// the prior and exit times kept as a censored histogram. It replaces
/// invented odds: with no history it says so, and one stop moves it little.
public struct KillOutcomeModel: Sendable {
    /// Pseudo-stops the prior is worth; a few real stops outweigh it.
    public static let priorStrength = 4.0
    /// Below this upper bound, SIGTERM rarely works for the family.
    public static let stubbornUpperBound = 0.3
    /// Stops in a row that ran out their wait before the grace shortens.
    public static let stubbornRun = 4
    public static let stubbornGrace: TimeInterval = 0.5
    private static let z80 = 0.8416

    public let history: KillOutcomeHistory

    public init(history: KillOutcomeHistory) {
        self.history = history
    }

    /// Before any history, from the strategies' track record in general.
    public static func defaultCleanRate(_ strategy: KillStrategy) -> Double {
        switch strategy {
        case .standard: 0.62
        case .gentleDevServer: 0.76
        case .quitApp: 0.84
        case .carefulShutdown: 0.8
        case .stubbornRunaway: 0.42
        case .inspectOnly: 0
        }
    }

    /// Evidence for a strategy. Stubborn stops are judged on the strategy
    /// they replace (`base`), and their clean exits, after a SIGTERM, join
    /// the standard strategy's record: quick SIGKILLs cannot keep a family
    /// stubborn, while exits on SIGTERM can bring it back.
    func posteriors(for strategy: KillStrategy, base: KillStrategy?) -> (signature: KillOutcomePosterior, kind: KillOutcomePosterior) {
        let evidenceStrategy = strategy == .stubbornRunaway ? base ?? strategy : strategy
        var signature = history.signature[evidenceStrategy] ?? .empty
        var kind = history.kind[evidenceStrategy] ?? .empty
        if evidenceStrategy == .standard {
            signature = signature.addingCleanExits(of: history.signature[.stubbornRunaway] ?? .empty)
            kind = kind.addingCleanExits(of: history.kind[.stubbornRunaway] ?? .empty)
        }
        return (signature, kind)
    }

    /// - Parameters:
    ///   - floorSeconds: the strategy's own grace, at least the workload's.
    ///     Learning never waits less, except for a family proven stubborn.
    public func forecast(
        strategy: KillStrategy,
        base: KillStrategy? = nil,
        workloadKind: KillWorkloadKind,
        floorSeconds: TimeInterval,
        forceKillDelay: TimeInterval
    ) -> KillStrategyForecast {
        guard strategy != .inspectOnly else { return .none }
        let (signature, kind) = posteriors(for: strategy, base: base)
        let priorStrategy = strategy == .stubbornRunaway ? base ?? strategy : strategy
        let baseRate = Self.defaultCleanRate(priorStrategy)
        // The kind row also holds this family's own stops, so while few
        // other families of the kind were stopped they shape the prior too.
        // That is what lets four ignored SIGTERMs make a classified family
        // stubborn; an unclassified one, with no kind row, must prove it
        // over more stops before it is forced quickly.
        let priorRate = kind.hasEvidence
            ? (kind.cleanWeight + Self.priorStrength * baseRate) / (kind.totalWeight + Self.priorStrength)
            : baseRate
        let alpha = Self.priorStrength * priorRate + signature.cleanWeight
        let beta = Self.priorStrength * (1 - priorRate) + (signature.totalWeight - signature.cleanWeight)
        let mean = alpha / (alpha + beta)
        let deviation = (alpha * beta / ((alpha + beta) * (alpha + beta) * (alpha + beta + 1))).squareRoot()

        // Exit times come only from the strategy's own stops: a stubborn
        // stop's exits happened under a much shorter wait.
        let evidenceStrategy = strategy == .stubbornRunaway ? base ?? strategy : strategy
        let ownSignature = history.signature[evidenceStrategy] ?? .empty
        let latency = ownSignature.hasEvidence ? ownSignature : history.kind[evidenceStrategy] ?? .empty
        let typical = latency.cleanWeight > 0 ? latency.latencyQuantile(0.5) : nil
        let ceiling = max(floorSeconds, 3 * forceKillDelay)
        let grace: TimeInterval
        if strategy == .stubbornRunaway {
            grace = signature.censoredRun >= Self.stubbornRun ? min(floorSeconds, Self.stubbornGrace) : floorSeconds
        } else if latency.cleanWeight > 0, let q90 = latency.latencyQuantile(0.9) {
            // Waits that ran out push q90 up only alongside real exits; a
            // family that never exits gets no longer wait for it.
            grace = min(ceiling, max(floorSeconds, q90 * 1.5))
        } else {
            grace = floorSeconds
        }
        return KillStrategyForecast(
            strategy: strategy,
            pClean: mean,
            pCleanUpper80: mean + Self.z80 * deviation,
            typicalExitSeconds: typical,
            graceSeconds: grace,
            observationCount: signature.observationCount,
            evidenceText: Self.evidenceText(signature: signature, kind: kind, typical: typical, grace: grace, workloadKind: workloadKind)
        )
    }

    private static func evidenceText(
        signature: KillOutcomePosterior,
        kind: KillOutcomePosterior,
        typical: TimeInterval?,
        grace: TimeInterval,
        workloadKind: KillWorkloadKind
    ) -> String {
        let usually = typical.map { ", usually within \(RadarFormat.seconds($0))" } ?? ""
        if signature.observationCount > 0 {
            let count = signature.observationCount
            let clean = signature.cleanCount
            return "Stopped cleanly \(clean) of \(count) time\(count == 1 ? "" : "s")\(clean > 0 ? usually : "")."
        }
        if kind.observationCount > 0 {
            let count = kind.observationCount
            let clean = kind.cleanCount
            let similar = [.general, .versionControl].contains(workloadKind) ? "similar processes" : "similar \(workloadKind.label.lowercased())s"
            return "No history for this one yet; \(similar) stopped cleanly \(clean) of \(count) times\(clean > 0 ? usually : "")."
        }
        return "No history yet; waits up to \(RadarFormat.seconds(grace)) for a clean exit."
    }
}
