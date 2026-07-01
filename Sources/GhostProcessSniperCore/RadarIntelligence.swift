import Foundation

public struct RadarRuleEngine: Sendable {
    public init() {}

    public func suggestions(for family: ProcessFamily, rules: [RadarRule], now: Date) -> [RadarActionSuggestion] {
        rules
            .filter { $0.isEnabled }
            .filter { rule in
                if let expiresAt = rule.expiresAt, expiresAt <= now {
                    return false
                }
                return matches(rule, family: family, now: now)
            }
            .map { suggestion(from: $0, family: family, now: now) }
    }

    public func alertState(for family: ProcessFamily, suggestions: [RadarActionSuggestion], now: Date) -> AlertState {
        if suggestions.contains(where: { $0.type == .ignore }) {
            return AlertState(kind: .ignored, message: "Ignored by rule", since: now)
        }
        if suggestions.contains(where: { $0.type == .snooze }) {
            return AlertState(kind: .snoozed, message: "Snoozed", since: now)
        }
        if family.score.level >= .hot {
            if family.recentIncidentCount > 0 {
                return AlertState(kind: .recurring, message: "\(family.recentIncidentCount + 1)x recurring incident", since: now)
            }
            return AlertState(kind: .new, message: "New \(family.score.level.label.lowercased()) incident", since: now)
        }
        return .normal
    }

    private func matches(_ rule: RadarRule, family: ProcessFamily, now: Date) -> Bool {
        let match = rule.match

        if let signatureID = match.signatureID, signatureID != family.signature.id {
            return false
        }
        if let command = match.commandContains?.lowercased(), !family.root.commandLine.lowercased().contains(command) {
            return false
        }
        if let path = match.pathContains?.lowercased(), !family.root.executablePath.lowercased().contains(path) {
            return false
        }
        guard family.score.level >= match.minimumLevel else {
            return false
        }
        guard family.score.value >= match.minimumScore else {
            return false
        }
        if let leak = match.minimumLeakVelocity, family.trend.memoryVelocityMegabytesPerMinute < leak {
            return false
        }
        if let age = match.minimumAgeMinutes {
            let processAge = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(family.root.identity.startTimeSeconds))) / 60
            if processAge < age {
                return false
            }
        }
        if let minimumIncidentCount = match.minimumIncidentCount, family.recentIncidentCount < minimumIncidentCount {
            return false
        }

        return true
    }

    private func suggestion(from rule: RadarRule, family: ProcessFamily, now: Date) -> RadarActionSuggestion {
        switch rule.action {
        case .notify:
            RadarActionSuggestion(
                type: .notify,
                title: "Notify on \(family.displayName)",
                detail: rule.name,
                ruleID: rule.id,
                createdAt: now
            )
        case .highlight:
            RadarActionSuggestion(
                type: .highlight,
                title: "Keep highlighted",
                detail: rule.name,
                ruleID: rule.id,
                createdAt: now
            )
        case .snooze:
            RadarActionSuggestion(
                type: .snooze,
                title: "Snoozed",
                detail: rule.expiresAt.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? rule.name,
                ruleID: rule.id,
                createdAt: now
            )
        case .ignore:
            RadarActionSuggestion(
                type: .ignore,
                title: "Ignored",
                detail: rule.name,
                ruleID: rule.id,
                createdAt: now
            )
        case .inspect:
            RadarActionSuggestion(
                type: .inspect,
                title: "Inspect trend",
                detail: "Leak \(Int(family.trend.memoryVelocityMegabytesPerMinute.rounded())) MB/min",
                ruleID: rule.id,
                createdAt: now
            )
        case .suggestKill:
            RadarActionSuggestion(
                type: .suggestKill,
                title: family.isKillable ? "Kill tree is available" : "Kill tree is locked",
                detail: family.isKillable ? "\(family.ownedIdentities.count) owned processes can be terminated" : "Protected descendants are present",
                ruleID: rule.id,
                createdAt: now
            )
        case .kill:
            RadarActionSuggestion(
                type: .kill,
                title: "Kill action recorded",
                detail: "Destructive actions still require explicit confirmation.",
                ruleID: rule.id,
                createdAt: now
            )
        }
    }
}

