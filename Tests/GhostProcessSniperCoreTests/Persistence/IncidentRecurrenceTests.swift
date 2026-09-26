import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class IncidentRecurrenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-recurrence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testLiveIncidentIsNotItsOwnRecurrence() async throws {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        let hot = family(level: .hot, at: start)
        try await persist(hot, store: store, at: start)

        let during = try await store.context(for: [hot], settings: .smart, now: start.addingTimeInterval(3))
        XCTAssertEqual(during.recentIncidentCounts[hot.signature.id, default: 0], 0,
                       "the first episode must not count itself as a recurrence")

        // Episodes close after 90 s of calm and reopen within 10 minutes, so
        // a separate episode needs a longer gap.
        try await persist(family(level: .quiet, at: start.addingTimeInterval(100)), store: store, at: start.addingTimeInterval(100))
        let again = family(level: .hot, at: start.addingTimeInterval(1_200))
        try await persist(again, store: store, at: start.addingTimeInterval(1_200))

        let second = try await store.context(for: [again], settings: .smart, now: start.addingTimeInterval(1_203))
        XCTAssertEqual(second.recentIncidentCounts[again.signature.id], 1)
    }

    private func persist(_ family: ProcessFamily, store: RadarStore, at date: Date) async throws {
        let model = RadarModel(families: [family], summary: .empty, incidents: [], rules: [], health: .starting, generatedAt: date)
        _ = try await store.enqueue(model: model, settings: .smart, now: date)
        try await store.flush(now: date)
    }

    private func family(level: GhostLevel, at date: Date) -> ProcessFamily {
        let identity = ProcessIdentity(pid: 730, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let memory: UInt64 = level >= .hot ? 3_000_000_000 : 40_000_000
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: "node",
                                  executablePath: "/usr/local/bin/node", commandLine: "node server.js",
                                  residentMemoryBytes: memory, physicalFootprintBytes: memory,
                                  virtualMemoryBytes: memory * 2, cpuPercent: 0, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        let score = GhostScore(value: level >= .hot ? 80 : 5, level: level, reasons: level >= .hot ? ["memory"] : [])
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: memory,
                             totalPhysicalFootprintBytes: memory, totalCPUPercent: 0,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: score, ownedIdentities: [identity], protectedPIDs: [], lastScoredAt: date)
    }
}
