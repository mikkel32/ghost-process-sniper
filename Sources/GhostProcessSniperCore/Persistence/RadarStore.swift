import Foundation

public enum RadarStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case unreadSettings

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "Unable to open radar store: \(message)"
        case .sqlite(let message):
            "Radar store error: \(message)"
        case .unreadSettings:
            "Radar store error: saved settings were not loaded yet, so they were left as they are"
        }
    }
}

/// Settings, rules, context and write batching. Tables with their own logic
/// live in collaborators that share this actor's connection and never escape it.
///
/// The database opens on first use, on this actor, so creating the store on
/// the main actor at launch does no SQLite work there.
public actor RadarStore {
    public static let incidentRetention: TimeInterval = 90 * 24 * 60 * 60
    static let openRetryInterval: TimeInterval = 30
    /// A locked or full disk must not grow the queue by a full model per tick.
    static let maximumBacklog = 3

    typealias BindingValue = SQLiteValue

    let url: URL
    private let db: SQLiteDatabase
    private let codec = StoreCodec()
    private let baselineBook: BaselineBook
    private let incidentLedger: IncidentLedger
    private let ruleBook: RuleBook
    private let maintenance: StoreMaintenance
    private let clock: @Sendable () -> Date
    private var openFailure: (date: Date, error: any Error)?
    private var recoveredFromCorruption = false
    private var pendingModels: [RadarModel] = []
    private var lastFlushDate: Date?
    private var transactionsSkipped = 0
    private var lastFlushMilliseconds = 0.0
    private var lastContextMilliseconds = 0.0
    private var skippedSettingsWriteCount = 0
    private var lastSettingsJSON: String?
    /// A save from a caller that never saw the stored settings would put
    /// its defaults over them.
    private var hasReadSettings = false
    private var lastErrorMessage: String?
    private var droppedModelCount = 0
    private var isClosed = false
    var lastKillOperationSummary: String?

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
        let rules = RuleBook(db: database, codec: codec)
        ruleBook = rules
        maintenance = StoreMaintenance(db: database, ruleBook: rules, baselineBook: baselineBook)
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
        let json = try db.string("SELECT json FROM settings WHERE key = 'thresholds' LIMIT 1")
        hasReadSettings = true
        guard let json else {
            return defaults
        }
        lastSettingsJSON = json
        return codec.decode(ThresholdSettings.self, from: json) ?? defaults
    }

    /// Throws `unreadSettings` instead of replacing stored settings that
    /// this store never loaded.
    public func saveSettings(_ settings: ThresholdSettings) throws {
        let db = try ensureOpen()
        let json = try codec.encode(settings)
        if lastSettingsJSON == json {
            skippedSettingsWriteCount += 1
            return
        }
        if let stored = try db.string("SELECT json FROM settings WHERE key = 'thresholds' LIMIT 1") {
            if stored == json {
                lastSettingsJSON = json
                skippedSettingsWriteCount += 1
                return
            }
            guard hasReadSettings else {
                throw RadarStoreError.unreadSettings
            }
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
        let signatureIDs = Array(Set(families.map(\.signature.id)))
        let rules = try ruleBook.composed(settings: settings, now: now)
        return RadarContext(
            baselines: try baselineBook.baselines(for: signatureIDs, at: now),
            recentIncidentCounts: try incidentLedger.recentCounts(
                for: signatureIDs,
                since: now.addingTimeInterval(-RadarStore.incidentRetention)
            ),
            rules: rules
        )
    }

    /// `settings` only sets the flush cadence. Settings are persisted by
    /// saveSettings alone, so a queued model cannot overwrite a newer edit.
    public func enqueue(model: RadarModel, settings: ThresholdSettings, now: Date = Date()) throws -> StoreHealth {
        pendingModels.append(model)
        if shouldFlush(now: now, settings: settings) {
            try flush(now: now)
        }
        return storeHealth()
    }

    public func flush(now: Date = Date()) throws {
        try flush(now: now, force: false)
    }

    /// Learns every queued model in memory, then writes only what is due:
    /// incident changes and baselines that have learned enough or waited
    /// long enough. A flush with nothing due skips the transaction entirely.
    /// `force` writes every learned baseline, for shutdown.
    private func flush(now: Date, force: Bool) throws {
        guard !pendingModels.isEmpty || (force && baselineBook.deferredCount > 0) else {
            return
        }
        let models = pendingModels
        pendingModels.removeAll(keepingCapacity: true)
        // Model dates drive the learning clocks, so replayed or test models
        // age consistently.
        let modelNow = models.last?.generatedAt ?? now

        let flushStart = Date()
        do {
            let db = try ensureOpen()
            for model in models {
                try baselineBook.learn(from: model.families, at: model.generatedAt)
                try incidentLedger.stage(model.families, at: model.generatedAt)
            }
            baselineBook.stagePersist(now: modelNow, force: force)
            if baselineBook.hasPendingWrites || incidentLedger.hasPendingWrites {
                try db.transaction {
                    try baselineBook.writeStaged()
                    try incidentLedger.writeStaged()
                }
            } else {
                transactionsSkipped += 1
            }
            baselineBook.commitStaged()
            incidentLedger.commitStaged()
            lastFlushDate = now
            lastFlushMilliseconds = Date().timeIntervalSince(flushStart) * 1_000
            lastErrorMessage = nil
        } catch {
            baselineBook.discardStaged()
            incidentLedger.discardStaged()
            let retry = models + pendingModels
            pendingModels = Array(retry.suffix(Self.maximumBacklog))
            droppedModelCount += retry.count - pendingModels.count
            lastErrorMessage = error.localizedDescription
            throw error
        }
        if !force, maintenance.isDue(now: modelNow) {
            runMaintenance(now: modelNow)
        }
    }

    /// Flushes what is queued, persists every learned baseline, checkpoints
    /// and truncates the WAL, and closes the connection. Every later call
    /// throws.
    public func close() {
        guard !isClosed else {
            return
        }
        do {
            try flush(now: Date(), force: true)
        } catch {
            RadarLogger.store.error("Final flush failed: \(error.localizedDescription, privacy: .public)")
        }
        if db.isOpen {
            try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            try? db.exec("PRAGMA optimize")
            db.close()
        }
        isClosed = true
    }

    public func storeHealth() -> StoreHealth {
        StoreHealth(
            backlogCount: pendingModels.count,
            pendingActionCount: 0,
            lastFlushDate: lastFlushDate,
            lastPruneDate: maintenance.lastRunDate,
            lastFlushMilliseconds: lastFlushMilliseconds,
            lastContextMilliseconds: lastContextMilliseconds,
            skippedSettingsWriteCount: skippedSettingsWriteCount,
            writeStats: StoreWriteStats(
                baselineWrites: baselineBook.writeCount,
                baselinesDeferred: baselineBook.deferredCount,
                transactionsSkipped: transactionsSkipped
            ),
            rulesCacheHitCount: ruleBook.cacheHitCount,
            errorMessage: lastErrorMessage,
            lastKillOperationSummary: lastKillOperationSummary,
            recoveredFromCorruption: recoveredFromCorruption,
            droppedModelCount: droppedModelCount
        )
    }

    public func recentIncidents(limit: Int = 80) throws -> [RadarIncident] {
        try ensureOpen()
        return try incidentLedger.recent(limit: limit)
    }

    public func loadRules(includeBuiltIns: Bool = true, settings: ThresholdSettings = .aggressive) throws -> [RadarRule] {
        try ensureOpen()
        let now = Date()
        if includeBuiltIns {
            return try ruleBook.composed(settings: settings, now: now)
        }
        return try ruleBook.stored().filter { !RuleBook.isExpired($0, at: now) }
    }

    public func saveRule(_ rule: RadarRule) throws {
        try ensureOpen()
        try ruleBook.save(rule)
        RadarLogger.rules.info("Saved rule \(rule.name, privacy: .public)")
    }

    public func deleteRule(id: UUID) throws {
        try ensureOpen()
        try ruleBook.delete(id: id)
    }

    public func setRuleEnabled(id: UUID, isEnabled: Bool) throws {
        var stored = try loadRules(includeBuiltIns: false)
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            return
        }
        stored[index].isEnabled = isEnabled
        try saveRule(stored[index])
    }

    /// Kill reports are stored with their operation; this only notes the
    /// action in the log.
    public func recordAction(
        kind: RadarActionType,
        family: ProcessFamily?,
        summary: String,
        at date: Date = Date()
    ) throws {
        RadarLogger.store.info("Action \(kind.rawValue, privacy: .public) on \(family?.displayName ?? "no family", privacy: .public)")
    }

    /// Runs the daily maintenance now unless it ran in the last day.
    public func pruneIfNeeded(now: Date) throws {
        try ensureOpen()
        guard maintenance.isDue(now: now, ignoringLaunchDelay: true) else {
            return
        }
        try maintenance.run(now: now)
    }

    private func runMaintenance(now: Date) {
        do {
            try maintenance.run(now: now)
        } catch {
            RadarLogger.store.error("Store maintenance failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldFlush(now: Date, settings: ThresholdSettings) -> Bool {
        if pendingModels.count >= Self.maximumBacklog {
            return true
        }
        guard let lastFlushDate else {
            return true
        }
        return now.timeIntervalSince(lastFlushDate) >= RadarPerformanceBudget.budget(for: settings.performanceMode).storeFlushInterval
    }

    /// Opens and migrates on first use. After a failure it retries at most
    /// once per `openRetryInterval`, rethrowing the last error in between so
    /// callers can surface it.
    @discardableResult
    private func ensureOpen() throws -> SQLiteDatabase {
        guard !isClosed else {
            throw RadarStoreError.sqlite("the store is closed")
        }
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
            let version = try db.userVersion()
            if version < RadarStoreSchema.slimVersion, try db.hasTables() {
                StoreMaintenance.backUp(db, from: version)
            }
            try db.migrate(RadarStoreSchema.migrations)
        } catch {
            db.close()
            throw error
        }
        StoreMaintenance.enableIncrementalVacuum(db)
    }
}

// Raw statement helpers for the extensions (kill learning) that step
// statements themselves.
extension RadarStore {
    /// Rows written since the connection opened; tests measure write volume.
    func totalChanges() -> Int {
        db.totalChanges
    }

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
