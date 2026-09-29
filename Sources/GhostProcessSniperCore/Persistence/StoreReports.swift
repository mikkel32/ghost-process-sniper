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
            lines.append("  peak memory: \(ByteCountFormatter.memoryString(incident.memoryBytes)), peak cpu: \(RadarFormat.percent(incident.cpuPercent)), peak growth: \(IncidentRowViewModel.growthText(incident.leakVelocityMegabytesPerMinute))")
            lines.append("  first: \(incident.startedAt.formatted()), last: \(incident.lastSeenAt.formatted()), hits: \(incident.occurrenceCount)")
            let reasons = incident.reasons.joined(separator: ", ")
            lines.append("  why: \(reasons)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `home` is the folder written as `~` in the report; tests stand in for it.
    public func exportDiagnosticsReport(settings: ThresholdSettings, home: String = NSHomeDirectory()) throws -> String {
        let health = storeHealth()
        let rules = try loadRules(settings: settings)
        let incidents = try recentIncidents(limit: 12)
        let kills = try recentKillOperations(limit: 5)
        var report = ["Ghost Process Sniper Store Diagnostics", "URL: \(url.path)"]
        report += footprintLines()
        report += [
            "Backlog: \(health.backlogCount), dropped models: \(health.droppedModelCount)",
            "Last flush: \(health.lastFlushDate?.formatted() ?? "none")",
            "Last flush cost: \(Int(health.lastFlushMilliseconds.rounded())) ms",
            "Last context cost: \(Int(health.lastContextMilliseconds.rounded())) ms",
            "Skipped settings writes: \(health.skippedSettingsWriteCount)",
            "Baseline writes: \(health.writeStats.baselineWrites), deferred: \(health.writeStats.baselinesDeferred)",
            "Flushes without a transaction: \(health.writeStats.transactionsSkipped)",
            "Last maintenance: \(health.lastPruneDate?.formatted() ?? "none")",
            "Rules: \(rules.count)",
            "Recent incidents: \(incidents.count)",
            "Recent kills: \(kills.count)",
            "Last kill: \(kills.first?.summary ?? "none")",
            "Error: \(health.errorMessage ?? "none")",
            "Recovered from a corrupt file this session: \(health.recoveredFromCorruption ? "yes" : "no")"
        ]
        // The store sits under the home folder and a kill summary can name
        // paths in it; a pasted report should not carry the account name.
        return DiagnosticsIdentity.redactingHome(in: report.joined(separator: "\n"), home: home)
    }

    /// Schema version, file sizes and row counts: which schema a report came
    /// from, and whether a table is growing. Each figure stands alone, so a
    /// table that cannot be read says n/a instead of failing the report.
    private func footprintLines() -> [String] {
        var version: Int32?
        try? query("PRAGMA user_version") { version = Int32(truncatingIfNeeded: $0.int64(0)) }
        let tables = [("incidents", "incidents"), ("baselines", "baselines"), ("rules", "rules"),
                      ("kill_operations", "kill operations"), ("energy_days", "energy days")]
        let counts = tables.map { table, label in
            var count: Int?
            try? query("SELECT COUNT(*) FROM \(table)") { count = $0.int(0) }
            return "\(label) \(count.map(String.init) ?? "n/a")"
        }
        let main = Self.fileSize(url.path).map(Self.sizeText) ?? "n/a"
        let log = Self.sizeText(Self.fileSize(url.path + "-wal") ?? 0)
        return [
            "Schema version: \(version.map(String.init) ?? "n/a")",
            "Store file: \(main), write-ahead log \(log)",
            "Stored rows: \(counts.joined(separator: ", "))"
        ]
    }

    private static func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    /// Whole KB below a megabyte, so a small store is not rounded to "1 MB".
    private static func sizeText(_ bytes: UInt64) -> String {
        bytes >= 1_048_576 ? RadarFormat.bytes(bytes) : "\((bytes + 1_023) / 1_024) KB"
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
