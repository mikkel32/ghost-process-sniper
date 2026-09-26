import Darwin
import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

/// Kill history informs the next stop but never locks the user out, and
/// only real refusals and real survivors count against a family.
final class InterventionPolicyHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let family = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(3))
        .enriched(classification: DevClassification(kind: .nodeServer, confidence: 1, reason: "test"))

    func testOneHeldSurvivorDoesNotLockFutureStops() async throws {
        let store = try RadarStore(url: storeURL())
        var held = report(survivors: [40_003])
        held.skipForceRequested = true
        try await store.recordKillOperation(report: held, family: family, at: now)
        let history = try await store.killStrategyHistory(signatureID: family.signature.id, now: now)
        XCTAssertEqual(history.operationCount, 1)
        XCTAssertEqual(history.survivorRate, 0, "the user chose to keep it running")

        let raw = KillHistorySummary(signatureID: "sig", operationCount: 1, gracefulSuccessRate: 0, forceRate: 0,
                                     survivorRate: 1, averageReclaimBytes: 0, commonDenialCount: 0)
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", history: raw)
        XCTAssertNotEqual(evaluation.recommendation.strategy, .inspectOnly)
        XCTAssertFalse(evaluation.decisionScore.factors.contains { $0.kind == .blocking })
        XCTAssertEqual(evaluation.decisionScore.readiness(hasTargets: true), .ready)
    }

    func testForeignChildrenAreNotDenials() async throws {
        let store = try RadarStore(url: storeURL())
        for offset in 0..<2 {
            var stop = report()
            stop.deniedPIDs = [90_001, 90_002]
            try await store.recordKillOperation(report: stop, family: family, at: now.addingTimeInterval(Double(offset)))
        }
        var refused = report()
        refused.deniedPIDs = [90_003]
        refused.signalDeniedPIDs = [90_003]
        try await store.recordKillOperation(report: refused, family: family, at: now.addingTimeInterval(3))
        let history = try await store.killStrategyHistory(signatureID: family.signature.id, now: now.addingTimeInterval(4))
        XCTAssertEqual(history.operationCount, 3)
        XCTAssertEqual(history.commonDenialCount, 1, "only the kernel's EPERM is a denial")
    }

    func testKernelRefusalIsTheOnlySignalDenial() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 730, name: "cruncher")
        let refusing = KillProcessLite.fake(pid: 731, parent: 730, name: "helper")
        let foreign = KillProcessLite.fake(pid: 732, parent: 730, name: "root-helper", userID: 0)
        table.add(root)
        table.add(refusing, FakeProcessTable.Behaviour(deniesSignals: true))
        table.add(foreign)
        let plan = KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity, refusing.identity], protectedPIDs: [],
                            displayName: "cruncher")
        let killer = ProcessKiller(snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper)
        let report = await killer.kill(plan: plan, forceKillDelay: 0.05)
        XCTAssertEqual(report.signalDeniedPIDs, [731])
        XCTAssertTrue(report.deniedPIDs.contains(732), "the preflight locked the foreign child")
    }

    func testThreeRealSurvivorsWarnButDoNotBlock() {
        let history = KillHistorySummary(signatureID: "sig", operationCount: 3, gracefulSuccessRate: 0, forceRate: 0,
                                         survivorRate: 1, averageReclaimBytes: 0, commonDenialCount: 5)
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", history: history)
        let warning = evaluation.decisionScore.factors.first { $0.title == "Past stops left something running" }
        XCTAssertEqual(warning?.kind, .whyWait)
        XCTAssertEqual(warning?.detail, "3 of the last 3 stops left a process running.")
        XCTAssertEqual(warning?.weight, -12)
        XCTAssertEqual(warning?.source, .history)
        XCTAssertNotEqual(evaluation.recommendation.strategy, .inspectOnly)
        XCTAssertEqual(evaluation.decisionScore.readiness(hasTargets: true), .caution)
    }

    func testFewStopsSayNothingYet() {
        let history = KillHistorySummary(signatureID: "sig", operationCount: 2, gracefulSuccessRate: 0, forceRate: 1,
                                         survivorRate: 0.5, averageReclaimBytes: 0, commonDenialCount: 3)
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", history: history)
        XCTAssertTrue(evaluation.decisionScore.whyWait.filter { $0.source == .history }.isEmpty)
        XCTAssertNotEqual(evaluation.recommendation.strategy, .inspectOnly)
    }

    func testStopsThatSentNothingAreNotLearned() async throws {
        let store = try RadarStore(url: storeURL())
        let expired = KillReport(displayName: "tool", rootPID: 40_003, failures: ["This preview expired."])
        try await store.recordKillOperation(report: expired, family: family, at: now)
        let history = try await store.killStrategyHistory(signatureID: family.signature.id, now: now)
        XCTAssertEqual(history.operationCount, 0)
        let operations = try await store.recentKillOperations()
        XCTAssertEqual(operations.count, 1, "the audit trail keeps it")
    }

    func testHistoryIsTheFamilysLatestTwentyWithinThirtyDays() async throws {
        let store = try RadarStore(url: storeURL())
        let day: TimeInterval = 24 * 60 * 60
        try await store.recordKillOperation(report: report(forced: [40_003]), family: family, at: now.addingTimeInterval(-40 * day))
        for index in 0..<25 {
            let stop = index < 5 ? report(forced: [40_003]) : report()
            try await store.recordKillOperation(report: stop, family: family, at: now.addingTimeInterval(-Double(25 - index) * 60))
        }
        let history = try await store.killStrategyHistory(signatureID: family.signature.id, now: now)
        XCTAssertEqual(history.operationCount, 20)
        XCTAssertEqual(history.forceRate, 0, "the old forced stops fell out of the window")

        let other = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(9))
            .enriched(classification: DevClassification(kind: .nodeServer, confidence: 1, reason: "test"))
        XCTAssertNotEqual(other.signature.id, family.signature.id)
        let unrelated = try await store.killStrategyHistory(signatureID: other.signature.id, now: now)
        XCTAssertEqual(unrelated.operationCount, 0, "another family of the same kind shares nothing")
    }

    func testOlderStoresDropTheirPoisonedLearning() async throws {
        let url = storeURL()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let legacy = """
        CREATE TABLE kill_strategy_history(id TEXT PRIMARY KEY NOT NULL, operation_id TEXT NOT NULL, signature_id TEXT,
          dev_kind TEXT, strategy TEXT NOT NULL, scope TEXT NOT NULL, graceful_count INTEGER NOT NULL,
          forced_count INTEGER NOT NULL, survivor_count INTEGER NOT NULL, locked_count INTEGER NOT NULL,
          realized_memory_bytes INTEGER NOT NULL, denial_count INTEGER NOT NULL, created_at REAL NOT NULL);
        INSERT INTO kill_strategy_history VALUES('old', 'op', '\(family.signature.id)', NULL, 'standard', 'ownedFamily',
          0, 0, 1, 2, 0, 2, \(now.timeIntervalSince1970));
        """
        XCTAssertEqual(sqlite3_exec(handle, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let store = try RadarStore(url: url)
        let history = try await store.killStrategyHistory(signatureID: family.signature.id, now: now)
        XCTAssertEqual(history.operationCount, 0, "fake survivors from older builds are discarded")
        try await store.recordKillOperation(report: report(), family: family, at: now)
        let reopened = try RadarStore(url: url)
        let kept = try await reopened.killStrategyHistory(signatureID: family.signature.id, now: now)
        XCTAssertEqual(kept.operationCount, 1, "the rebuild runs once")
    }

    // MARK: - Fixtures

    private func report(survivors: [Int32] = [], forced: [Int32] = []) -> KillReport {
        KillReport(
            displayName: "tool",
            rootPID: 40_003,
            gracefulPIDs: [40_003],
            forcedPIDs: forced,
            survivorPIDs: survivors,
            attempts: [KillAttempt(pid: 40_003, signal: SIGTERM, stage: "graceful", succeeded: true)]
        )
    }

    private func storeURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kill-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("radar.sqlite")
    }
}
