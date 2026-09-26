import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

final class MigrationTests: XCTestCase {
    private let latest = RadarStoreSchema.migrations.map(\.version).max() ?? 0
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testUnversionedStoreMigratesWithRowsIntact() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        for sql in RadarStoreSchema.migrationStatements {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
        let rule = RadarRule(name: "Keep me", match: RadarRuleMatch(commandContains: "node"), action: .highlight)
        let json = try StoreCodec().encode(rule).replacingOccurrences(of: "'", with: "''")
        let insert = "INSERT INTO rules(id, json, created_at) VALUES('\(rule.id.uuidString)', '\(json)', 1)"
        XCTAssertEqual(sqlite3_exec(handle, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try userVersion(handle), 0)
        sqlite3_close(handle)

        let store = RadarStore(url: url)
        let rules = try await store.loadRules(includeBuiltIns: false)
        XCTAssertEqual(rules.map(\.id), [rule.id])

        let reopened = SQLiteDatabase(url: url)
        try reopened.open()
        XCTAssertEqual(try reopened.userVersion(), latest)
        XCTAssertEqual(try reopened.migrate(RadarStoreSchema.migrations), [], "a current store must open without migrating")
        XCTAssertEqual(try reopened.string("SELECT id FROM rules"), rule.id.uuidString)
        let indexes = "SELECT group_concat(name) FROM sqlite_master WHERE type = 'index' AND name LIKE 'incidents_signature_started%'"
        XCTAssertEqual(try reopened.string(indexes), "incidents_signature_started_resolved")
    }

    func testVersionOneStoreSlimsDownAndKeepsItsHistory() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let v1 = SQLiteDatabase(url: url)
        try v1.open()
        try v1.migrate(RadarStoreSchema.migrations.filter { $0.version == 1 })
        let seed = [
            """
            INSERT INTO incidents VALUES('i1', 'sig', 'node', '/node', 'fp', 'node', 'Hot', 80, 1, 1, 0, '[]',
                                         1800000000, 1800000010, 1800000020, 1)
            """,
            """
            INSERT INTO baselines VALUES('sig', 'node', '/node', 'fp', 7, 1, 1, 1, 1, 0, 0, 1800000000, 1800000010, 1)
            """,
            """
            INSERT INTO kill_operations VALUES('k1', 'sig', 'node', 42, 'Stopped', 1, 1, 1, 0, 0, 0, 0, 0, 12, 1800000000)
            """,
            "INSERT INTO forecasts VALUES('sig', 'leaking', 0.9, NULL, 'why', 1, 1, 0, 0, 1800000000)",
            "INSERT INTO samples(signature_id, family_name, level, score, memory_bytes, cpu_percent, leak_velocity, sampled_at) VALUES('sig', 'node', 'Hot', 1, 1, 1, 0, 1)",
            "INSERT INTO actions VALUES('a1', 'sig', 'kill', 'report', 1800000000)"
        ]
        for sql in seed {
            try v1.exec(sql)
        }
        XCTAssertEqual(try v1.userVersion(), 1)
        v1.close()

        let store = RadarStore(url: url)
        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.map(\.id.uuidString.isEmpty), [false])
        let kills = try await store.recentKillOperations()
        XCTAssertEqual(kills.count, 1)
        await store.close()

