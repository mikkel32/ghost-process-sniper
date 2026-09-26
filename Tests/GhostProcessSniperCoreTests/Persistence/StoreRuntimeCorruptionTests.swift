import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

/// A damaged page the open does not touch surfaces only when a later
/// statement reads it. That must recover like corruption found at open,
/// not fail every flush on every launch.
final class StoreRuntimeCorruptionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-runtime-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCorruptPageFoundByAFlushIsMovedAsideAndTheFlushRetried() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let first = RadarStore(url: url)
        try await persist(at: start, store: first)
        await first.close()
        try damageRootPage(of: "incidents_signature_active", in: url)

        let store = RadarStore(url: url)
        try await persist(at: start.addingTimeInterval(3_600), store: store)
        let health = await store.storeHealth()
        XCTAssertTrue(health.recoveredFromCorruption)
        XCTAssertNil(health.errorMessage)
        XCTAssertEqual(health.backlogCount, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("Radar.corrupt-") && $0.hasSuffix(".sqlite") }, "\(names)")
        await store.close()

        let next = RadarStore(url: url)
        try await persist(at: start.addingTimeInterval(7_200), store: next)
        let nextHealth = await next.storeHealth()
        XCTAssertFalse(nextHealth.recoveredFromCorruption, "the fresh file stays healthy on the next launch")
        XCTAssertNil(nextHealth.errorMessage)
    }

    func testRecoveryCarriesSettingsRulesAndLearnedBaselinesOver() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        var settings = ThresholdSettings.smart
        settings.memoryBytes = 44_000_000
        let rule = RadarRule(name: "Keep me", match: RadarRuleMatch(commandContains: "node"), action: .highlight)
        let first = RadarStore(url: url)
        try await first.saveSettings(settings)
        try await first.saveRule(rule)
        try await persist(at: start, store: first, families: [family(at: start), family(at: start, name: "vite")])
        await first.close()
        try damageRootPage(of: "incidents_signature_active", in: url)

        let store = RadarStore(url: url)
        let loaded = try await store.loadSettings(defaults: .aggressive)
        XCTAssertEqual(loaded, settings)
        // Both baselines are in memory; only the first is in the flush that finds the damage.
        let before = try await store.context(for: [family(at: start), family(at: start, name: "vite")], settings: .smart,
                                             now: start.addingTimeInterval(3_000))
        XCTAssertEqual(before.baselines.count, 2)
        try await persist(at: start.addingTimeInterval(3_600), store: store)
        let recovered = await store.storeHealth()
        XCTAssertTrue(recovered.recoveredFromCorruption)
        var edited = settings
        edited.forceKillDelay = 5
        try await store.saveSettings(edited)
        await store.close()

        let reopened = RadarStore(url: url)
        let persisted = try await reopened.loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted, edited)
        let rules = try await reopened.loadRules(includeBuiltIns: false)
        XCTAssertEqual(rules.map(\.id), [rule.id])
        let idle = family(at: start, name: "vite")
        let context = try await reopened.context(for: [family(at: start), idle], settings: .smart, now: start.addingTimeInterval(3_660))
        let baseline = context.baselines[family(at: start).signature.id]
        XCTAssertEqual(baseline?.firstSeenAt, start, "learning from before the damage carries over to the fresh file")
        XCTAssertEqual(baseline?.lastSeenAt, start.addingTimeInterval(3_600))
        XCTAssertEqual(context.baselines[idle.signature.id]?.firstSeenAt, start, "so does a baseline the flush did not touch")
    }

    func testCorruptPageFoundByAContextReadRecoversInTheSameCall() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let first = RadarStore(url: url)
        try await persist(at: start, store: first)
        await first.close()
        try damageRootPage(of: "baselines", in: url)

        let store = RadarStore(url: url)
        _ = try await store.context(for: [family(at: start)], settings: .smart, now: start.addingTimeInterval(60))
        let health = await store.storeHealth()
        XCTAssertTrue(health.recoveredFromCorruption)
        XCTAssertNil(health.errorMessage)
    }

    func testSalvagePrefersTheSettingsTheStoreLastSawOverTheDamagedFilesRow() throws {
        let damaged = SQLiteDatabase(url: folder.appendingPathComponent("Damaged.sqlite"))
        try damaged.open()
        try damaged.migrate(RadarStoreSchema.migrations)
        try damaged.execute("INSERT INTO settings(key, json, updated_at) VALUES('thresholds', '{}', 1)")
        let fresh = SQLiteDatabase(url: folder.appendingPathComponent("Fresh.sqlite"))
        try fresh.open()
        try fresh.migrate(RadarStoreSchema.migrations)

        let known = "{\"memoryBytes\":5}"
        XCTAssertEqual(StoreSalvage(readingFrom: damaged, knownSettingsJSON: known).restore(into: fresh), known)
        XCTAssertEqual(try fresh.string("SELECT json FROM settings WHERE key = 'thresholds'"), known)
        XCTAssertEqual(StoreSalvage(readingFrom: damaged, knownSettingsJSON: nil).restore(into: fresh), "{}")
    }

    private func persist(at date: Date, store: RadarStore, families: [ProcessFamily]? = nil) async throws {
        let model = RadarModel(families: families ?? [family(at: date)], summary: .empty, incidents: [], rules: [], health: .starting, generatedAt: date)
        _ = try await store.enqueue(model: model, settings: .smart, now: date)
        try await store.flush(now: date)
    }

    /// Overwrites the root page of a table or index, leaving the header and
    /// schema intact, like a torn write or a bad sector.
    private func damageRootPage(of name: String, in url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT rootpage FROM sqlite_master WHERE name = '\(name)'", -1, &statement, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let rootPage = Int(sqlite3_column_int64(statement, 0))
        sqlite3_finalize(statement)
        sqlite3_prepare_v2(handle, "PRAGMA page_size", -1, &statement, nil)
        sqlite3_step(statement)
        let pageSize = Int(sqlite3_column_int64(statement, 0))
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        XCTAssertGreaterThan(rootPage, 1)
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: UInt64((rootPage - 1) * pageSize))
        file.write(Data(repeating: 0xA5, count: pageSize))
        try file.close()
    }

    private func family(at date: Date, name: String = "node") -> ProcessFamily {
        let identity = ProcessIdentity(pid: name == "node" ? 731 : 732, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let footprint: UInt64 = 3_000_000_000
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: name,
                                  executablePath: "/usr/local/bin/\(name)", commandLine: "\(name) server.js",
                                  residentMemoryBytes: footprint, physicalFootprintBytes: footprint,
                                  virtualMemoryBytes: footprint * 2, cpuPercent: 0, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: footprint,
                             totalPhysicalFootprintBytes: footprint, totalCPUPercent: 0,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: 80, level: .hot, reasons: ["memory"]),
                             ownedIdentities: [identity], protectedPIDs: [],
                             alertState: AlertState(kind: .normal, message: "normal", since: date),
                             lastScoredAt: date)
    }
}
