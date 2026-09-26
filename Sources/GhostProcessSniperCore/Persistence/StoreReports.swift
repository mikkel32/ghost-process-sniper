import Foundation

/// Plain-text exports for the copy buttons and diagnostics.
extension RadarStore {
    public func exportIncidentReport(limit: Int = 20) throws -> String {
        let incidents = try recentIncidents(limit: limit)
        guard !incidents.isEmpty else {
            return "Ghost Process Sniper Incident Report\nNo incidents recorded yet."
        }

        var lines = ["Ghost Process Sniper Incident Report", "Generated \(Date().formatted())", ""]
        for incident in incidents {
            lines.append("\(incident.familyName) - \(incident.level.label) - score \(Int(incident.maxScore.rounded()))")
            lines.append("  memory: \(ByteCountFormatter.memoryString(incident.memoryBytes)), cpu: \(Int(incident.cpuPercent.rounded()))%, leak: \(Int(incident.leakVelocityMegabytesPerMinute.rounded())) MB/min")
            lines.append("  first: \(incident.startedAt.formatted()), last: \(incident.lastSeenAt.formatted()), hits: \(incident.occurrenceCount)")
            let reasons = incident.reasons.joined(separator: ", ")
            lines.append("  why: \(reasons)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func exportDiagnosticsReport(settings: ThresholdSettings) throws -> String {
        let health = storeHealth()
        let rules = try loadRules(settings: settings)
        let incidents = try recentIncidents(limit: 12)
        let forecasts = try recentForecasts(limit: 12)
        let alerts = try recentPredictiveAlerts(limit: 12)
        let kills = try recentKillOperations(limit: 5)
        return [
            "Ghost Process Sniper Store Diagnostics",
            "URL: \(url.path)",
            "Backlog: \(health.backlogCount), actions: \(health.pendingActionCount), dropped models: \(health.droppedModelCount)",
            "Last flush: \(health.lastFlushDate?.formatted() ?? "none")",
            "Last flush cost: \(Int(health.lastFlushMilliseconds.rounded())) ms",
            "Last context cost: \(Int(health.lastContextMilliseconds.rounded())) ms",
            "Skipped settings writes: \(health.skippedSettingsWriteCount)",
            "Forecast writes: \(health.coalescingStats.forecastWrites)/\(health.coalescingStats.forecastCandidates)",
            "Recommendation writes: \(health.coalescingStats.recommendationWrites), skipped: \(health.coalescingStats.recommendationSkippedCount)",
            "Last prune: \(health.lastPruneDate?.formatted() ?? "none")",
            "Rules: \(rules.count)",
            "Recent incidents: \(incidents.count)",
            "Forecasts: \(forecasts.count), predictive alerts: \(alerts.count)",
            "Recent kills: \(kills.count)",
            "Last kill: \(kills.first?.summary ?? "none")",
            "Error: \(health.errorMessage ?? "none")",
            "Recovered from a corrupt file this session: \(health.recoveredFromCorruption ? "yes" : "no")"
        ].joined(separator: "\n")
    }
}

private extension ByteCountFormatter {
    static func memoryString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
