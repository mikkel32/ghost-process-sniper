import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class PresentationPipelineTests: XCTestCase {
    func testScopedDetailsKeepEveryProcessRow() {
        let families = (0..<300).map { family($0) }
        let requested = families[299].familyKey
        let scoped = payload(families, keys: [requested])
        XCTAssertEqual(scoped.state.consoleSnapshot.families.count, 300)
        XCTAssertNotNil(scoped.state.detailViewModels[requested])
        XCTAssertLessThanOrEqual(scoped.state.consoleSnapshot.detailPanels.count, 30)
        let full = payload(families, keys: nil)
        XCTAssertEqual(full.state.consoleSnapshot.families, scoped.state.consoleSnapshot.families)
        XCTAssertEqual(full.state.consoleSnapshot.detailPanels[requested], scoped.state.consoleSnapshot.detailPanels[requested])
    }

    func testEqualMetricRowsKeepTheirOrderWhenSamplingOrderChanges() {
        let families = (0..<40).map { family($0, sharedSignature: true) }
        let forward = payload(families, keys: []).state.consoleSnapshot
        let reverse = payload(Array(families.reversed()), keys: []).state.consoleSnapshot
        for sort in RadarSort.allCases {
            let a = forward.families(query: "", filter: .all, sort: sort).map(\.id)
            let b = reverse.families(query: "", filter: .all, sort: sort).map(\.id)
            XCTAssertEqual(a, b, "Equal-ranked rows reshuffled in \(sort)")
        }
    }

    func testNewSelectionMaterializesWithoutResourceChange() {
        let families = [family(0), family(1)]
        let first = payload(families, keys: [families[0].familyKey])
        let next = payload(families, keys: [families[1].familyKey], previous: first.state.consoleSnapshot)
        XCTAssertEqual(first.state.consoleSnapshot.contentRevision, next.state.consoleSnapshot.contentRevision)
        XCTAssertEqual(next.delta.mode, .contentChanged)
        XCTAssertNotNil(next.state.detailViewModels[families[1].familyKey])
    }

    func testRepeatedSignatureDoesNotExpandDetailDemandToAllInstances() {
        let families = (0..<200).map { family($0, sharedSignature: true) }
        let result = payload(families, keys: [families[0].signature.id, families[199].familyKey])
        XCTAssertNotNil(result.state.detailViewModels[families[199].familyKey])
        XCTAssertLessThanOrEqual(result.state.consoleSnapshot.detailPanels.count, 4)
        XCTAssertEqual(result.state.consoleSnapshot.families.count, 200)
    }

    func testUnchangedRenderingStillPublishesFreshRawMeasurements() {
        let first = family(0)
        let monitor = ProcessMonitor(builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        monitor.ingest([first.root], now: first.root.sampledAt)
        let revision = monitor.consoleSnapshot.contentRevision
        let fresh = family(0, at: first.root.sampledAt.addingTimeInterval(1))
        monitor.ingest([fresh.root], now: fresh.root.sampledAt)
        XCTAssertEqual(monitor.consoleSnapshot.contentRevision, revision)
        XCTAssertEqual(monitor.families.first?.root.sampledAt, fresh.root.sampledAt)
    }

    func testLateQueryCannotOverwriteTheLatestResult() async throws {
        let worker = ControlledProjector()
        let store = ConsoleQueryStore(projector: worker)
        let old = Task { await store.update(request("old")) }
        try await waitForOld(worker)
        let accepted = await store.update(request("new"))
        XCTAssertTrue(accepted)
        await worker.releaseOld()
        let staleAccepted = await old.value
        XCTAssertFalse(staleAccepted)
        XCTAssertEqual(store.snapshot.key.searchText, "new")
        XCTAssertFalse(store.isUpdating)
    }

    func testCancelledQueryDoesNotPublishOrLeaveLoadingStuck() async throws {
        let worker = ControlledProjector()
        let store = ConsoleQueryStore(projector: worker)
        let pending = Task { await store.update(request("old")) }
        try await waitForOld(worker)
        pending.cancel()
        await worker.releaseOld()
        let accepted = await pending.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(store.isUpdating)
        XCTAssertNil(store.errorMessage)
    }

    func testClosingPresentationInvalidatesInFlightWork() async throws {
        let worker = ControlledProjector()
        let store = ConsoleQueryStore(projector: worker)
        let pending = Task { await store.update(request("old")) }
        try await waitForOld(worker)
        store.cancel()
        await worker.releaseOld()
        let accepted = await pending.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(store.isUpdating)
        XCTAssertEqual(store.snapshot, .empty)
    }

    func testDefaultProjectionMatchesSynchronousOracle() async throws {
        let source = payload((0..<40).map { family($0) }, keys: nil).state.consoleSnapshot
        let worker = ConsoleProjectionWorker()
        for filter in RadarFilter.allCases {
            var state = RadarConsoleState.default
            state.familyFilter = filter
            state.familySort = .memory
            state.searchText = "worker-1"
            let request = ConsoleProjectionRequest(source: source, incidents: [], state: state)
            let result = try await worker.project(request)
            let expected = ConsoleDerivedSnapshot.build(snapshot: source, incidents: [], state: state)
            XCTAssertEqual(result.familyRows, expected.familyRows)
            XCTAssertEqual(result.compactSidebarSections, expected.compactSidebarSections)
        }
    }

    func testRecurrenceQueryUsesCoveringIndexWithoutChangingBoundaryCounts() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in RadarStoreSchema.migrationStatements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
        for (id, time) in [(1, 99), (2, 100), (3, 101)] {
            let sql = "INSERT INTO incidents VALUES('\(id)', 'test', 'worker', '/test', 'hash', 'worker', 'Watch', 0, 0, 0, 0, '[]', \(time), \(time), NULL, 1)"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        let sql = "SELECT signature_id, COUNT(*) FROM incidents WHERE signature_id IN ('test') AND started_at >= 100 GROUP BY signature_id"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 1), 2)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let text = try XCTUnwrap(sqlite3_column_text(statement, 3))
        XCTAssertTrue(String(cString: text).contains("COVERING INDEX incidents_signature_started"))
        sqlite3_finalize(statement)
    }

    private func request(_ query: String) -> ConsoleProjectionRequest {
        var state = RadarConsoleState.default
        state.searchText = query
        return ConsoleProjectionRequest(source: .empty, incidents: [], state: state)
    }

    private func waitForOld(_ worker: ControlledProjector) async throws {
        for _ in 0..<2000 {
            if await worker.isWaiting { return }
            await Task.yield()
        }
        throw NSError(domain: "PresentationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Projection did not start"])
    }

    private func family(_ index: Int, sharedSignature: Bool = false, at date: Date = Date(timeIntervalSince1970: 10_000)) -> ProcessFamily {
        let name = sharedSignature ? "node" : "worker-\(index)"
        let identity = ProcessIdentity(pid: Int32(50_000 + index), startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: name,
                                  executablePath: "/usr/local/bin/\(name)", commandLine: "\(name) server.js",
                                  residentMemoryBytes: 32_000_000, physicalFootprintBytes: 32_000_000,
                                  virtualMemoryBytes: 64_000_000, cpuPercent: 0, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                             totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: 0,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: 0, level: .quiet, reasons: []),
                             ownedIdentities: [identity], protectedPIDs: [], lastScoredAt: date)
    }

    private func payload(_ families: [ProcessFamily], keys: Set<String>?, previous: RadarConsoleSnapshot? = nil) -> RadarPublishPayload {
        let summary = ProcessFamilyBuilder(currentUserID: 501).summary(for: families)
        return RadarPublishPayload.build(families: families, summary: summary, rules: [], incidents: [],
                                         health: .starting, storeHealth: .empty, storeError: nil,
                                         performance: .empty, previous: previous,
                                         generatedAt: Date(timeIntervalSince1970: 10_000), detailSignatures: keys)
    }
}

private actor ControlledProjector: ConsoleProjecting {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func project(_ request: ConsoleProjectionRequest) async throws -> ConsoleDerivedSnapshot {
        if request.state.searchText == "old" {
            await withCheckedContinuation { continuation = $0 }
        }
        // Deliberately ignores cancellation to exercise publication safeguards.
        return ConsoleDerivedSnapshot.build(snapshot: request.source, incidents: request.incidents, state: request.state)
    }

    func releaseOld() { continuation?.resume(); continuation = nil }
}
