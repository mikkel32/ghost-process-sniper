import Foundation

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

/// Settings, rules, context and write batching. Tables with their own logic
/// live in collaborators that share this actor's connection and never escape it.
///
/// The database opens on first use, on this actor, so creating the store on
/// the main actor at launch does no SQLite work there.
public actor RadarStore {
    public static let denseSampleRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let incidentRetention: TimeInterval = 90 * 24 * 60 * 60
    static let openRetryInterval: TimeInterval = 30

    typealias BindingValue = SQLiteValue

    let url: URL
    private let db: SQLiteDatabase
    private let codec = StoreCodec()
    private let baselineBook: BaselineBook
    private let incidentLedger: IncidentLedger
    private let forecastLedger: ForecastLedger
    private let clock: @Sendable () -> Date
    private var openFailure: (date: Date, error: any Error)?
    private var recoveredFromCorruption = false
    private var pendingModels: [(RadarModel, ThresholdSettings)] = []
    private var pendingActions: [PendingAction] = []
    private var lastFlushDate: Date?
    private var lastPruneDate: Date?
    private var lastFlushMilliseconds = 0.0
    private var lastContextMilliseconds = 0.0
    private var skippedSettingsWriteCount = 0
    private var lastSettingsJSON: String?
    private var lastErrorMessage: String?
    var lastKillOperationSummary: String?
    private var cachedStoredRules: [RadarRule]?
    private var cachedRulesKey: String?
    private var cachedComposedRules: [RadarRule] = []
    private var rulesCacheHitCount = 0
    private var rulesRevision = 0

    public init(url: URL = RadarStore.defaultURL()) {
        self.init(url: url, busyTimeoutMilliseconds: 2_000, clock: { Date() })
    }

    init(url: URL, busyTimeoutMilliseconds: Int32, clock: @escaping @Sendable () -> Date) {
        let database = SQLiteDatabase(url: url, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        self.url = url
        self.clock = clock
        db = database
        baselineBook = BaselineBook(db: database)
        incidentLedger = IncidentLedger(db: database, codec: codec)
        forecastLedger = ForecastLedger(db: database)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Ghost Process Sniper", isDirectory: true)
            .appendingPathComponent("Radar.sqlite")
    }

    public func loadSettings(defaults: ThresholdSettings) throws -> ThresholdSettings {
        let db = try ensureOpen()
        guard let json = try db.string("SELECT json FROM settings WHERE key = 'thresholds' LIMIT 1") else {
            return defaults
        }
        lastSettingsJSON = json
        return codec.decode(ThresholdSettings.self, from: json) ?? defaults
    }

    public func saveSettings(_ settings: ThresholdSettings) throws {
        let db = try ensureOpen()
        let json = try codec.encode(settings)
        if lastSettingsJSON == json {
            skippedSettingsWriteCount += 1
            return
        }
        if let stored = try db.string("SELECT json FROM settings WHERE key = 'thresholds' LIMIT 1"), stored == json {
            lastSettingsJSON = json
            skippedSettingsWriteCount += 1
            return
        }
        try db.execute(
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
        try ensureOpen()
        try pruneIfNeeded(now: now)
        let signatureIDs = Array(Set(families.map(\.signature.id)))
        let rules = try rulesForContext(settings: settings)
        return RadarContext(
            baselines: try baselineBook.baselines(for: signatureIDs),
            recentIncidentCounts: try incidentLedger.recentCounts(
                for: signatureIDs,
                since: now.addingTimeInterval(-RadarStore.incidentRetention)
            ),
            rules: rules
        )
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
            try ensureOpen().transaction {
                var latestForecastFamilies: [String: ProcessFamily] = [:]
                var forecastCandidates = 0
                for (model, settings) in models {
                    try saveSettings(settings)
                    try baselineBook.learn(from: model.families, at: model.generatedAt)
                    try incidentLedger.record(model.families, at: model.generatedAt)
                    for family in model.families.prefix(64) {
                        forecastCandidates += 1
                        latestForecastFamilies[family.signature.id] = family
                    }
                }
                if !latestForecastFamilies.isEmpty {
                    try forecastLedger.persist(
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
            coalescingStats: forecastLedger.lastStats,
            rulesCacheHitCount: rulesCacheHitCount,
            errorMessage: lastErrorMessage,
            lastKillOperationSummary: lastKillOperationSummary,
            recoveredFromCorruption: recoveredFromCorruption
        )
    }

    public func recentIncidents(limit: Int = 80) throws -> [RadarIncident] {
        try ensureOpen()
        return try incidentLedger.recent(limit: limit)
    }

    public func recentForecasts(limit: Int = 80) throws -> [ForecastStoreSnapshot] {
        try ensureOpen()
        return try forecastLedger.recentForecasts(limit: limit)
    }

    public func recentPredictiveAlerts(limit: Int = 80) throws -> [PredictiveAlert] {
        try ensureOpen()
        return try forecastLedger.recentPredictiveAlerts(limit: limit)
    }

    public func loadRules(includeBuiltIns: Bool = true, settings: ThresholdSettings = .aggressive) throws -> [RadarRule] {
        if includeBuiltIns {
            return try rulesForContext(settings: settings)
        }
        if let cachedStoredRules {
            rulesCacheHitCount += 1
            return cachedStoredRules
        }
        let db = try ensureOpen()
        var rules: [RadarRule] = []
        let now = Date()
        try db.query("SELECT json FROM rules ORDER BY created_at DESC") { row in
            guard let rule = codec.decode(RadarRule.self, from: row.string(0)) else {
                return
            }
            if rule.expiresAt.map({ $0 <= now }) == true {
                return
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
        let db = try ensureOpen()
        let json = try codec.encode(rule)
        try db.execute(
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
        try ensureOpen().execute("DELETE FROM rules WHERE id = ?", .text(id.uuidString))
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
        var summaries: [String] = []
        try ensureOpen().query(
            "SELECT summary FROM actions WHERE kind = ? ORDER BY created_at DESC LIMIT ?",
            [.text(kind.rawValue), .int64(Int64(limit))]
        ) { row in
            if let summary = row.string(0) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    public func pruneIfNeeded(now: Date) throws {
        if let lastPruneDate, now.timeIntervalSince(lastPruneDate) < 24 * 60 * 60 {
            return
        }
        let db = try ensureOpen()
        let sampleCutoff = now.addingTimeInterval(-RadarStore.denseSampleRetention).timeIntervalSince1970
        let cutoff = now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970
        try db.execute("DELETE FROM samples WHERE sampled_at < ?", .double(sampleCutoff))
        try db.execute("DELETE FROM incidents WHERE resolved_at IS NOT NULL AND resolved_at < ?", .double(cutoff))
        for table in RadarStoreSchema.createdAtRetentionTables {
            try db.execute("DELETE FROM \(table) WHERE created_at < ?", .double(cutoff))
        }
        try db.execute("DELETE FROM rules WHERE json LIKE '%\"expiresAt\"%' AND created_at < ?", .double(cutoff))
        lastPruneDate = now
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
        try ensureOpen().execute(
            "INSERT INTO actions(id, signature_id, kind, summary, created_at) VALUES(?, ?, ?, ?, ?)",
            .text(action.id.uuidString),
            action.signatureID.map { .text($0) } ?? .null,
            .text(action.kind.rawValue),
            .text(action.summary),
            .double(action.createdAt.timeIntervalSince1970)
        )
    }

    /// Opens and migrates on first use. After a failure it retries at most
    /// once per `openRetryInterval`, rethrowing the last error in between so
    /// callers can surface it.
    @discardableResult
    private func ensureOpen() throws -> SQLiteDatabase {
        if db.isOpen {
            return db
        }
        let now = clock()
        if let openFailure, now.timeIntervalSince(openFailure.date) < Self.openRetryInterval {
            throw openFailure.error
        }
        do {
            try openAndMigrate(now: now)
        } catch {
            openFailure = (now, error)
            lastErrorMessage = error.localizedDescription
            RadarLogger.store.error("Radar store unavailable: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if openFailure != nil {
            openFailure = nil
            lastErrorMessage = nil
        }
        RadarLogger.store.info("Radar store opened at \(self.url.path, privacy: .private)")
        return db
    }

    private func openAndMigrate(now: Date) throws {
        do {
            try openMigrated()
        } catch where db.lastFailureIsCorruption {
            // A corrupt file would otherwise disable learning on every launch.
            let moved = db.quarantineFiles(at: now)
            RadarLogger.store.error("Radar store was corrupt; moved it to \(moved.lastPathComponent, privacy: .public) and started fresh")
            try openMigrated()
            recoveredFromCorruption = true
        }
    }

    /// A half-migrated connection must not look open to the next caller.
    private func openMigrated() throws {
        try db.open()
        do {
            try db.migrate(RadarStoreSchema.migrations)
        } catch {
            db.close()
            throw error
        }
    }

    private struct PendingAction {
        var id: UUID
        var signatureID: String?
        var kind: RadarActionType
        var summary: String
        var createdAt: Date
    }
}

// Raw statement helpers for the extensions (kill learning) that step
// statements themselves.
extension RadarStore {
    func transaction(_ body: () throws -> Void) throws {
        try ensureOpen().transaction(body)
    }

    func execute(_ sql: String, _ values: BindingValue...) throws {
        try ensureOpen().execute(sql, values: values)
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        try ensureOpen().prepare(sql)
    }

    func bind(_ value: BindingValue, to statement: OpaquePointer?, index: Int32) {
        SQLiteDatabase.bind(value, to: statement, index: index)
    }

    func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        SQLiteDatabase.columnString(statement, index)
    }
}
