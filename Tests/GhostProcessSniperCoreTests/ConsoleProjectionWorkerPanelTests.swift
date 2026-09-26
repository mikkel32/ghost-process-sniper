import Foundation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class ConsoleProjectionWorkerPanelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)

    func testUnpreparedFamilyGetsAPanelWithItsStopRisk() async throws {
        let (families, processes) = sample()
        let quiet = families[1]
        let request = request(families: families, processes: processes)
        XCTAssertNil(request.source.detailPanel(for: quiet.familyKey), "the quiet family must not be prepared")

        let worker = ConsoleProjectionWorker()
        let panel = try await worker.panel(familyKey: quiet.familyKey, request: request)
        XCTAssertEqual(panel?.familyKey, quiet.familyKey)
        let expected = KillRiskAssessor().assess(KillWorkloadProfile(family: quiet, sample: processes))
        XCTAssertEqual(panel?.stopRisk, expected)
        XCTAssertEqual(panel?.stopRisk?.supervisor?.name, "nodemon")

        let again = try await worker.panel(familyKey: quiet.familyKey, request: request)
        XCTAssertEqual(again, panel)
        let builds = await worker.panelBuildCount
        XCTAssertEqual(builds, 1, "the same family and revisions must be a cache hit")
    }

    func testPreparedPanelsCarryTheirStopRisk() {
        let (families, processes) = sample()
        let hot = families[0]
        let snapshot = request(families: families, processes: processes).source
        let expected = KillRiskAssessor().assess(KillWorkloadProfile(family: hot, sample: processes))
        XCTAssertEqual(snapshot.detailPanel(for: hot.familyKey)?.stopRisk, expected)
    }

    /// The panel's risk covers the real stop set, like the monitor's memo:
    /// a database another family owns, started under an unchanged runner,
    /// changes it even though the runner's members did not.
    func testForeignDescendantUnderAnUnchangedFamilyChangesThePanelRisk() {
        for level in [GhostLevel.hot, .quiet] {
            let runner = family(pid: 900, parent: 1, name: "node", level: level, command: "node /usr/local/bin/foreman start")
            // The radar gives postgres a family of its own.
            let database = family(pid: 901, parent: runner.root.pid, name: "postgres", level: .quiet,
                                  command: KillFixture.postgresCommand)
            let postgres = database.root
            let before = request(families: [runner], processes: [runner.root])
            let after = request(families: [runner, database], processes: [runner.root, postgres], previous: before.source)

            let first = ConsoleProjectionWorker.buildPanel(familyKey: runner.familyKey, request: before)
            let second = ConsoleProjectionWorker.buildPanel(familyKey: runner.familyKey, request: after, reusing: first)
            let expected = KillRiskAssessor().assess(KillWorkloadProfile(family: runner, sample: [runner.root, postgres]))

            XCTAssertNotEqual(first?.stopRisk?.kind, .dataStore, "level \(level)")
            XCTAssertEqual(expected.kind, .dataStore)
            XCTAssertEqual(second?.stopRisk, expected, "level \(level)")

            // And back: once the database exits, the reused panel drops it.
            let gone = request(families: [runner], processes: [runner.root], previous: after.source)
            let third = ConsoleProjectionWorker.buildPanel(familyKey: runner.familyKey, request: gone, reusing: second)
            XCTAssertEqual(third?.stopRisk, first?.stopRisk, "level \(level)")
            XCTAssertNil(third?.stopBlockedReason)
        }
    }

    func testStaleSelectionDoesNotPublish() async throws {
        let (families, processes) = sample()
        let request = request(families: families, processes: processes)
        let projector = GatedPanelProjector(gatedKey: families[0].familyKey)
        let store = ConsoleQueryStore(projector: projector)

        let stale = Task { await store.updatePanel(familyKey: families[0].familyKey, request: request) }
        for _ in 0..<2_000 {
            if await projector.isWaiting { break }
            await Task.yield()
        }
        let fresh = await store.updatePanel(familyKey: families[1].familyKey, request: request)
        XCTAssertTrue(fresh)
        await projector.release()
        let published = await stale.value
        XCTAssertFalse(published, "an older selection must not replace a newer one")
        XCTAssertEqual(store.selectedPanel?.familyKey, families[1].familyKey)
    }

    func testChangeComesFromTheTrendAndNeverWarmsWithHistory() {
        let samples = [
            TrendSample(date: now, memoryBytes: 100 * 1_048_576, cpuPercent: 10),
            TrendSample(date: now.addingTimeInterval(20), memoryBytes: 150 * 1_048_576, cpuPercent: 12),
            TrendSample(date: now.addingTimeInterval(40), memoryBytes: 400 * 1_048_576, cpuPercent: 30)
        ]
        let family = family(pid: 700, parent: 1, name: "node", level: .quiet, samples: samples)
        let panel = FamilyDetailPanelModel(family: family)
        XCTAssertNotEqual(panel.change, .warming)
        XCTAssertEqual(panel.change.memoryDeltaBytes, 300 * 1_048_576, "compares with the newest sample at least 30 s older")
        XCTAssertEqual(panel.change.level, .hot)
        XCTAssertTrue(panel.change.summary.hasSuffix("in the last 40 s"), panel.change.summary)

        let short = FamilyDetailPanelModel(family: self.family(pid: 701, parent: 1, name: "node", level: .quiet,
                                                               samples: Array(samples.prefix(2))))
        XCTAssertNotEqual(short.change, .warming)
        XCTAssertEqual(FamilyDetailPanelModel(family: self.family(pid: 702, parent: 1, name: "node", level: .quiet,
                                                                  samples: Array(samples.prefix(1)))).change, .warming)
    }

    // MARK: - Fixtures

    private func sample() -> (families: [ProcessFamily], processes: [ProcessMetrics]) {
        let supervisor = process(pid: 800, parent: 1, name: "nodemon", command: "node /usr/local/bin/nodemon server.js")
        let hot = family(pid: 810, parent: 1, name: "postgres", level: .hot)
        let quiet = family(pid: 820, parent: supervisor.pid, name: "node", level: .quiet)
        return ([hot, quiet], [supervisor, hot.root, quiet.root])
    }

    private func request(families: [ProcessFamily], processes: [ProcessMetrics],
                         previous: RadarConsoleSnapshot? = nil) -> ConsoleProjectionRequest {
        let snapshot = RadarConsoleSnapshot.build(
            families: families, summary: .empty, incidents: [], rules: [], metrics: .empty,
            health: .starting, storeHealth: .empty, storeError: nil, previous: previous,
            generatedAt: now, detailSignatures: [], processes: processes
        )
        return ConsoleProjectionRequest(source: snapshot, incidents: [], state: .default,
                                        families: families, processes: processes, sampleRevision: 3)
    }

    private func process(pid: Int32, parent: Int32, name: String, command: String? = nil) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
                       parentPID: parent, userID: 501, ownerName: "test", name: name,
                       executablePath: "/usr/local/bin/\(name)", commandLine: command ?? "\(name) --serve",
                       residentMemoryBytes: 64_000_000, physicalFootprintBytes: 64_000_000,
                       virtualMemoryBytes: 128_000_000, cpuPercent: 1, totalProcessorSeconds: 10,
                       threadCount: 2, isSystemProcess: false, sampledAt: now)
    }

    private func family(pid: Int32, parent: Int32, name: String, level: GhostLevel, samples: [TrendSample] = [],
                        command: String? = nil) -> ProcessFamily {
        let root = process(pid: pid, parent: parent, name: name, command: command)
        let trend = TrendMetrics(memoryVelocityMegabytesPerMinute: 0, cpuSlopePerMinute: 0,
                                 memoryPoints: samples.map { Double($0.memoryBytes) }, samples: samples)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                             totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: 1,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: trend,
                             score: GhostScore(value: level >= .hot ? 80 : 5, level: level, reasons: []),
                             ownedIdentities: [root.identity], protectedPIDs: [], lastScoredAt: now)
    }
}

/// Holds the first panel request for `gatedKey` until released.
private actor GatedPanelProjector: ConsoleProjecting {
    private let gatedKey: String
    private var continuation: CheckedContinuation<Void, Never>?
    private var gated = false
    var isWaiting: Bool { continuation != nil }

    init(gatedKey: String) {
        self.gatedKey = gatedKey
    }

    func project(_ request: ConsoleProjectionRequest) async throws -> ConsoleDerivedSnapshot {
        ConsoleDerivedSnapshot.build(snapshot: request.source, incidents: request.incidents, state: request.state)
    }

    func panel(familyKey: String, request: ConsoleProjectionRequest) async throws -> FamilyDetailPanelModel? {
        if familyKey == gatedKey, !gated {
            gated = true
            await withCheckedContinuation { continuation = $0 }
        }
        return ConsoleProjectionWorker.buildPanel(familyKey: familyKey, request: request)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
