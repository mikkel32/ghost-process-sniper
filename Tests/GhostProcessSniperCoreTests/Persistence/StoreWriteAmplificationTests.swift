import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class StoreWriteAmplificationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testThirtyTicksOfThreeHundredFamiliesWriteEachBaselineOnce() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let store = RadarStore(url: url)
        // Before write-behind, every flush upserted all 300 baselines, 64
        // forecasts and their history: 9,684 row writes for these 30 ticks.
        for tick in 0..<30 {
            let date = start.addingTimeInterval(Double(tick) * 3.5)
            _ = try await store.enqueue(model: model(at: date), settings: .smart, now: date)
        }
        let changes = await store.totalChanges()
        let health = await store.storeHealth()
        XCTAssertLessThanOrEqual(changes, 400, "one baseline pass plus six incident episodes")
        XCTAssertEqual(health.writeStats.baselineWrites, 294, "hot families learn no samples, so only the quiet ones are due")
        XCTAssertGreaterThan(health.writeStats.transactionsSkipped, 0)
        XCTAssertNotNil(health.lastPruneDate, "maintenance runs from a flush once the first minute has passed")

        let unflushed = await store.storeHealth().backlogCount
        await store.close()
        let reopened = RadarStore(url: url)
        let probe = family(10, at: start)
        let context = try await reopened.context(for: [probe], settings: .smart, now: start.addingTimeInterval(200))
        XCTAssertEqual(context.baselines[probe.signature.id]?.sampleCount, 30,
                       "closing persists what was learned after the last pass (\(unflushed) models were still queued)")
    }

    func testMaintenanceWaitsForTheFirstMinute() async throws {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        for tick in 0..<10 {
            let date = start.addingTimeInterval(Double(tick) * 5)
            _ = try await store.enqueue(model: model(at: date, count: 3), settings: .smart, now: date)
        }
        let health = await store.storeHealth()
        XCTAssertNil(health.lastPruneDate)
    }

    private func model(at date: Date, count: Int = 300) -> RadarModel {
        RadarModel(families: (0..<count).map { family($0, at: date) }, summary: .empty, incidents: [], rules: [],
                   health: .starting, generatedAt: date)
    }

    private func family(_ index: Int, at date: Date) -> ProcessFamily {
        let hot = index < 6
        let identity = ProcessIdentity(pid: Int32(20_000 + index), startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let memory: UInt64 = hot ? 3_000_000_000 : UInt64(40 + index % 50) * 1_048_576
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: "worker-\(index)",
                                  executablePath: "/usr/local/bin/worker-\(index)", commandLine: "worker-\(index) --serve",
                                  residentMemoryBytes: memory, physicalFootprintBytes: memory,
                                  virtualMemoryBytes: memory * 2, cpuPercent: 1, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: memory,
                             totalPhysicalFootprintBytes: memory, totalCPUPercent: 1,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: hot ? 80 : 3, level: hot ? .hot : .quiet, reasons: hot ? ["memory"] : []),
                             ownedIdentities: [identity], protectedPIDs: [], lastScoredAt: date)
    }
}
