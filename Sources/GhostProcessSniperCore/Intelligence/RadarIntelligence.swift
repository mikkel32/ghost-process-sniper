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
                if rule.isBuiltIn {
                    switch rule.action {
                    case .notify:
                        guard family.score.heat.shouldNotify else { return false }
                    case .suggestKill, .kill:
                        guard family.score.heat.shouldRaiseLiveAlert else { return false }
                    default:
                        break
                    }
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
        if family.score.heat.shouldRaiseLiveAlert {
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
        if let leak = match.minimumLeakVelocity, family.trend.credibleMemoryVelocity < leak {
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
                detail: "Leak \(Int(family.trend.credibleMemoryVelocity.rounded())) MB/min",
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
        family: ProcessFamily,
        context: RadarContext,
        settings: ThresholdSettings,
        now: Date
    ) -> ProcessFamily {
        guard family.hasRecentMeasurements(at: now) else {
            return family.enriched(
                score: GhostScore(value: 0, level: .quiet, reasons: ["Measurements incomplete or stale"], heat: .quiet),
                suggestions: [],
                alertState: .normal,
                forecast: .quiet,
                lastScoredAt: now
            )
        }
        let candidateBaseline = context.baselines[family.signature.id]
        let baseline = candidateBaseline?.isMeasurementTrusted == true ? candidateBaseline : nil
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
        // Suppression must be known before forecasting, but advisory rules
        // must be evaluated after final Heat is available. A single early
        // rule pass used to miss actions earned by baseline/forecast evidence.
        let preliminaryRules = ruleEngine.suggestions(for: staged, rules: context.rules, now: now)
        let preliminarySuppression = suppressionSuggestions(from: preliminaryRules)
        let suppressedScore = adjustedScoreForSuppression(score, suggestions: preliminarySuppression)
        let workingFamily = staged.enriched(
            score: suppressedScore,
            suggestions: preliminarySuppression
        )
        let forecast = forecaster.forecast(family: workingFamily, settings: settings, now: now)
        let predictiveScore = scoreWithForecast(suppressedScore, forecast: forecast, family: workingFamily)
        let refinedHeat = GhostHeatModel.refined(
            base: predictiveScore.heat,
            family: workingFamily,
            baseline: baseline,
            recentIncidentCount: recentIncidents,
            pressure: context.systemPressure,
            forecast: forecast
        )
        let heatResolvedScore = GhostScore(
            value: predictiveScore.value,
            level: refinedHeat.level,
            reasons: predictiveScore.reasons,
            components: predictiveScore.components,
            heat: refinedHeat
        )
        let heatResolvedFamily = workingFamily.enriched(
            score: heatResolvedScore,
            forecast: forecast
        )
        let finalRules = ruleEngine.suggestions(for: heatResolvedFamily, rules: context.rules, now: now)
        let finalSuppression = suppressionSuggestions(
            from: mergedSuggestions(preliminarySuppression + finalRules)
        )
        let finalSuggestions: [RadarActionSuggestion]
        if finalSuppression.isEmpty {
            finalSuggestions = mergedSuggestions(finalRules + forecastSuggestion(for: heatResolvedFamily))
        } else {
            // Muted families keep their underlying diagnostics, but should not
            // simultaneously tell the user to inspect, notify, or kill.
            finalSuggestions = finalSuppression
        }
        let resolvedScore = adjustedScoreForSuppression(
            heatResolvedScore,
            suggestions: finalSuggestions
        )
        let resolvedFamily = heatResolvedFamily.enriched(
            score: resolvedScore,
            suggestions: finalSuggestions
        )
        let resolvedAlert = ruleEngine.alertState(
            for: resolvedFamily,
            suggestions: finalSuggestions,
            now: now
        )
        return resolvedFamily.enriched(alertState: resolvedAlert)
    }

    private func scoreWithForecast(
        _ score: GhostScore,
        forecast: RiskForecast,
        family: ProcessFamily
    ) -> GhostScore {
        guard forecast.isCredibleEarlyWarning, family.forecastHasUsefulHistory(heat: score.heat) else {
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
        let weightedImpact = impact * forecast.confidence
        let value = min(100, score.value + weightedImpact)
        let forecastComponent = GhostScoreComponent(
            kind: .forecast,
            title: "Forecast: \(forecast.state.label)",
            detail: forecast.whyNow.isEmpty ? forecast.etaText : forecast.whyNow,
            impact: weightedImpact,
            level: forecast.state.level
        )
        return GhostScore(
            value: value,
            level: score.level,
            reasons: Array((forecast.whyNow.isEmpty ? score.reasons : [forecast.whyNow] + score.reasons).prefix(6)),
            components: GhostScoreComponentMath.normalized(score.components + [forecastComponent], to: value),
            heat: score.heat
        )
    }

    private func forecastSuggestion(for family: ProcessFamily) -> [RadarActionSuggestion] {
        guard family.forecastIsCredibleEarlyWarning else {
            return []
        }
        let forecast = family.forecast
        let recommendation = family.presentedForecastRecommendation
        return [
            RadarActionSuggestion(
                type: recommendation.action,
                title: recommendation.title,
                detail: "\(forecast.etaText) - \(forecast.whyNow)",
                ruleID: nil,
                createdAt: forecast.generatedAt
            )
        ]
    }

    private func suppressionSuggestions(
        from suggestions: [RadarActionSuggestion]
    ) -> [RadarActionSuggestion] {
        if let ignore = suggestions.first(where: { $0.type == .ignore }) {
            return [ignore]
        }
        if let snooze = suggestions.first(where: { $0.type == .snooze }) {
            return [snooze]
        }
        return []
    }

    private func mergedSuggestions(
        _ suggestions: [RadarActionSuggestion]
    ) -> [RadarActionSuggestion] {
        var seen = Set<String>()
        return suggestions.filter { suggestion in
            let source = suggestion.ruleID?.uuidString ?? "forecast"
            return seen.insert("\(source)|\(suggestion.type.rawValue)|\(suggestion.title)").inserted
        }
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
        // Unusual means far outside the learned spread as well as well above
        // the mean: a family that swings between idle and indexing is not
        // anomalous at 2x.
        let memoryIsUnusual = baseline.memoryZScore(for: family.totalPhysicalFootprintBytes) >= 3 && memoryMultiple >= 1.3
        let leakRatio = family.trend.credibleMemoryVelocity / max(settings.leakVelocityMegabytesPerMinute, 1)
        var reasons = family.score.reasons
        var value = family.score.value
        var components = family.score.components

        if memoryIsUnusual, memoryMultiple >= 2, family.totalPhysicalFootprintBytes > 256 * 1_048_576 {
            let impact = min(18, memoryMultiple * 6)
            let reason = String(format: "%.1fx usual memory", memoryMultiple)
            value += impact
            reasons.insert(reason, at: 0)
            components.append(GhostScoreComponent(
                kind: .baseline,
                title: reason,
                detail: "Current memory is far above this family's learned normal",
                impact: impact,
                level: memoryMultiple >= 3 ? .critical : .hot
            ))
        } else if memoryIsUnusual, family.totalPhysicalFootprintBytes > 512 * 1_048_576 {
            let impact = min(10, memoryMultiple * 4)
            let reason = String(format: "%.1fx baseline memory", memoryMultiple)
            value += impact
            reasons.insert(reason, at: 0)
            components.append(GhostScoreComponent(
                kind: .baseline,
                title: reason,
                detail: "Current memory is meaningfully above this family's learned normal",
                impact: impact,
                level: .watch
            ))
        }

        if let cpuAnomaly = BaselineCPUAnomaly(baseline: baseline, cpuPercent: family.totalCPUPercent) {
            let impact = min(12, cpuAnomaly.multiple * 3)
            value += impact
            reasons.insert(cpuAnomaly.reason, at: 0)
            components.append(GhostScoreComponent(
                kind: .baseline,
                title: cpuAnomaly.reason,
                detail: "CPU use is well above this family's learned normal",
                impact: impact,
                level: cpuAnomaly.multiple >= 5 ? .hot : .watch
            ))
        }

        if recentIncidentCount > 0 {
            let incidentCount = recentIncidentCount
            let impact = min(10, Double(incidentCount) * 2.5)
            value += impact
            reasons.append("recurring family")
            components.append(GhostScoreComponent(
                kind: .recurrence,
                title: "Recurring family",
                detail: "\(incidentCount) prior incident\(incidentCount == 1 ? "" : "s") raise the chance this is a real repeat",
                impact: impact,
                level: incidentCount >= 3 ? .hot : .watch
            ))
        }

        if leakRatio >= 0.5, family.trend.cpuSlopePerMinute > 20 {
            value += 6
            reasons.append("leak and CPU are accelerating together")
            components.append(GhostScoreComponent(
                kind: .leak,
                title: "Memory and CPU accelerating",
                detail: "Two independent signals are worsening together, increasing confidence",
                impact: 6,
                level: .hot
            ))
        }

        value = min(100, value)
        return GhostScore(
            value: value,
            level: family.score.level,
            reasons: Array(reasons.prefix(6)),
            components: GhostScoreComponentMath.normalized(components, to: value),
            heat: family.score.heat
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
        let reason = "system memory pressure is \(pressure.level.label.lowercased())"
        let pressureComponent = GhostScoreComponent(
            kind: .system,
            title: "Host memory pressure",
            detail: "This footprint matters more while system pressure is \(pressure.level.label.lowercased())",
            impact: boost,
            level: pressure.level.ghostLevel
        )
        let value = min(100, score.value + boost)
        return GhostScore(
            value: value,
            level: score.level,
            reasons: Array((score.reasons + [reason]).prefix(6)),
            components: GhostScoreComponentMath.normalized(score.components + [pressureComponent], to: value),
            heat: score.heat
        )
    }

    private func adjustedScoreForSuppression(_ score: GhostScore, suggestions: [RadarActionSuggestion]) -> GhostScore {
        if suggestions.contains(where: { $0.type == .ignore }) {
            let value = min(score.value, 12)
            return GhostScore(
                value: value,
                level: .quiet,
                reasons: ["ignored by rule"],
                components: [
                    GhostScoreComponent(
                        kind: .rules,
                        title: "Ignored by rule",
                        detail: "The underlying signals remain visible, but alerts are muted by your rule",
                        impact: value,
                        level: .quiet
                    )
                ],
                heat: score.heat.replacing(value: min(score.heat.value, 12), level: .quiet, evidence: ["Muted by ignore rule"])
            )
        }
        if suggestions.contains(where: { $0.type == .snooze }) {
            let value = min(score.value, 24)
            return GhostScore(
                value: value,
                level: .watch,
                reasons: ["snoozed"],
                components: [
                    GhostScoreComponent(
                        kind: .rules,
                        title: "Snoozed",
                        detail: "The family remains visible while alerts are temporarily paused",
                        impact: value,
                        level: .watch
                    )
                ],
                heat: score.heat.replacing(value: min(score.heat.value, 29), level: .watch, evidence: ["Temporarily snoozed"])
            )
        }
        return score
    }
}
