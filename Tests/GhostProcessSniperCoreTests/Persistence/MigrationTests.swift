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
