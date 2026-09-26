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
            return unscorable(family: family, context: context, now: now)
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
            pressure: context.systemPressure,
            share: context.pressureShare(for: family)
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
        let forecast = forecaster.forecast(family: workingFamily, settings: settings, now: now,
                                           pressure: context.systemPressure, hostOutlook: context.hostOutlook)
        let predictiveScore = scoreWithForecast(suppressedScore, forecast: forecast, family: workingFamily)
        let refinedHeat = GhostHeatModel.refined(
            base: predictiveScore.heat,
            family: workingFamily,
            baseline: baseline,
            recentIncidentCount: recentIncidents,
            pressure: context.systemPressure,
            pressureShare: context.pressureShare(for: workingFamily),
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
            finalSuggestions = mergedSuggestions(
                finalRules + forecastSuggestion(for: heatResolvedFamily) + duplicateSuggestion(for: heatResolvedFamily, now: now) +
                    zombieSuggestion(for: heatResolvedFamily, now: now) + culpritSuggestion(for: heatResolvedFamily, now: now)
            )
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

    // Without a current reading nothing is scored, but ignore and snooze
    // rules still hold: a muted family must not lose its Muted state.
    private func unscorable(family: ProcessFamily, context: RadarContext, now: Date) -> ProcessFamily {
        let suppression = suppressionSuggestions(from: ruleEngine.suggestions(for: family, rules: context.rules, now: now))
        let blank = GhostScore(value: 0, level: .quiet, reasons: ["Measurements incomplete or stale"], heat: .quiet)
        let waiting = family.enriched(
            score: adjustedScoreForSuppression(blank, suggestions: suppression),
            suggestions: suppression,
            forecast: .quiet,
            lastScoredAt: now
        )
        return waiting.enriched(alertState: ruleEngine.alertState(for: waiting, suggestions: suppression, now: now))
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
            slot: "forecast",
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

    /// One suggestion per duplicated workload, on the copy to keep: stop the
    /// others. The copy with the suggestion is never a target.
    private func duplicateSuggestion(for family: ProcessFamily, now: Date) -> [RadarActionSuggestion] {
        guard let cluster = family.duplicateCluster, cluster.countsAsIndependentCopies,
              let keep = cluster.keepIdentity, family.members.contains(where: { $0.identity == keep })
        else {
            return []
        }
        let redundant = cluster.redundantRootIdentities
        guard !redundant.isEmpty else { return [] }
        let ports = cluster.redundantPorts
        let noun = redundant.count == 1 ? "copy" : "copies"
        let portText = ports.isEmpty ? "" : " (port\(ports.count == 1 ? "" : "s") \(ports.map(String.init).joined(separator: ", ")))"
        return [
            RadarActionSuggestion(
                id: RadarActionSuggestion.stableID(scope: "duplicate|\(cluster.key.id)", type: .suggestKill),
                type: .suggestKill,
                title: "Stop \(redundant.count) older \(noun)\(portText)",
                detail: "\(cluster.independentRootCount) copies of \(cluster.displayName) are running; keeps PID \(keep.pid), \(cluster.keepReason).",
                createdAt: now,
                targetIdentities: redundant
            )
        ]
    }

    /// When one member accounts for most of a leak, stopping it alone (a
    /// language server, a renderer) is often enough and spares the rest of
    /// the tree, through the single-process stop path.
    private func culpritSuggestion(for family: ProcessFamily, now: Date) -> [RadarActionSuggestion] {
        guard let culprit = family.culprit, culprit.identity != family.root.identity, family.hasCredibleLeak,
              family.ownedIdentities.contains(culprit.identity)
        else {
            return []
        }
        return [
            RadarActionSuggestion(
                id: RadarActionSuggestion.stableID(scope: "culprit", type: .suggestKill),
                type: .suggestKill,
                title: "Stop only \(culprit.name) (\(Int((culprit.share * 100).rounded()))% of growth)",
                detail: "It grows \(Int(culprit.slopeMegabytesPerMinute.rounded())) MB/min; the rest of \(family.displayName) keeps running.",
                createdAt: now,
                targetIdentities: [culprit.identity]
            )
        ]
    }

    /// Zombies cannot be killed; only the parent that never reaps them can
    /// be fixed.
    private func zombieSuggestion(for family: ProcessFamily, now: Date) -> [RadarActionSuggestion] {
        guard family.zombieChildCount >= 3 else { return [] }
        return [
            RadarActionSuggestion(
                id: RadarActionSuggestion.stableID(scope: "zombies", type: .inspect),
                type: .inspect,
                title: "Restart \(family.displayName) to clear \(family.zombieChildCount) zombies",
                detail: "Exited children are waiting for their parent to reap them; stopping them does nothing.",
                createdAt: now
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
        // Ids are per (rule or forecast, action), so they must stay unique.
        var seen = Set<UUID>()
        return suggestions.filter { seen.insert($0.id).inserted }
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
            let reason = "\(RadarFormat.fixed1(memoryMultiple))x usual memory"
            value += impact
            reasons.insert(reason, at: 0)
            components.append(GhostScoreComponent(
                slot: "baseline.memory",
                kind: .baseline,
                title: reason,
                detail: "Current memory is far above this family's learned normal",
                impact: impact,
                level: memoryMultiple >= 3 ? .critical : .hot
            ))
        } else if memoryIsUnusual, family.totalPhysicalFootprintBytes > 512 * 1_048_576 {
            let impact = min(10, memoryMultiple * 4)
            let reason = "\(RadarFormat.fixed1(memoryMultiple))x baseline memory"
            value += impact
            reasons.insert(reason, at: 0)
            components.append(GhostScoreComponent(
                slot: "baseline.memory",
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
                slot: "baseline.cpu",
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
                slot: "recurrence",
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
                slot: "acceleration",
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

    // When the whole machine is starved, the families that hold or grow
    // its memory move up the queue, in proportion to their share: an idle
    // bystander of the same size barely moves.
    private func pressureAdjustedScore(
        _ score: GhostScore,
        family: ProcessFamily,
        pressure: SystemMemoryPressure,
        share: PressureShare
    ) -> GhostScore {
        guard pressure.isKnown, pressure.level >= .warning,
              family.totalPhysicalFootprintBytes > 512 * 1_048_576, share.boostScale > 0.05
        else {
            return score
        }
        let boost: Double = (pressure.level == .critical ? 12 : 7) * share.boostScale
        let reason = "system memory pressure is \(pressure.level.label.lowercased()) (\(share.text))"
        let pressureComponent = GhostScoreComponent(
            slot: "pressure",
            kind: .system,
            title: "Host memory pressure",
            detail: "Holds \(share.text) while system pressure is \(pressure.level.label.lowercased())",
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
                        slot: "rules",
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
                        slot: "rules",
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
