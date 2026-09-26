import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

final class StoreDurabilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCloseFlushesCheckpointsAndReopensWithTheLatestState() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let store = RadarStore(url: url)
        var settings = ThresholdSettings.smart
        settings.memoryBytes = 91_000_000
        try await store.saveSettings(settings)
        _ = try await store.enqueue(model: model(at: start), settings: settings, now: start)
        let queued = try await store.enqueue(model: model(at: start.addingTimeInterval(1)), settings: settings, now: start.addingTimeInterval(1))
        XCTAssertEqual(queued.backlogCount, 1, "the second model should still be queued when the store closes")

        await store.close()

        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0
        XCTAssertEqual(wal, 0, "closing must checkpoint and truncate the WAL")
        do {
            _ = try await store.loadSettings(defaults: .smart)
            XCTFail("a closed store must refuse further work")
        } catch {}

        let reopened = RadarStore(url: url)
        let loaded = try await reopened.loadSettings(defaults: .smart)
        XCTAssertEqual(loaded.memoryBytes, 91_000_000)
        let family = family(at: start)
        let context = try await reopened.context(for: [family], settings: .smart, now: start.addingTimeInterval(2))
        XCTAssertEqual(context.baselines[family.signature.id]?.sampleCount, 2)
    }

    func testLockedFlushesKeepTheBacklogBoundedAndNeverLearnTwice() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let store = RadarStore(url: url, busyTimeoutMilliseconds: 10, clock: { Date() })
        _ = try await store.enqueue(model: model(at: start), settings: .smart, now: start)

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)

        for second in 1...10 {
            let date = start.addingTimeInterval(TimeInterval(second))
            _ = try? await store.enqueue(model: model(at: date), settings: .smart, now: date)
            let backlog = await store.storeHealth().backlogCount
            XCTAssertLessThanOrEqual(backlog, 3, "backlog after model \(second)")
        }
        let blocked = await store.storeHealth()
        XCTAssertGreaterThan(blocked.droppedModelCount, 0)
        XCTAssertNotNil(blocked.errorMessage)

        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        try await store.flush(now: start.addingTimeInterval(11))
        let retained = 1 + 3
        let family = family(at: start)
        let context = try await store.context(for: [family], settings: .smart, now: start.addingTimeInterval(12))
        XCTAssertEqual(context.baselines[family.signature.id]?.sampleCount, retained,
                       "only the first flush and the three retained models were committed")
        let recovered = await store.storeHealth()
        XCTAssertEqual(recovered.backlogCount, 0)
        XCTAssertNil(recovered.errorMessage)
    }

    func testFlushNoLongerWritesTheSettingsCarriedByModels() async throws {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        var saved = ThresholdSettings.smart
        saved.memoryBytes = 55_000_000
        try await store.saveSettings(saved)
        var stale = ThresholdSettings.smart
        stale.memoryBytes = 11_000_000
        _ = try await store.enqueue(model: model(at: start), settings: stale, now: start)
        try await store.flush(now: start)
        let loaded = try await store.loadSettings(defaults: .smart)
        XCTAssertEqual(loaded.memoryBytes, 55_000_000)
    }

    @MainActor
    func testShutdownKeepsASettingsChangeMadeJustBeforeQuitting() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let monitor = ProcessMonitor(store: RadarStore(url: url))
        monitor.settings.memoryBytes = 66_000_000
        monitor.saveSettingsDebounced(delay: 60)
        await monitor.shutdown()

        let loaded = try await RadarStore(url: url).loadSettings(defaults: .smart)
        XCTAssertEqual(loaded.memoryBytes, 66_000_000)
    }

    private func model(at date: Date) -> RadarModel {
        RadarModel(families: [family(at: date)], summary: .empty, incidents: [], rules: [], health: .starting, generatedAt: date)
    }

    private func family(at date: Date) -> ProcessFamily {
        let identity = ProcessIdentity(pid: 740, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: "node",
                                  executablePath: "/usr/local/bin/node", commandLine: "node server.js",
                                  residentMemoryBytes: 40_000_000, physicalFootprintBytes: 40_000_000,
                                  virtualMemoryBytes: 80_000_000, cpuPercent: 1, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: 40_000_000,
                             totalPhysicalFootprintBytes: 40_000_000, totalCPUPercent: 1,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: 2, level: .quiet, reasons: []),
                             ownedIdentities: [identity], protectedPIDs: [], lastScoredAt: date)
    }
}
