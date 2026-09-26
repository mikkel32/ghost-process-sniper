import Foundation
import SQLite3

public enum RadarStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "Unable to open radar store: \(message)"
        case .sqlite(let message):
            "Radar store error: \(message)"
        }
    }
}

public actor RadarStore {
    public static let denseSampleRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let incidentRetention: TimeInterval = 90 * 24 * 60 * 60

    private let url: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let statementCache = SQLiteStatementCache()
    private var pendingModels: [(RadarModel, ThresholdSettings)] = []
    private var pendingActions: [PendingAction] = []
    private var lastFlushDate: Date?
    private var lastPruneDate: Date?
    private var lastFlushMilliseconds = 0.0
    private var lastContextMilliseconds = 0.0
    private var skippedSettingsWriteCount = 0
    private var lastCoalescingStats: StoreCoalescingStats = .empty
    private var lastRecommendationFingerprints: [String: RecommendationFingerprint] = [:]
    private var lastSettingsJSON: String?
    private var lastErrorMessage: String?
    var lastKillOperationSummary: String?
    private var cachedStoredRules: [RadarRule]?
    private var cachedRulesKey: String?
    private var cachedComposedRules: [RadarRule] = []
    private var rulesCacheHitCount = 0
    private var rulesRevision = 0
    private var baselineCache: [String: FamilyBaseline] = [:]
    private var knownMissingBaselines: Set<String> = []
    private var baselineRoundRobinOffset = 0

    public init(url: URL = RadarStore.defaultURL()) throws {
        self.url = url
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        decoder.dateDecodingStrategy = .secondsSince1970

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let handle {
                sqlite3_close(handle)
            }
            throw RadarStoreError.openFailed(message)
        }

        db = handle
        try Self.migrate(handle)
        RadarLogger.store.info("Radar store opened at \(url.path, privacy: .private)")
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Ghost Process Sniper", isDirectory: true)
            .appendingPathComponent("Radar.sqlite")
    }

    public func loadSettings(defaults: ThresholdSettings) throws -> ThresholdSettings {
        guard let json = try stringValue("SELECT json FROM settings WHERE key = 'thresholds' LIMIT 1") else {
            return defaults
        }
        guard let data = json.data(using: .utf8) else {
            return defaults
        }
        lastSettingsJSON = json
        return (try? decoder.decode(ThresholdSettings.self, from: data)) ?? defaults
    }

    public func saveSettings(_ settings: ThresholdSettings) throws {
        let json = try encode(settings)
        if lastSettingsJSON == json {
            skippedSettingsWriteCount += 1
            return
        }
        if let stored = try stringValue("SELECT json FROM settings WHERE key = 'thresholds' LIMIT 1"), stored == json {
            lastSettingsJSON = json
            skippedSettingsWriteCount += 1
            return
        }
        try execute(
            "INSERT INTO settings(key, json, updated_at) VALUES('thresholds', ?, ?) " +
            "ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at",
            .text(json),
            .double(Date().timeIntervalSince1970)
        )
        lastSettingsJSON = json
    }

    public func context(
        for families: [ProcessFamily],
        settings: ThresholdSettings,
        now: Date
    ) throws -> RadarContext {
        let contextStart = Date()
        defer {
            lastContextMilliseconds = Date().timeIntervalSince(contextStart) * 1_000
        }
        try pruneIfNeeded(now: now)
        let signatureIDs = Array(Set(families.map(\.signature.id)))
        let rules = try rulesForContext(settings: settings)
        return RadarContext(
            baselines: try baselines(for: signatureIDs),
            recentIncidentCounts: try recentIncidentCounts(for: signatureIDs, since: now.addingTimeInterval(-RadarStore.incidentRetention)),
            rules: rules
        )
    }

    public func persist(model: RadarModel, settings: ThresholdSettings) throws {
        pendingModels.append((model, settings))
        try flush()
    }

    public func enqueue(model: RadarModel, settings: ThresholdSettings, now: Date = Date()) throws -> StoreHealth {
        pendingModels.append((model, settings))
        if shouldFlush(now: now, settings: settings) {
            try flush(now: now)
        }
        return storeHealth()
    }

    public func flush(now: Date = Date()) throws {
        guard !pendingModels.isEmpty || !pendingActions.isEmpty else {
            return
        }
        let models = pendingModels
        let actions = pendingActions
        pendingModels.removeAll(keepingCapacity: true)
        pendingActions.removeAll(keepingCapacity: true)

        let flushStart = Date()
        do {
            try transaction {
                var latestForecastFamilies: [String: ProcessFamily] = [:]
                var forecastCandidates = 0
                for (model, settings) in models {
                    try saveSettings(settings)
                    try updateBaselines(model.families, at: model.generatedAt)
                    try upsertIncidents(model.families, at: model.generatedAt)
                    for family in model.families.prefix(64) {
                        forecastCandidates += 1
                        latestForecastFamilies[family.signature.id] = family
                    }
                }
                if !latestForecastFamilies.isEmpty {
                    try persistForecasts(
                        Array(latestForecastFamilies.values),
                        at: models.last?.0.generatedAt ?? now,
                        forecastCandidates: forecastCandidates
                    )
                }
                for action in actions {
                    try writeAction(action)
                }
            }
            lastFlushDate = now
            lastFlushMilliseconds = Date().timeIntervalSince(flushStart) * 1_000
            lastErrorMessage = nil
        } catch {
            pendingModels.insert(contentsOf: models, at: 0)
            pendingActions.insert(contentsOf: actions, at: 0)
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func storeHealth() -> StoreHealth {
        StoreHealth(
            backlogCount: pendingModels.count,
            pendingActionCount: pendingActions.count,
            lastFlushDate: lastFlushDate,
            lastPruneDate: lastPruneDate,
            lastFlushMilliseconds: lastFlushMilliseconds,
            lastContextMilliseconds: lastContextMilliseconds,
            skippedSettingsWriteCount: skippedSettingsWriteCount,
            coalescingStats: lastCoalescingStats,
            rulesCacheHitCount: rulesCacheHitCount,
            errorMessage: lastErrorMessage,
            lastKillOperationSummary: lastKillOperationSummary
        )
    }

    public func recentIncidents(limit: Int = 80) throws -> [RadarIncident] {
        let statement = try prepare(RadarStoreQueries.recentIncidents)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var incidents: [RadarIncident] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            incidents.append(incident(from: statement))
        }
        return incidents
    }

    public func recentIncidents(filter: RadarIncidentFilter, limit: Int = 80) throws -> [RadarIncident] {
        let incidents = try recentIncidents(limit: max(limit * 2, limit))
        return IncidentQuery(filter: filter, limit: limit).apply(to: incidents)
    }

    public func recentForecasts(limit: Int = 80) throws -> [ForecastStoreSnapshot] {
        let statement = try prepare(RadarStoreQueries.recentForecasts)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var forecasts: [ForecastStoreSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            forecasts.append(forecastSnapshot(from: statement))
        }
        return forecasts
    }

    public func recentPredictiveAlerts(limit: Int = 80) throws -> [PredictiveAlert] {
        let statement = try prepare(RadarStoreQueries.recentPredictiveAlerts)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var alerts: [PredictiveAlert] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            alerts.append(predictiveAlert(from: statement))
        }
        return alerts
    }

    public func loadRules(includeBuiltIns: Bool = true, settings: ThresholdSettings = .aggressive) throws -> [RadarRule] {
        if includeBuiltIns {
            return try rulesForContext(settings: settings)
        }
        if let cachedStoredRules {
            rulesCacheHitCount += 1
            return cachedStoredRules
        }
        let statement = try prepare("SELECT json FROM rules ORDER BY created_at DESC")
        defer { sqlite3_finalize(statement) }

        var rules: [RadarRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let json = columnString(statement, 0),
                  let data = json.data(using: .utf8),
                  let rule = try? decoder.decode(RadarRule.self, from: data)
            else {
                continue
            }
            if rule.expiresAt.map({ $0 <= Date() }) == true {
                continue
            }
            rules.append(rule)
        }

        cachedStoredRules = rules
        return rules
    }

    private func rulesForContext(settings: ThresholdSettings) throws -> [RadarRule] {
        let key = "\(rulesRevision)|\(settings.memoryBytes)|\(Int(settings.cpuPercent.rounded()))|\(Int(settings.leakVelocityMegabytesPerMinute.rounded()))|\(settings.radarMode.rawValue)"
        if cachedRulesKey == key {
            rulesCacheHitCount += 1
            return cachedComposedRules
        }
        let stored = try loadRules(includeBuiltIns: false, settings: settings)
        let composed = RadarRule.builtIns(settings: settings) + stored
        cachedRulesKey = key
        cachedComposedRules = composed
        return composed
    }

    private func invalidateRulesCache() {
        rulesRevision += 1
        cachedStoredRules = nil
        cachedRulesKey = nil
        cachedComposedRules.removeAll(keepingCapacity: true)
    }

    public func saveRule(_ rule: RadarRule) throws {
        let json = try encode(rule)
        try execute(
            "INSERT INTO rules(id, json, created_at) VALUES(?, ?, ?) " +
            "ON CONFLICT(id) DO UPDATE SET json = excluded.json",
            .text(rule.id.uuidString),
            .text(json),
            .double(rule.createdAt.timeIntervalSince1970)
        )
        invalidateRulesCache()
        RadarLogger.rules.info("Saved rule \(rule.name, privacy: .public)")
    }

    public func deleteRule(id: UUID) throws {
        try execute("DELETE FROM rules WHERE id = ?", .text(id.uuidString))
        invalidateRulesCache()
    }

    public func setRuleEnabled(id: UUID, isEnabled: Bool) throws {
        var stored = try loadRules(includeBuiltIns: false)
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            return
        }
        stored[index].isEnabled = isEnabled
        try saveRule(stored[index])
    }

    public func recordAction(
        kind: RadarActionType,
        family: ProcessFamily?,
        summary: String,
        at date: Date = Date()
    ) throws {
        pendingActions.append(
            PendingAction(
                id: UUID(),
                signatureID: family?.signature.id,
                kind: kind,
                summary: summary,
                createdAt: date
            )
        )
        if pendingActions.count >= 8 {
            try flush(now: date)
        }
    }

    public func actionSummaries(kind: RadarActionType, limit: Int = 20) throws -> [String] {
        let statement = try prepare(
            "SELECT summary FROM actions WHERE kind = ? ORDER BY created_at DESC LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(kind.rawValue), to: statement, index: 1)
        bind(.int64(Int64(limit)), to: statement, index: 2)

        var summaries: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let summary = columnString(statement, 0) {
                summaries.append(summary)
            }
        }
        return summaries
    }

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
            "Backlog: \(health.backlogCount), actions: \(health.pendingActionCount)",
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
            "Error: \(health.errorMessage ?? "none")"
        ].joined(separator: "\n")
    }

    private static func migrate(_ handle: OpaquePointer?) throws {
        for sql in RadarStoreSchema.migrationStatements {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "unknown sqlite error"
                if let message {
                    sqlite3_free(message)
                }
                throw RadarStoreError.sqlite(text)
            }
        }
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(baselines)", -1, &columns, nil) == SQLITE_OK else {
            throw RadarStoreError.sqlite("Cannot inspect baseline schema")
        }
        var hasMeasurementVersion = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1), String(cString: name) == "measurement_version" {
                hasMeasurementVersion = true
            }
        }
        sqlite3_finalize(columns)
        if !hasMeasurementVersion {
            let sql = "ALTER TABLE baselines ADD COLUMN measurement_version INTEGER NOT NULL DEFAULT 0"
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw RadarStoreError.sqlite("Cannot upgrade baseline measurement provenance")
            }
        }
        try migrateKillLearning(handle)
    }

    public func pruneIfNeeded(now: Date) throws {
        if let lastPruneDate, now.timeIntervalSince(lastPruneDate) < 24 * 60 * 60 {
            return
        }
        try execute("DELETE FROM samples WHERE sampled_at < ?", .double(now.addingTimeInterval(-RadarStore.denseSampleRetention).timeIntervalSince1970))
        try execute("DELETE FROM incidents WHERE resolved_at IS NOT NULL AND resolved_at < ?", .double(now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970))
        try execute("DELETE FROM actions WHERE created_at < ?", .double(now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970))
        try pruneKillOperations(before: now.addingTimeInterval(-RadarStore.incidentRetention))
        try execute("DELETE FROM predictive_alerts WHERE created_at < ?", .double(now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970))
        try execute("DELETE FROM recommendation_history WHERE created_at < ?", .double(now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970))
        try execute("DELETE FROM rules WHERE json LIKE '%\"expiresAt\"%' AND created_at < ?", .double(now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970))
        lastPruneDate = now
    }

    private func baselines(for signatureIDs: [String]) throws -> [String: FamilyBaseline] {
        guard !signatureIDs.isEmpty else {
            return [:]
        }

        let uniqueIDs = Array(Set(signatureIDs))
        var result: [String: FamilyBaseline] = [:]
        result.reserveCapacity(uniqueIDs.count)
        var missing: [String] = []
        missing.reserveCapacity(uniqueIDs.count)

        for signatureID in uniqueIDs {
            if let cached = baselineCache[signatureID] {
                result[signatureID] = cached
            } else if !knownMissingBaselines.contains(signatureID) {
                missing.append(signatureID)
            }
        }

        // Keep the cold-load query comfortably below SQLite variable limits
        // and avoid re-reading known baselines on every refresh.
        let chunkSize = 400
        var start = 0
        while start < missing.count {
            let end = min(start + chunkSize, missing.count)
            let chunk = Array(missing[start..<end])
            let statement = try prepare(
                """
                SELECT signature_id, display_name, canonical_path, command_fingerprint, sample_count,
                       mean_memory_bytes, peak_memory_bytes, mean_cpu_percent, peak_cpu_percent,
                       mean_leak_velocity, incident_count, first_seen_at, last_seen_at, measurement_version
                FROM baselines
                WHERE signature_id IN (\(placeholders(count: chunk.count)))
                """
            )
            for (offset, signatureID) in chunk.enumerated() {
                bind(.text(signatureID), to: statement, index: Int32(offset + 1))
            }

            var found = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                let baseline = baseline(from: statement)
                let signatureID = baseline.signature.id
                baselineCache[signatureID] = baseline
                knownMissingBaselines.remove(signatureID)
                result[signatureID] = baseline
                found.insert(signatureID)
            }
            sqlite3_finalize(statement)

            for signatureID in chunk where !found.contains(signatureID) {
                knownMissingBaselines.insert(signatureID)
            }
            start = end
        }
        return result
    }

    private func recentIncidentCounts(for signatureIDs: [String], since: Date) throws -> [String: Int] {
        guard !signatureIDs.isEmpty else {
            return [:]
        }

        let uniqueIDs = Array(Set(signatureIDs))
        var counts: [String: Int] = [:]
        let chunkSize = 400
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + chunkSize, uniqueIDs.count)
            let chunk = Array(uniqueIDs[start..<end])
            let statement = try prepare(
                """
                SELECT signature_id, COUNT(*)
                FROM incidents
                WHERE signature_id IN (\(placeholders(count: chunk.count))) AND started_at >= ?
                GROUP BY signature_id
                """
            )
            for (offset, signatureID) in chunk.enumerated() {
                bind(.text(signatureID), to: statement, index: Int32(offset + 1))
            }
            bind(.double(since.timeIntervalSince1970), to: statement, index: Int32(chunk.count + 1))

            while sqlite3_step(statement) == SQLITE_ROW {
                if let signatureID = columnString(statement, 0) {
                    counts[signatureID] = Int(sqlite3_column_int(statement, 1))
                }
            }
            sqlite3_finalize(statement)
            start = end
        }
        return counts
    }

    private func updateBaselines(_ families: [ProcessFamily], at date: Date) throws {
        let candidates = baselineUpdateCandidates(from: families)
        let existing = try baselines(for: candidates.map(\.signature.id))
        for family in candidates {
            let baseline = updatedBaseline(
                family: family,
                existing: existing[family.signature.id],
                now: date
            )
            try upsert(baseline)
        }
    }

    private func baselineUpdateCandidates(from families: [ProcessFamily]) -> [ProcessFamily] {
        let maximumUpdates = 512
        var seenSignatures = Set<String>()
        let uniqueFamilies = families.filter { family in
            seenSignatures.insert(family.signature.id).inserted
        }
        guard uniqueFamilies.count > maximumUpdates else {
            return uniqueFamilies
        }

        // Always spend part of the budget on families that can affect the
        // current diagnosis. Quiet families still learn through a rotating
        // slice, so a huge process table cannot turn into thousands of SQLite
        // upserts every flush.
        let priorityLimit = maximumUpdates / 2
        var selected: [ProcessFamily] = []
        selected.reserveCapacity(maximumUpdates)
        var selectedIDs = Set<String>()

        for family in uniqueFamilies where
            family.score.level >= .watch ||
            family.forecastIsCredibleEarlyWarning ||
            family.recentIncidentCount > 0 {
            guard selected.count < priorityLimit else { break }
            selected.append(family)
            selectedIDs.insert(family.signature.id)
        }

        let quiet = uniqueFamilies.filter { !selectedIDs.contains($0.signature.id) }
        guard !quiet.isEmpty, selected.count < maximumUpdates else {
            return selected
        }

        let start = baselineRoundRobinOffset % quiet.count
        let remaining = maximumUpdates - selected.count
        for offset in 0..<min(remaining, quiet.count) {
            selected.append(quiet[(start + offset) % quiet.count])
        }
        baselineRoundRobinOffset = (start + remaining) % quiet.count
        return selected
    }

    private func updatedBaseline(
        family: ProcessFamily,
        existing: FamilyBaseline?,
        now: Date
    ) -> FamilyBaseline {
        FamilyBaselineLearner().updated(existing: existing, family: family, now: now)
    }

    private func upsert(_ baseline: FamilyBaseline) throws {
        try execute(
            """
            INSERT INTO baselines(signature_id, display_name, canonical_path, command_fingerprint, sample_count,
                                  mean_memory_bytes, peak_memory_bytes, mean_cpu_percent, peak_cpu_percent,
                                  mean_leak_velocity, incident_count, first_seen_at, last_seen_at, measurement_version)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(signature_id) DO UPDATE SET
                display_name = excluded.display_name,
                canonical_path = excluded.canonical_path,
                command_fingerprint = excluded.command_fingerprint,
                sample_count = excluded.sample_count,
                mean_memory_bytes = excluded.mean_memory_bytes,
                peak_memory_bytes = excluded.peak_memory_bytes,
                mean_cpu_percent = excluded.mean_cpu_percent,
                peak_cpu_percent = excluded.peak_cpu_percent,
                mean_leak_velocity = excluded.mean_leak_velocity,
                incident_count = excluded.incident_count,
                last_seen_at = excluded.last_seen_at,
                first_seen_at = excluded.first_seen_at,
                measurement_version = excluded.measurement_version
            """,
            .text(baseline.signature.id),
            .text(baseline.signature.displayName),
            .text(baseline.signature.canonicalPath),
            .text(baseline.signature.commandFingerprint),
            .int64(Int64(baseline.sampleCount)),
            .double(baseline.meanMemoryBytes),
            .int64(Int64(clamping: baseline.peakMemoryBytes)),
            .double(baseline.meanCPUPercent),
            .double(baseline.peakCPUPercent),
            .double(baseline.meanLeakVelocityMegabytesPerMinute),
            .int64(Int64(baseline.incidentCount)),
            .double(baseline.firstSeenAt.timeIntervalSince1970),
            .double(baseline.lastSeenAt.timeIntervalSince1970),
            .int64(Int64(baseline.measurementVersion ?? 0))
        )
        baselineCache[baseline.signature.id] = baseline
        knownMissingBaselines.remove(baseline.signature.id)
    }

    private func upsertIncidents(_ families: [ProcessFamily], at date: Date) throws {
        let activeFamilies = families.filter {
            $0.score.heat.shouldRecordIncident &&
                $0.alertState.kind != .ignored &&
                $0.alertState.kind != .snoozed
        }
        let activeIDs = Set(activeFamilies.map(\.signature.id))

        for family in activeFamilies {
            if let existingID = try activeIncidentID(for: family.signature.id) {
                try execute(
                    """
                    UPDATE incidents
                    SET level = ?, max_score = MAX(max_score, ?), memory_bytes = ?, cpu_percent = ?,
                        leak_velocity = ?, reasons_json = ?, last_seen_at = ?
                    WHERE id = ?
                    """,
                    .text(family.score.level.label),
                    .double(family.score.value),
                    .int64(Int64(clamping: family.totalPhysicalFootprintBytes)),
                    .double(family.totalCPUPercent),
                    .double(family.trend.memoryVelocityMegabytesPerMinute),
                    .text(try encode(family.score.reasons)),
                    .double(date.timeIntervalSince1970),
                    .text(existingID.uuidString)
                )
            } else {
                try execute(
                    """
                    INSERT INTO incidents(id, signature_id, display_name, canonical_path, command_fingerprint, family_name,
                                          level, max_score, memory_bytes, cpu_percent, leak_velocity, reasons_json,
                                          started_at, last_seen_at, resolved_at, occurrence_count)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 1)
                    """,
                    .text(UUID().uuidString),
                    .text(family.signature.id),
                    .text(family.signature.displayName),
                    .text(family.signature.canonicalPath),
                    .text(family.signature.commandFingerprint),
                    .text(family.displayName),
                    .text(family.score.level.label),
                    .double(family.score.value),
                    .int64(Int64(clamping: family.totalPhysicalFootprintBytes)),
                    .double(family.totalCPUPercent),
                    .double(family.trend.memoryVelocityMegabytesPerMinute),
                    .text(try encode(family.score.reasons)),
                    .double(date.timeIntervalSince1970),
                    .double(date.timeIntervalSince1970)
                )
            }
        }

        let statement = try prepare("SELECT signature_id FROM incidents WHERE resolved_at IS NULL")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let signatureID = columnString(statement, 0), !activeIDs.contains(signatureID) else {
                continue
            }
            try execute(
                "UPDATE incidents SET resolved_at = ?, last_seen_at = ? WHERE signature_id = ? AND resolved_at IS NULL",
                .double(date.timeIntervalSince1970),
                .double(date.timeIntervalSince1970),
                .text(signatureID)
            )
        }
    }

    private func persistForecasts(_ families: [ProcessFamily], at date: Date, forecastCandidates: Int) throws {
        var recommendationWrites = 0
        var recommendationSkips = 0
        for family in families.prefix(64) {
            let forecast = family.forecast
            let generatedAt = forecast.generatedAt.timeIntervalSince1970 > 0 ? forecast.generatedAt : date
            try execute(
                """
                INSERT INTO forecasts(signature_id, state, confidence, eta_seconds, why_now,
                                      projected_memory_bytes, projected_cpu_percent, recurrence_risk,
                                      stale_likelihood, generated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(signature_id) DO UPDATE SET
                    state = excluded.state,
                    confidence = excluded.confidence,
                    eta_seconds = excluded.eta_seconds,
                    why_now = excluded.why_now,
                    projected_memory_bytes = excluded.projected_memory_bytes,
                    projected_cpu_percent = excluded.projected_cpu_percent,
                    recurrence_risk = excluded.recurrence_risk,
                    stale_likelihood = excluded.stale_likelihood,
                    generated_at = excluded.generated_at
                """,
                .text(family.signature.id),
                .text(forecast.state.rawValue),
                .double(forecast.confidence),
                forecast.etaSeconds.map { .double($0) } ?? .null,
                .text(forecast.whyNow),
                .int64(Int64(clamping: forecast.projectedMemoryBytes)),
                .double(forecast.projectedCPUPercent),
                .double(forecast.recurrenceRisk),
                .double(forecast.staleLikelihood),
                .double(generatedAt.timeIntervalSince1970)
            )

            guard forecast.state >= .warming, forecast.confidence >= 0.42 else {
                continue
            }
            guard shouldWriteRecommendation(for: family, at: generatedAt) else {
                recommendationSkips += 1
                continue
            }
            try execute(
                """
                INSERT INTO recommendation_history(id, signature_id, title, detail, action, confidence, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
                .text(UUID().uuidString),
                .text(family.signature.id),
                .text(forecast.recommendedAction.title),
                .text(forecast.recommendedAction.detail),
                .text(forecast.recommendedAction.action.rawValue),
                .double(forecast.recommendedAction.confidence),
                .double(generatedAt.timeIntervalSince1970)
            )
            recommendationWrites += 1

            guard forecast.state >= .leaking else {
                continue
            }
            try execute(
                """
                INSERT INTO predictive_alerts(id, signature_id, state, message, created_at)
                VALUES(?, ?, ?, ?, ?)
                """,
                .text(UUID().uuidString),
                .text(family.signature.id),
                .text(forecast.state.rawValue),
                .text(forecast.whyNow),
                .double(generatedAt.timeIntervalSince1970)
            )
        }
        lastCoalescingStats = StoreCoalescingStats(
            forecastCandidates: forecastCandidates,
            forecastWrites: min(families.count, 64),
            recommendationWrites: recommendationWrites,
            recommendationSkippedCount: recommendationSkips
        )
    }

    private func shouldWriteRecommendation(for family: ProcessFamily, at date: Date) -> Bool {
        let fingerprint = RecommendationFingerprint(family: family, date: date)
        defer {
            lastRecommendationFingerprints[family.signature.id] = fingerprint
        }
        guard let previous = lastRecommendationFingerprints[family.signature.id] else {
            return true
        }
        if previous.state != fingerprint.state ||
            previous.title != fingerprint.title ||
            previous.detail != fingerprint.detail ||
            previous.action != fingerprint.action {
            return true
        }
        return date.timeIntervalSince(previous.createdAt) >= 30 * 60
    }

    private func shouldFlush(now: Date, settings: ThresholdSettings) -> Bool {
        if pendingModels.count >= 3 || pendingActions.count >= 8 {
            return true
        }
        guard let lastFlushDate else {
            return true
        }
        return now.timeIntervalSince(lastFlushDate) >= RadarPerformanceBudget.budget(for: settings.performanceMode).storeFlushInterval
    }

    private func writeAction(_ action: PendingAction) throws {
        try execute(
            "INSERT INTO actions(id, signature_id, kind, summary, created_at) VALUES(?, ?, ?, ?, ?)",
            .text(action.id.uuidString),
            action.signatureID.map { .text($0) } ?? .null,
            .text(action.kind.rawValue),
            .text(action.summary),
            .double(action.createdAt.timeIntervalSince1970)
        )
    }

    private func activeIncidentID(for signatureID: String) throws -> UUID? {
        let statement = try prepare("SELECT id FROM incidents WHERE signature_id = ? AND resolved_at IS NULL LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(.text(signatureID), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = columnString(statement, 0)
        else {
            return nil
        }
        return UUID(uuidString: text)
    }

    private func baseline(from statement: OpaquePointer?) -> FamilyBaseline {
        let signature = ProcessSignature(
            id: columnString(statement, 0) ?? "",
            displayName: columnString(statement, 1) ?? "Process",
            canonicalPath: columnString(statement, 2) ?? "",
            commandFingerprint: columnString(statement, 3) ?? ""
        )
        return FamilyBaseline(
            signature: signature,
            sampleCount: Int(sqlite3_column_int64(statement, 4)),
            meanMemoryBytes: sqlite3_column_double(statement, 5),
            peakMemoryBytes: UInt64(max(0, sqlite3_column_int64(statement, 6))),
            meanCPUPercent: sqlite3_column_double(statement, 7),
            peakCPUPercent: sqlite3_column_double(statement, 8),
            meanLeakVelocityMegabytesPerMinute: sqlite3_column_double(statement, 9),
            incidentCount: Int(sqlite3_column_int64(statement, 10)),
            firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
            lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            measurementVersion: Int(sqlite3_column_int64(statement, 13))
        )
    }

    private func incident(from statement: OpaquePointer?) -> RadarIncident {
        let signature = ProcessSignature(
            id: columnString(statement, 1) ?? "",
            displayName: columnString(statement, 2) ?? "Process",
            canonicalPath: columnString(statement, 3) ?? "",
            commandFingerprint: columnString(statement, 4) ?? ""
        )
        let reasons: [String] = columnString(statement, 11)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        let resolved = sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
        return RadarIncident(
            id: UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(),
            signature: signature,
            familyName: columnString(statement, 5) ?? signature.displayName,
            level: GhostLevel.allCases.first { $0.label == columnString(statement, 6) } ?? .watch,
            maxScore: sqlite3_column_double(statement, 7),
            memoryBytes: UInt64(max(0, sqlite3_column_int64(statement, 8))),
            cpuPercent: sqlite3_column_double(statement, 9),
            leakVelocityMegabytesPerMinute: sqlite3_column_double(statement, 10),
            reasons: reasons,
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            resolvedAt: resolved,
            occurrenceCount: Int(sqlite3_column_int64(statement, 15))
        )
    }

    private func forecastSnapshot(from statement: OpaquePointer?) -> ForecastStoreSnapshot {
        let eta: TimeInterval? = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
        return ForecastStoreSnapshot(
            signatureID: columnString(statement, 0) ?? "",
            state: ForecastState(rawValue: columnString(statement, 1) ?? "") ?? .quiet,
            confidence: sqlite3_column_double(statement, 2),
            etaSeconds: eta,
            whyNow: columnString(statement, 4) ?? "",
            generatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private func predictiveAlert(from statement: OpaquePointer?) -> PredictiveAlert {
        PredictiveAlert(
            id: UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(),
            signatureID: columnString(statement, 1) ?? "",
            state: ForecastState(rawValue: columnString(statement, 2) ?? "") ?? .warming,
            message: columnString(statement, 3) ?? "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }

    enum BindingValue {
        case text(String)
        case double(Double)
        case int64(Int64)
        case null
    }

    private struct PendingAction {
        var id: UUID
        var signatureID: String?
        var kind: RadarActionType
        var summary: String
        var createdAt: Date
    }

    private struct RecommendationFingerprint {
        var state: ForecastState
        var title: String
        var detail: String
        var action: RadarActionType
        var createdAt: Date

        init(family: ProcessFamily, date: Date) {
            state = family.forecast.state
            title = family.forecast.recommendedAction.title
            detail = family.forecast.recommendedAction.detail
            action = family.forecast.recommendedAction.action
            createdAt = date
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ values: BindingValue...) throws {
        let statement = try cachedPrepare(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            bind(value, to: statement, index: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func cachedPrepare(_ sql: String) throws -> OpaquePointer {
        if let statement = statementCache.statement(for: sql) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        statementCache.store(statement, for: sql)
        return statement
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        return statement
    }

    func bind(_ value: BindingValue, to statement: OpaquePointer?, index: Int32) {
        switch value {
        case .text(let text):
            sqlite3_bind_text(statement, index, text, -1, transient)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        case .int64(let value):
            sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }

    private func stringValue(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return columnString(statement, 0)
    }

    func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func sqliteError() -> RadarStoreError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        return .sqlite(message)
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

private final class SQLiteStatementCache: @unchecked Sendable {
    private var statements: [String: OpaquePointer] = [:]

    func statement(for sql: String) -> OpaquePointer? {
        statements[sql]
    }

    func store(_ statement: OpaquePointer, for sql: String) {
        statements[sql] = statement
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
    }
}
