import Darwin
import Foundation

public struct InterventionPolicyEvaluation: Equatable, Sendable {
    public let decisionScore: KillDecisionScore
    public let recommendation: KillStrategyRecommendation
    public let profile: KillStrategyProfile
    /// What this family's past stops predict for the chosen strategy.
    public let forecast: KillStrategyForecast
    public let risk: KillRiskAssessment

    public init(
        decisionScore: KillDecisionScore,
        recommendation: KillStrategyRecommendation,
        profile: KillStrategyProfile,
        forecast: KillStrategyForecast,
        risk: KillRiskAssessment = .none
    ) {
        self.decisionScore = decisionScore
        self.recommendation = recommendation
        self.profile = profile
        self.forecast = forecast
        self.risk = risk
    }
}

public struct InterventionPolicyEngine: Sendable {
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
        let (recommendation, forecast) = strategyRecommendation(
            plan: plan,
            targets: targets,
            locked: locked,
            decisionScore: decisionScore,
            risk: risk,
            model: KillOutcomeModel(history: plan.strategyCalibrations),
            forceKillDelay: forceKillDelay
        )
        return InterventionPolicyEvaluation(
            decisionScore: decisionScore,
            recommendation: recommendation,
            profile: strategyProfile(recommendation: recommendation, grace: forecast.graceSeconds, risk: risk),
            forecast: forecast,
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
            // Weighs on the score but never decides the strategy: a root
            // with root-owned helpers is still the user's to stop.
            let foreign = locked.filter { $0.reason.hasPrefix("Owned by") || $0.reason.hasPrefix("Runs under") }.count
            let count = "\(locked.count) process\(locked.count == 1 ? "" : "es")"
            let detail = foreign == locked.count
                ? "\(count) owned by other users \(locked.count == 1 ? "stays" : "stay") running."
                : "\(count) \(locked.count == 1 ? "stays" : "stay") running; \(foreign) of them belong to other users."
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Protected descendants", detail: detail, weight: -min(16, Double(locked.count) * 4)))
        }
        if !stale.isEmpty || !recycled.isEmpty || !diff.isEmpty {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Tree drift", detail: diff.summary, weight: -min(20, Double(stale.count + recycled.count + diff.reparentedPIDs.count) * 5)))
        }
        if let debugged = targets.first(where: { $0.condition == .traced }) {
            factors.append(KillDecisionFactor(kind: .whyWait, title: "Debugger attached", detail: "A debugger is attached to \(debugged.name): a polite stop only pauses it in the debugger. Stop it from the debugger, or allow force.", weight: -6))
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
            case (false, .respawn, .caution), (false, .respawn, .danger): -12
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
        risk: KillRiskAssessment,
        model: KillOutcomeModel,
        forceKillDelay: TimeInterval
    ) -> (KillStrategyRecommendation, KillStrategyForecast) {
        func forecast(_ strategy: KillStrategy, base: KillStrategy? = nil) -> KillStrategyForecast {
            model.forecast(strategy: strategy, base: base, workloadKind: risk.kind,
                           floorSeconds: Self.defaultGrace(strategy, forceKillDelay: forceKillDelay, risk: risk),
                           forceKillDelay: forceKillDelay)
        }
        // Locked helpers weigh on the score; only a locked root means there
        // is nothing of the user's to stop.
        let rootLocked = locked.contains { $0.identity == plan.rootIdentity }
        if targets.isEmpty || rootLocked || decisionScore.factors.contains(where: { $0.kind == .blocking }) {
            return (KillStrategyRecommendation(
                strategy: .inspectOnly,
                confidence: max(0.72, decisionScore.confidence),
                reasons: decisionScore.whyWait.prefix(2).map(\.detail).ifEmpty(["The root process is locked or protected."]),
                previewText: "Inspect only; no signal should be sent until ownership is clearer."
            ), .none)
        }
        if let quitPID = risk.appQuitPID, targets.contains(where: { $0.pid == quitPID }) {
            return (KillStrategyRecommendation(
                strategy: .quitApp,
                confidence: max(0.82, decisionScore.confidence),
                reasons: ["\(risk.kind.label): quitting lets it save state and close its own helpers."],
                previewText: "Quit like \u{2318}Q, then SIGTERM what the app left behind once it has gone; SIGKILL only for same-identity survivors."
            ), forecast(.quitApp))
        }
        if risk.kind == .dataStore || risk.kind == .containerRuntime {
            return (KillStrategyRecommendation(
                strategy: .carefulShutdown,
                confidence: max(0.8, decisionScore.confidence),
                reasons: ["\(risk.kind.label): needs time to flush data before it exits."],
                previewText: risk.rootShutdownSignal == nil
                    ? "SIGTERM with a long grace period; SIGKILL only if you allow it."
                    : "Asks the database alone to shut down, so it stops its own workers in order; SIGKILL only if you allow it."
            ), forecast(.carefulShutdown))
        }
        var base: KillStrategy = risk.kind == .devServer ? .gentleDevServer : .standard
        var baseForecast = forecast(base)
        // The family's own record may favour the other polite strategy, but
        // never over an app's quit or a database's careful shutdown.
        if [.general, .devServer, .build].contains(risk.kind) {
            let other: KillStrategy = base == .standard ? .gentleDevServer : .standard
            let otherForecast = forecast(other)
            if otherForecast.observationCount >= 3, otherForecast.pClean > baseForecast.pCleanUpper80 {
                base = other
                baseForecast = otherForecast
            }
        }
        if Self.mayForceQuickly(risk), baseForecast.pCleanUpper80 < KillOutcomeModel.stubbornUpperBound {
            return (KillStrategyRecommendation(
                strategy: .stubbornRunaway,
                confidence: max(0.74, decisionScore.confidence),
                reasons: ["It rarely exits on SIGTERM: \(baseForecast.evidenceText)"],
                previewText: "SIGTERM, a short wait, then SIGKILL same-identity survivors."
            ), forecast(.stubbornRunaway, base: base))
        }
        if base == .gentleDevServer {
            return (KillStrategyRecommendation(
                strategy: .gentleDevServer,
                confidence: max(0.76, decisionScore.confidence),
                reasons: ["Looks like a dev server; try SIGINT before SIGTERM."],
                previewText: "SIGINT, verify, then SIGTERM; SIGKILL only for same-identity survivors."
            ), baseForecast)
        }
        return (KillStrategyRecommendation(
            strategy: .standard,
            confidence: max(0.65, decisionScore.confidence),
            reasons: ["Balanced default based on current evidence."],
            previewText: "SIGTERM, verify, then SIGKILL surviving same-identity targets."
        ), baseForecast)
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

    /// - Parameter grace: the first wait, from the outcome forecast.
    private func strategyProfile(
        recommendation: KillStrategyRecommendation,
        grace: TimeInterval,
        risk: KillRiskAssessment
    ) -> KillStrategyProfile {
        // A database or prefork master stops its workers in order; a worker
        // signalled first is a crash to it, or is simply forked again.
        let first: KillSignalReach = risk.shutsDownThroughRoot ? .rootOnly : .tree
        let ask = { (label: String) in first == .rootOnly ? "Ask the main process to stop its workers" : label }
        let force = { (order: Int, wait: TimeInterval) in
            KillSignalPhase(order: order, label: "Force same-identity survivors", action: .signal(SIGKILL), waitAfterSeconds: wait)
        }
        let phases: [KillSignalPhase] = switch recommendation.strategy {
        case .standard: [
            KillSignalPhase(order: 0, label: ask("Ask target to terminate"), action: .signal(SIGTERM), waitAfterSeconds: grace, reach: first),
            force(1, 0.35)
        ]
        case .gentleDevServer: [
            KillSignalPhase(order: 0, label: ask("Interrupt dev server cleanly"), action: .signal(SIGINT), waitAfterSeconds: grace, reach: first),
            KillSignalPhase(order: 1, label: "Terminate survivors", action: .signal(SIGTERM), waitAfterSeconds: 0.45),
            force(2, 0.35)
        ]
        case .stubbornRunaway: [
            KillSignalPhase(order: 0, label: ask("Terminate runaway"), action: .signal(SIGTERM), waitAfterSeconds: grace, reach: first),
            KillSignalPhase(order: 1, label: "Force verified survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.25)
        ]
        // The app itself is never sent SIGTERM: it would close past a save
        // prompt, and its helpers hold what the prompt is about. Only what
        // it left behind once it had gone is; force alone reaches an app
        // that never answers.
        case .quitApp: [
            KillSignalPhase(order: 0, label: "Ask the app to quit, like \u{2318}Q", action: .quitRequest, waitAfterSeconds: grace),
            KillSignalPhase(order: 1, label: "Terminate leftover helpers", action: .signal(SIGTERM), waitAfterSeconds: 1.5),
            force(2, 0.35)
        ]
        // Force still reaches every process: SIGKILL on the postmaster alone
        // leaves backends holding the shared memory the next start needs.
        case .carefulShutdown: if let signal = risk.rootShutdownSignal {
            [
                KillSignalPhase(order: 0, label: "Ask the database to shut down cleanly", action: .signal(signal),
                                waitAfterSeconds: grace, reach: .rootOnly),
                KillSignalPhase(order: 1, label: "Terminate leftover workers", action: .signal(SIGTERM), waitAfterSeconds: 3),
                force(2, 0.5)
            ]
        } else {
            [
                KillSignalPhase(order: 0, label: "Request a clean shutdown", action: .signal(SIGTERM), waitAfterSeconds: grace),
                force(1, 0.5)
            ]
        }
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