public struct RadarIntelligence: Sendable {
    private let ruleEngine: RadarRuleEngine
    private let forecaster: FamilyRiskForecaster

    public init(
        ruleEngine: RadarRuleEngine = RadarRuleEngine(),
        forecaster: FamilyRiskForecaster = FamilyRiskForecaster()
    ) {
        self.ruleEngine = ruleEngine
        self.forecaster = forecaster
    }

    public func enrich(
        families: [ProcessFamily],
        context: RadarContext,
        settings: ThresholdSettings,
        now: Date
    ) -> [ProcessFamily] {
        families
            .map { enrich(family: $0, context: context, settings: settings, now: now) }
            .sorted(by: sortFamilies)
    }

    public func enrich(
        family: ProcessFamily,
        context: RadarContext,
        settings: ThresholdSettings,
        now: Date
    ) -> ProcessFamily {
        let baseline = context.baselines[family.signature.id]
        let recentIncidents = context.recentIncidentCounts[family.signature.id, default: 0]
        let score = pressureAdjustedScore(
            baselineAwareScore(
                family: family,
                baseline: baseline,
                recentIncidentCount: recentIncidents,
                settings: settings
            ),
            family: family,
            pressure: context.systemPressure
        )
        let staged = family.enriched(
            score: score,
            baseline: baseline,
            recentIncidentCount: recentIncidents
        )
        let suggestions = ruleEngine.suggestions(for: staged, rules: context.rules, now: now)
        let alertState = ruleEngine.alertState(for: staged, suggestions: suggestions, now: now)
        let finalScore = adjustedScoreForSuppression(score, suggestions: suggestions)
        let finalFamily = staged.enriched(
            score: finalScore,
            suggestions: suggestions,
            alertState: alertState
        )
        let forecast = forecaster.forecast(family: finalFamily, settings: settings, now: now)
        let predictiveScore = scoreWithForecast(finalScore, forecast: forecast)
        let predictiveSuggestions = suggestions + suggestion(from: forecast, family: finalFamily)
        return finalFamily.enriched(
            score: predictiveScore,
            suggestions: predictiveSuggestions,
            forecast: forecast
        )
    }

    private func scoreWithForecast(_ score: GhostScore, forecast: RiskForecast) -> GhostScore {
        guard forecast.state >= .warming, forecast.confidence >= 0.42 else {
            return score
        }
        let impact: Double = switch forecast.state {
        case .quiet: 0
        case .warming: 6
        case .stale: 8
        case .leaking: 14
        case .runaway: 20
        case .critical: 24
        }
        let level = max(score.level, forecast.state.level)
        let value = min(100, score.value + impact * forecast.confidence)
        return GhostScore(
            value: value,
            level: level,
            reasons: Array((forecast.whyNow.isEmpty ? score.reasons : [forecast.whyNow] + score.reasons).prefix(6))
        )
    }

    private func suggestion(from forecast: RiskForecast, family: ProcessFamily) -> [RadarActionSuggestion] {
        guard forecast.state >= .warming else {
            return []
        }
        return [
            RadarActionSuggestion(
                type: forecast.recommendedAction.action,
                title: forecast.recommendedAction.title,
                detail: "\(forecast.etaText) - \(forecast.whyNow)",
                ruleID: nil,
                createdAt: forecast.generatedAt
            )
        ]
    }

