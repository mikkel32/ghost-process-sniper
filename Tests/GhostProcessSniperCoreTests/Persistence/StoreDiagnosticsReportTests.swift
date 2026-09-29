import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

final class StoreDiagnosticsReportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testReportSaysWhichSchemaAndHowBigTheStoreIs() async throws {
        let store = try await storeWithOneIncident()
        let report = try await store.exportDiagnosticsReport(settings: .smart)

        let latest = try XCTUnwrap(RadarStoreSchema.migrations.last?.version)
        XCTAssertTrue(report.contains("Schema version: \(latest)\n"), report)
        XCTAssertTrue(report.contains("Stored rows: incidents 1, baselines "), report)
        for table in ["rules", "kill operations", "energy days"] {
            XCTAssertTrue(report.contains("\(table) "), "\(table) is counted")
        }
        XCTAssertFalse(report.contains("n/a"), "every table could be counted")

        let size = try XCTUnwrap(report.firstMatch(of: /Store file: (\S+ [KMG]B), write-ahead log (\S+ [KMG]B)/), report)
        XCTAssertNotEqual(String(size.1), "0 KB", "a store that holds an incident is not empty")
    }

    func testATableThatCannotBeCountedDoesNotFailTheReport() async throws {
        let store = try await storeWithOneIncident()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("Radar.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE energy_days", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)

        let report = try await store.exportDiagnosticsReport(settings: .smart)
        XCTAssertTrue(report.contains("energy days n/a"), report)
        XCTAssertTrue(report.contains("incidents 1,"), "the other counts survive")
        XCTAssertTrue(report.contains("Baseline writes:"), "the rest of the report is intact")
    }

    func testReportNeverPrintsTheHomeFolder() async throws {
        let store = try await storeWithOneIncident()
        // The store lives in a temporary folder, so stand in for the home
        // folder with its parent: everything below it must read `~/…`.
        let home = folder.deletingLastPathComponent().path
        let report = try await store.exportDiagnosticsReport(settings: .smart, home: home)
        XCTAssertTrue(report.contains("URL: ~/\(folder.lastPathComponent)/Radar.sqlite"), report)
        XCTAssertFalse(report.contains(home + "/"), report)
    }

    // MARK: - Fixtures

    private func storeWithOneIncident() async throws -> RadarStore {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let model = RadarModel(families: [hotFamily(at: date)], summary: .empty, incidents: [], rules: [],
                               health: .starting, generatedAt: date)
        _ = try await store.enqueue(model: model, settings: .smart, now: date)
        try await store.flush(now: date)
        return store
    }

    private func hotFamily(at date: Date) -> ProcessFamily {
        let identity = ProcessIdentity(pid: 731, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let footprint: UInt64 = 3_000_000_000
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: "node",
                                  executablePath: "/usr/local/bin/node", commandLine: "node server.js",
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
