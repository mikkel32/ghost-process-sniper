import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// What a confirmed preview covers: the processes it showed, plus children
/// they start before the stop runs. Nothing older, and nothing unrelated.
final class KillApprovalScopeTests: XCTestCase {
    private let approvedAt = Date(timeIntervalSince1970: 1_000_000)
    private let afterApproval: UInt64 = 1_000_050

    func testChildrenStartedAfterPreviewStopWithTheirParent() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1400, name: "runner")
        let workers = (1401...1403).map { KillProcessLite.fake(pid: Int32($0), parent: 1400, name: "worker", start: afterApproval) }
        table.add(root)
        workers.forEach { table.add($0) }
        let plan = KillPlan.fixture(root).binding(to: [root.identity], expiresAt: .distantFuture, approvedAt: approvedAt)
        let killer = table.killer()

        let preview = await killer.preview(plan: plan, forceKillDelay: 2)
        let report = await killer.kill(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(Set(preview.targetPIDs), [1400, 1401, 1402, 1403])
        XCTAssertTrue(preview.targets.filter { $0.pid != 1400 }.allSatisfy { $0.reason == "Started after the preview by runner (PID 1400)" })
        XCTAssertNotEqual(report.strategyUsed, .inspectOnly)
        XCTAssertEqual(Set(table.log.map(\.pid)), [1400, 1401, 1402, 1403])
        XCTAssertEqual(report.targetDiff.addedPIDs, [1401, 1402, 1403])
        XCTAssertTrue(report.succeeded, report.summary)
        XCTAssertTrue(table.listed.isEmpty)
    }

    func testForeignHelpersNeverLockAnOwnedRoot() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1410, name: "runner")
        let helpers = (1411...1413).map { KillProcessLite.fake(pid: Int32($0), parent: 1410, name: "helper", userID: 0) }
        table.add(root)
        helpers.forEach { table.add($0) }
        let killer = table.killer()

        let preview = await killer.preview(plan: .fixture(root), forceKillDelay: 2)
        let report = await killer.kill(plan: .fixture(root), forceKillDelay: 2)

        XCTAssertNotEqual(preview.strategyRecommendation.strategy, .inspectOnly)
        XCTAssertTrue(preview.canKill)
        let factor = preview.decisionScore.factors.first { $0.title == "Protected descendants" }
        XCTAssertEqual(factor?.detail, "3 processes owned by other users stay running.")
        XCTAssertEqual(factor?.weight, -12)
        XCTAssertEqual(table.log.map(\.pid), [1410])
        XCTAssertEqual(report.deniedPIDs, [1411, 1412, 1413])
    }

    func testLockedRootIsInspectOnly() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1415, name: "daemon", userID: 0)
        let child = KillProcessLite.fake(pid: 1416, parent: 1415, name: "worker")
        table.add(root)
        table.add(child)

        let preview = await table.killer().preview(plan: .fixture(root), forceKillDelay: 2)

        XCTAssertEqual(preview.strategyRecommendation.strategy, .inspectOnly)
    }

    func testUnrelatedNewProcessIsNotAdopted() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1420, name: "runner")
        let old = KillProcessLite.fake(pid: 1421, parent: 1420, name: "watcher")
        let underOld = KillProcessLite.fake(pid: 1422, parent: 1421, name: "worker", start: afterApproval)
        let stranger = KillProcessLite.fake(pid: 1423, parent: 1, name: "worker", start: afterApproval)
        [root, old, underOld, stranger].forEach { table.add($0) }
        let plan = KillPlan.fixture(root).binding(to: [root.identity], expiresAt: .distantFuture, approvedAt: approvedAt)

        let report = await table.killer().kill(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(table.log.map(\.pid), [1420], "a child of a process left out of the preview stays out")
        XCTAssertTrue(report.targetResults.contains { $0.pid == 1422 && $0.state == .locked })
        XCTAssertFalse(report.targetResults.contains { $0.pid == 1423 })
    }

    func testOrphansAreReported() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1430, name: "runner")
        let old = KillProcessLite.fake(pid: 1431, parent: 1430, name: "watcher")
        table.add(root)
        table.add(old, .ignoresTermination)
        let plan = KillPlan.fixture(root).binding(to: [root.identity], expiresAt: .distantFuture, approvedAt: approvedAt)

        let report = await table.killer().kill(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(report.leftRunning.map(\.pid), [1431])
        XCTAssertEqual(report.leftRunning.first?.reason, "Left running (now orphaned)")
        XCTAssertTrue(report.summary.contains("Left running (now orphaned): watcher (PID 1431)."), report.summary)
        XCTAssertTrue(table.signals(to: 1431).isEmpty)
    }
}