    private func baselineAwareScore(
        family: ProcessFamily,
        baseline: FamilyBaseline?,
        recentIncidentCount: Int,
        settings: ThresholdSettings
    ) -> GhostScore {
        guard let baseline, baseline.sampleCount >= 3 else {
            return family.score
        }

        let memoryMultiple = baseline.memoryMultiple(for: family.totalPhysicalFootprintBytes)
        let cpuMultiple = baseline.cpuMultiple(for: family.totalCPUPercent)
        let leakRatio = max(0, family.trend.memoryVelocityMegabytesPerMinute) / max(settings.leakVelocityMegabytesPerMinute, 1)
        var reasons = family.score.reasons
        var value = family.score.value

        if memoryMultiple >= 2, family.totalPhysicalFootprintBytes > 256 * 1_048_576 {
            value += min(18, memoryMultiple * 6)
            reasons.insert(String(format: "%.1fx usual memory", memoryMultiple), at: 0)
        } else if memoryMultiple >= 1.45, family.totalPhysicalFootprintBytes > 512 * 1_048_576 {
            value += min(10, memoryMultiple * 4)
            reasons.insert(String(format: "%.1fx baseline memory", memoryMultiple), at: 0)
        }

        if cpuMultiple >= 3, family.totalCPUPercent > 20 {
            value += min(12, cpuMultiple * 3)
            reasons.insert(String(format: "%.1fx usual CPU", cpuMultiple), at: 0)
        }

        if baseline.incidentCount > 0 || recentIncidentCount > 0 {
            value += min(10, Double(baseline.incidentCount + recentIncidentCount) * 2.5)
            reasons.append("recurring family")
        }

        if leakRatio >= 0.5, family.trend.cpuSlopePerMinute > 20 {
            value += 6
            reasons.append("leak and CPU are accelerating together")
        }

        value = min(100, value)
        let level: GhostLevel
        if value >= 84 || memoryMultiple >= 3 || leakRatio >= 1.6 {
            level = .critical
        } else if value >= 60 || memoryMultiple >= 2 || leakRatio >= 1 {
            level = .hot
        } else if value >= 28 || family.score.level >= .watch {
            level = max(family.score.level, .watch)
        } else {
            level = family.score.level
        }

        return GhostScore(
            value: value,
            level: level,
            reasons: Array(reasons.prefix(6))
        )
    }

    // The same footprint matters more when the whole machine is starved:
    // large families get pushed up the queue while host pressure is high.
    private func pressureAdjustedScore(
        _ score: GhostScore,
        family: ProcessFamily,
        pressure: SystemMemoryPressure
    ) -> GhostScore {
        guard pressure.isKnown, pressure.level >= .warning,
              family.totalPhysicalFootprintBytes > 512 * 1_048_576
        else {
            return score
        }
        let boost: Double = pressure.level == .critical ? 12 : 7
        let level: GhostLevel
        if pressure.level == .critical, family.totalPhysicalFootprintBytes > 1_073_741_824 {
            level = max(score.level, .watch)
        } else {
            level = score.level
        }
        return GhostScore(
            value: min(100, score.value + boost),
            level: level,
            reasons: Array((score.reasons + ["system memory pressure is \(pressure.level.label.lowercased())"]).prefix(6))
        )
    }

    private func adjustedScoreForSuppression(_ score: GhostScore, suggestions: [RadarActionSuggestion]) -> GhostScore {
        if suggestions.contains(where: { $0.type == .ignore }) {
            return GhostScore(value: min(score.value, 12), level: .quiet, reasons: ["ignored by rule"])
        }
        if suggestions.contains(where: { $0.type == .snooze }) {
            return GhostScore(value: min(score.value, 24), level: .watch, reasons: ["snoozed"])
        }
        return score
    }

    private func sortFamilies(_ lhs: ProcessFamily, _ rhs: ProcessFamily) -> Bool {
        if lhs.score.level != rhs.score.level {
            return lhs.score.level > rhs.score.level
        }
        if lhs.alertState.kind != rhs.alertState.kind {
            return alertPriority(lhs.alertState.kind) > alertPriority(rhs.alertState.kind)
        }
        if lhs.score.value != rhs.score.value {
            return lhs.score.value > rhs.score.value
        }
        if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
            return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
        }
        return lhs.totalCPUPercent > rhs.totalCPUPercent
    }

    private func alertPriority(_ kind: AlertStateKind) -> Int {
        switch kind {
        case .new: 4
        case .recurring: 3
        case .normal: 2
        case .snoozed: 1
        case .ignored: 0
        }
    }
}
