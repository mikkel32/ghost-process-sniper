import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class IncidentHistoryLoadTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testTheMonitorReadsTheWholeLogFromItsStore() async throws {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        for index in 0..<90 {
            let date = start.addingTimeInterval(Double(index) * 1_200)
            let model = RadarModel(families: [hotFamily(name: "job-\(index)", at: date)], summary: .empty, incidents: [], rules: [],
                                   health: .starting, generatedAt: date)
            _ = try await store.enqueue(model: model, settings: .smart, now: date)
            try await store.flush(now: date)
        }
        let monitor = ProcessMonitor(store: store, battery: nil, sleepAssertions: nil)

        let loaded = await monitor.loadIncidentHistory()
        let history = try XCTUnwrap(loaded)
        XCTAssertEqual(history.incidents.count, 90, "the published list stops at 80; the log does not")
        XCTAssertFalse(history.isTruncated)
    }

    @MainActor
    func testWithoutAStoreThereIsNoHistory() async {
        let monitor = ProcessMonitor(store: nil, battery: nil, sleepAssertions: nil)
        let history = await monitor.loadIncidentHistory()
        XCTAssertNil(history)
    }

    private func hotFamily(name: String, at date: Date) -> ProcessFamily {
        let identity = ProcessIdentity(pid: 731, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: name,
                                  executablePath: "/usr/local/bin/\(name)", commandLine: "\(name) run",
                                  residentMemoryBytes: 3_000_000_000, physicalFootprintBytes: 3_000_000_000,
                                  virtualMemoryBytes: 6_000_000_000, cpuPercent: 0, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: 3_000_000_000,
                             totalPhysicalFootprintBytes: 3_000_000_000, totalCPUPercent: 0,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: 80, level: .hot, reasons: ["memory"]), ownedIdentities: [identity],
                             protectedPIDs: [], lastScoredAt: date)
    }
}