        let migrated = SQLiteDatabase(url: url)
        try migrated.open()
        defer { migrated.close() }
        XCTAssertEqual(try migrated.userVersion(), latest)
        for table in ["samples", "forecasts", "recommendation_history", "predictive_alerts", "actions"] {
            XCTAssertNil(try migrated.string("SELECT name FROM sqlite_master WHERE name = ?", [.text(table)]), table)
        }
        XCTAssertEqual(try migrated.string("SELECT sample_count FROM baselines WHERE signature_id = 'sig'"), "7")
        XCTAssertEqual(try migrated.string("SELECT signature_id FROM incidents"), "sig")
        XCTAssertEqual(try migrated.string("PRAGMA auto_vacuum"), "2", "the store compacts incrementally after migrating")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak-v1"), "the pre-migration file is kept")
        let backup = SQLiteDatabase(url: URL(fileURLWithPath: url.path + ".bak-v1"))
        try backup.open()
        defer { backup.close() }
        XCTAssertEqual(try backup.string("SELECT COUNT(*) FROM forecasts"), "1")
    }

    func testVersionThreeStoreRebuildsKillLearningAndKeepsTheAudit() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let v3 = SQLiteDatabase(url: url)
        try v3.open()
        try v3.migrate(RadarStoreSchema.migrations.filter { $0.version <= RadarStoreSchema.slimVersion })
        let seed = [
            "INSERT INTO kill_operations VALUES('k1', 'sig', 'node', 42, 'Stopped', 1, 1, 1, 0, 0, 0, 0, 0, 12, 1800000000)",
            """
            INSERT INTO kill_outcome_history VALUES('o1', 'k1', 'sig', 'standard', 'ownedFamily', 0, 0, 1, 2, 0, 2, 1800000000)
            """,
            """
            INSERT INTO kill_strategy_history VALUES('s1', 'k1', 'sig', 'nodeServer', 'standard', 'ownedFamily',
                                                     0, 0, 1, 2, 0, 2, 1800000000)
            """,
            """
            INSERT INTO kill_calibration_aggregates VALUES('sig|*|standard', 'sig', NULL, 'standard', 3, 0.2, 0.5, 0.6, 2, 1, 0.8, 1800000000)
            """
        ]
        for sql in seed {
            try v3.exec(sql)
        }
        XCTAssertEqual(try v3.userVersion(), RadarStoreSchema.slimVersion)
        v3.close()

        let store = RadarStore(url: url)
        let history = try await store.killStrategyHistory(signatureID: "sig", now: Date(timeIntervalSince1970: 1800000100))
        XCTAssertEqual(history.operationCount, 0, "rows from before held force was recorded are dropped")
        let outcomes = try await store.killOutcomeHistory(signatureID: "sig", devKind: "nodeServer")
        XCTAssertEqual(outcomes, .empty, "the old calibration rates are not posteriors")
        let audit = try await store.recentKillOperations()
        XCTAssertEqual(audit.map(\.displayName), ["node"], "the audit trail survives the rebuild")
        await store.close()

        let migrated = SQLiteDatabase(url: url)
        try migrated.open()
        defer { migrated.close() }
        XCTAssertEqual(try migrated.userVersion(), latest)
        XCTAssertTrue(try migrated.hasColumn("held_force", in: "kill_outcome_history"))
        XCTAssertTrue(try migrated.hasColumn("held_force", in: "kill_strategy_history"))
        XCTAssertTrue(try migrated.hasColumn("clean_weight", in: "kill_calibration_aggregates"))
        XCTAssertFalse(try migrated.hasColumn("graceful_success_rate", in: "kill_calibration_aggregates"))
    }

    func testVersionFourStoreGainsBaselineStatisticsAndKeepsItsRows() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let v4 = SQLiteDatabase(url: url)
        try v4.open()
        try v4.migrate(RadarStoreSchema.migrations.filter { $0.version <= RadarStoreSchema.killLearningVersion })
        try v4.exec("INSERT INTO baselines VALUES('sig', 'node', '/node', 'fp', 7, 1, 1, 1, 1, 0, 0, 1800000000, 1800000010, 1)")
        XCTAssertEqual(try v4.userVersion(), RadarStoreSchema.killLearningVersion)
        v4.close()

        let store = RadarStore(url: url)
        _ = try await store.loadRules(includeBuiltIns: false)
        await store.close()

        let migrated = SQLiteDatabase(url: url)
        try migrated.open()
        defer { migrated.close() }
        XCTAssertEqual(try migrated.userVersion(), latest)
        XCTAssertGreaterThanOrEqual(latest, RadarStoreSchema.baselineStatisticsVersion)
        for column in ["memory_variance", "cpu_variance", "observed_seconds", "session_count"] {
            XCTAssertTrue(try migrated.hasColumn(column, in: "baselines"), column)
        }
        var baselines: [FamilyBaseline] = []
        try migrated.query("SELECT \(RadarStoreRows.baselineColumns) FROM baselines") { row in
            baselines.append(RadarStoreRows.baseline(from: row))
        }
        let baseline = try XCTUnwrap(baselines.first)
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(baseline.sampleCount, 7, "the learned row survives the upgrade")
        XCTAssertEqual(baseline.memoryVariance, 0)
        XCTAssertEqual(baseline.observedSeconds, 0)
        XCTAssertEqual(baseline.sessionCount, 1)
    }

    func testUpgradedAndFreshStoresEndInTheSameSchema() async throws {
        let upgradedURL = folder.appendingPathComponent("Upgraded.sqlite")
        let v3 = SQLiteDatabase(url: upgradedURL)
        try v3.open()
        try v3.migrate(RadarStoreSchema.migrations.filter { $0.version <= RadarStoreSchema.slimVersion })
        try v3.exec("INSERT INTO kill_operations VALUES('k1', 'sig', 'node', 42, 'Stopped', 1, 1, 1, 0, 0, 0, 0, 0, 12, 1800000000)")
        v3.close()
        let freshURL = folder.appendingPathComponent("Fresh.sqlite")
        for url in [upgradedURL, freshURL] {
            let store = RadarStore(url: url)
            _ = try await store.loadRules(includeBuiltIns: false)
            await store.close()
        }
        XCTAssertEqual(try schema(at: upgradedURL), try schema(at: freshURL))
        XCTAssertFalse(try schema(at: freshURL).isEmpty)
    }

    /// Every table and index with its definition, whitespace-normalized.
    private func schema(at url: URL) throws -> [String] {
        let database = SQLiteDatabase(url: url)
        try database.open()
        defer { database.close() }
        var rows: [String] = []
        try database.query("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name") { row in
            let sql = (row.string(2) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            rows.append("\(row.string(0) ?? "") \(row.string(1) ?? ""): \(sql)")
        }
        rows.append("user_version \(try database.userVersion())")
        return rows
    }

    func testFreshStoreStartsCompactable() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let store = RadarStore(url: url)
        _ = try await store.loadRules(includeBuiltIns: false)
        await store.close()
        let database = SQLiteDatabase(url: url)
        try database.open()
        defer { database.close() }
        XCTAssertEqual(try database.string("PRAGMA auto_vacuum"), "2")
        XCTAssertEqual(try database.string("PRAGMA journal_size_limit"), "4194304")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".bak-v0"), "an empty file needs no backup")
    }

    func testNewerVersionAppliesOnceAndKeepsRows() throws {
        let database = SQLiteDatabase(url: folder.appendingPathComponent("Radar.sqlite"))
        try database.open()
        XCTAssertEqual(try database.migrate(RadarStoreSchema.migrations), RadarStoreSchema.migrations.map(\.version))
        try database.execute("INSERT INTO settings(key, json, updated_at) VALUES('thresholds', '{}', 1)")

        let next = RadarStoreSchema.migrations + [
            SQLiteMigration(version: latest + 1, statements: ["CREATE TABLE extra(id INTEGER PRIMARY KEY)"])
        ]
        XCTAssertEqual(try database.migrate(next), [latest + 1])
        XCTAssertEqual(try database.userVersion(), latest + 1)
        XCTAssertEqual(try database.string("SELECT json FROM settings WHERE key = 'thresholds'"), "{}")
        XCTAssertEqual(try database.migrate(next), [])
    }

    func testFailedMigrationRollsBackAndKeepsItsVersion() throws {
        let database = SQLiteDatabase(url: folder.appendingPathComponent("Radar.sqlite"))
        try database.open()
        try database.migrate(RadarStoreSchema.migrations)
        let broken = RadarStoreSchema.migrations + [
            SQLiteMigration(version: latest + 1, statements: ["CREATE TABLE half(id INTEGER)", "NOT SQL"])
        ]
        XCTAssertThrowsError(try database.migrate(broken))
        XCTAssertEqual(try database.userVersion(), latest)
        XCTAssertNil(try database.string("SELECT name FROM sqlite_master WHERE name = 'half'"))
    }

    func testLegacyBaselineTableGainsMeasurementColumn() throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let legacy = """
        CREATE TABLE baselines(signature_id TEXT PRIMARY KEY, display_name TEXT, canonical_path TEXT,
          command_fingerprint TEXT, sample_count INTEGER, mean_memory_bytes REAL, peak_memory_bytes INTEGER,
          mean_cpu_percent REAL, peak_cpu_percent REAL, mean_leak_velocity REAL, incident_count INTEGER,
          first_seen_at REAL, last_seen_at REAL)
        """
        XCTAssertEqual(sqlite3_exec(handle, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let database = SQLiteDatabase(url: url)
        try database.open()
        try database.migrate(RadarStoreSchema.migrations)
        XCTAssertTrue(try database.hasColumn("measurement_version", in: "baselines"))
    }

    private func userVersion(_ handle: OpaquePointer?) throws -> Int32 {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }
}
