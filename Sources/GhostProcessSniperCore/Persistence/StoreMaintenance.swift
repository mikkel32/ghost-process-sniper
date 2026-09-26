import Foundation

/// Daily housekeeping, so the store stays bounded: old history is deleted,
/// the freed pages are returned to the file system, and caches forget
/// signatures that stopped appearing. Runs from a flush, never from the
/// per-tick context read, and not in the first minute after launch.
final class StoreMaintenance {
    static let interval: TimeInterval = 24 * 60 * 60
    static let launchDelay: TimeInterval = 60
    static let baselineRetention: TimeInterval = 90 * 24 * 60 * 60
    static let calibrationRetention: TimeInterval = 180 * 24 * 60 * 60
    static let cacheIdleLimit: TimeInterval = 24 * 60 * 60

    private let db: SQLiteDatabase
    private let ruleBook: RuleBook
    private let baselineBook: BaselineBook
    private var firstFlushDate: Date?
    private var lastAttemptDate: Date?
    private(set) var lastRunDate: Date?

    init(db: SQLiteDatabase, ruleBook: RuleBook, baselineBook: BaselineBook) {
        self.db = db
        self.ruleBook = ruleBook
        self.baselineBook = baselineBook
    }

    func isDue(now: Date, ignoringLaunchDelay: Bool = false) -> Bool {
        let first = firstFlushDate ?? now
        firstFlushDate = first
        if !ignoringLaunchDelay, now.timeIntervalSince(first) < Self.launchDelay {
            return false
        }
        // A failed run waits a day as well, instead of retrying every flush.
        guard let lastAttemptDate else {
            return true
        }
        return now.timeIntervalSince(lastAttemptDate) >= Self.interval
    }

    func run(now: Date) throws {
        lastAttemptDate = now
        let historyCutoff = now.addingTimeInterval(-RadarStore.incidentRetention).timeIntervalSince1970
        try db.transaction {
            try db.execute("DELETE FROM incidents WHERE resolved_at IS NOT NULL AND resolved_at < ?", .double(historyCutoff))
            for table in RadarStoreSchema.createdAtRetentionTables {
                try db.execute("DELETE FROM \(table) WHERE created_at < ?", .double(historyCutoff))
            }
            try db.execute(
                "DELETE FROM baselines WHERE last_seen_at < ?",
                .double(now.addingTimeInterval(-Self.baselineRetention).timeIntervalSince1970)
            )
            try db.execute(
                "DELETE FROM kill_calibration_aggregates WHERE updated_at < ?",
                .double(now.addingTimeInterval(-Self.calibrationRetention).timeIntervalSince1970)
            )
            try ruleBook.pruneExpired(now: now)
        }
        // Housekeeping pragmas must run outside a transaction; failing one
        // is not worth failing the run.
        try? db.exec("PRAGMA incremental_vacuum(128)")
        try? db.exec("PRAGMA optimize")
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        baselineBook.evict(notSeenSince: now.addingTimeInterval(-Self.cacheIdleLimit))
        lastRunDate = now
    }

    /// Copies the database aside before a migration that drops tables.
    /// A failed copy is logged; the dropped tables only held write-only data.
    static func backUp(_ db: SQLiteDatabase, from version: Int32) {
        let backup = URL(fileURLWithPath: db.url.path + ".bak-v\(version)")
        do {
            try? FileManager.default.removeItem(at: backup)
            try db.execute("VACUUM INTO ?", .text(backup.path))
        } catch {
            RadarLogger.store.error("Radar store backup before migrating failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// auto_vacuum only changes through a full VACUUM, which cannot run in a
    /// transaction. It runs once per file; a failure retries on the next open.
    static func enableIncrementalVacuum(_ db: SQLiteDatabase) {
        do {
            guard try db.string("PRAGMA auto_vacuum") != "2" else {
                return
            }
            try db.exec("PRAGMA auto_vacuum = INCREMENTAL")
            try db.exec("VACUUM")
        } catch {
            RadarLogger.store.error("Radar store compaction failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
