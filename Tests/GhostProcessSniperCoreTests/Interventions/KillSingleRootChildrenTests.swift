import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Stopping one process does not stop its children, and they lose their
/// parent. The preview says so before Confirm, and the result checks which
/// of them are still running afterwards; nothing about them is signalled.
final class KillSingleRootChildrenTests: XCTestCase {
    private let host = KillProcessLite.fake(pid: 1500, name: "ext-host")
    private let analyzer = KillProcessLite.fake(pid: 1501, parent: 1500, name: "rust-analyzer")
    private let macros = KillProcessLite.fake(pid: 1502, parent: 1501, name: "proc-macro-srv")

    // MARK: - Preview

    func testPreviewNamesTheChildrenThatKeepRunning() async throws {
        let table = tree()

        let preview = await table.killer().preview(plan: singleRootPlan(), forceKillDelay: 2)

        XCTAssertEqual(preview.targetIdentities, [host.identity], "the stop itself is unchanged")
        XCTAssertEqual(preview.leftBehind.map(\.pid), [1501, 1502])
        XCTAssertTrue(preview.leftBehind.allSatisfy { $0.state == .locked })
        XCTAssertEqual(preview.leftBehind.first?.reason, "Not part of this stop; may keep running without its parent")
        XCTAssertTrue(preview.deniedPIDs.isEmpty, "they are not another user's, and do not feed the locked list")
        let hazard = try XCTUnwrap(preview.riskAssessment.hazards.first { $0.kind == .leavesChildren })
        XCTAssertEqual(hazard.title, "2 child processes are not stopped")
        XCTAssertEqual(hazard.severity, .info)
        XCTAssertTrue(hazard.detail.hasPrefix("rust-analyzer and proc-macro-srv lose their parent and may keep running"), hazard.detail)
        XCTAssertEqual(preview.readiness, .ready, "a note, not a reason to wait")
    }

    func testTheWholeFamilyStopHasNothingLeftBehind() async {
        let table = tree()
        let plan = KillPlan.fixture(host, members: [host, analyzer, macros])

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(Set(preview.targetPIDs), [1500, 1501, 1502])
        XCTAssertTrue(preview.leftBehind.isEmpty)
        XCTAssertFalse(preview.riskAssessment.hazards.contains { $0.kind == .leavesChildren })
    }

    func testAProcessWithoutChildrenGetsNoWarning() async {
        let table = tree()
        let plan = KillPlan.fixture(host, members: [host, analyzer, macros]).targetingOnly(macros.identity, name: "proc-macro-srv")

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.targetPIDs, [1502])
        XCTAssertTrue(preview.leftBehind.isEmpty)
        XCTAssertFalse(preview.riskAssessment.hazards.contains { $0.kind == .leavesChildren })
    }

    func testStoppingAFamilysRootAloneIsACautionButOneHelperIsNot() async throws {
        let table = tree()

        let root = await table.killer().preview(plan: singleRootPlan(childCount: 2), forceKillDelay: 2)
        let rootHazard = try XCTUnwrap(root.riskAssessment.hazards.first { $0.kind == .leavesChildren })
        XCTAssertEqual(rootHazard.severity, .caution, "every other process of the family is left behind")
        XCTAssertEqual(root.readiness, .caution)

        let helper = KillPlan.fixture(host, members: [host, analyzer, macros], familyChildCount: 2)
            .targetingOnly(analyzer.identity, name: "rust-analyzer")
        let inner = await table.killer().preview(plan: helper, forceKillDelay: 2)
        let innerHazard = try XCTUnwrap(inner.riskAssessment.hazards.first { $0.kind == .leavesChildren })
        XCTAssertEqual(innerHazard.title, "1 child process is not stopped")
        XCTAssertEqual(innerHazard.severity, .info)
        XCTAssertTrue(innerHazard.detail.hasPrefix("proc-macro-srv loses its parent and may keep running"), innerHazard.detail)
        XCTAssertEqual(inner.readiness, .ready)
    }

    func testAnAppThatIsAskedToQuitTakesItsHelpersWithIt() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 1520, name: "Slack")
        let helper = KillProcessLite.fake(pid: 1521, parent: 1520, name: "Slack Helper (Renderer)")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 1))
        table.add(helper, FakeProcessTable.Behaviour(exitsWithParent: true))
        let plan = KillPlan.fixture(app, members: [app, helper], paths: [1520: "/Applications/Slack.app/Contents/MacOS/Slack"])
            .targetingOnly(app.identity, name: "Slack")

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.strategyRecommendation.strategy, .quitApp)
        XCTAssertFalse(preview.riskAssessment.hazards.contains { $0.kind == .leavesChildren }, "quitting closes its helpers")
        XCTAssertEqual(preview.leftBehind.map(\.pid), [1521], "still checked afterwards")
        XCTAssertEqual(preview.leftBehind.first?.reason, "Not signalled; an app's helpers normally exit when it quits")

        let report = await table.killer().kill(plan: plan, forceKillDelay: 2)
        XCTAssertTrue(report.leftRunning.isEmpty, report.summary)
    }

    func testZombiesAndProtectedProcessesAreNotListed() async {
        let table = tree()
        table.add(.fake(pid: 1503, parent: 1500, name: "defunct", status: 5))
        table.add(.fake(pid: 1504, parent: 1500, name: "WindowServer"))

        let preview = await table.killer().preview(plan: singleRootPlan(), forceKillDelay: 2)

        XCTAssertEqual(preview.leftBehind.map(\.pid), [1501, 1502])
    }

    func testTheListIsCappedButTheWarningCountsEveryChild() async throws {
        let table = FakeProcessTable()
        table.add(host)
        for offset in 0..<40 {
            table.add(.fake(pid: 1600 + Int32(offset), parent: 1500, name: "worker"))
        }
        let members = table.listed
        let plan = KillPlan.fixture(host, members: members).targetingOnly(host.identity, name: "ext-host")

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.leftBehind.count, 32)
        let hazard = try XCTUnwrap(preview.riskAssessment.hazards.first { $0.kind == .leavesChildren })
        XCTAssertEqual(hazard.title, "40 child processes are not stopped")
        XCTAssertTrue(hazard.detail.hasPrefix("worker (40) lose their parent"), hazard.detail)
    }

    // MARK: - Result

    func testTheResultSaysWhichChildrenAreStillRunning() async {
        let table = tree()

        let report = await table.killer().kill(plan: singleRootPlan(), forceKillDelay: 2)

        XCTAssertEqual(Set(table.log.map(\.pid)), [1500], "only the process asked for is signalled")
        XCTAssertEqual(report.leftRunning.map(\.pid), [1501, 1502])
        XCTAssertEqual(report.leftRunning.map(\.reason), ["Left running (now orphaned)", "Left running (its parent is now orphaned)"])
        XCTAssertTrue(report.summary.contains("Left running (now orphaned): rust-analyzer (PID 1501), proc-macro-srv (PID 1502)."), report.summary)
        XCTAssertTrue(table.isListed(1501) && table.isListed(1502))
    }

    func testChildrenThatFollowTheirParentOutAreNotReported() async {
        let table = FakeProcessTable()
        table.add(host)
        table.add(analyzer, FakeProcessTable.Behaviour(exitsWithParent: true))
        table.add(macros, FakeProcessTable.Behaviour(exitsWithParent: true))

        let report = await table.killer().kill(plan: singleRootPlan(), forceKillDelay: 2)

        XCTAssertTrue(report.leftRunning.isEmpty)
        XCTAssertFalse(report.summary.contains("Left running"), report.summary)
    }

    func testAChildSlowToNoticeItsParentIsGoneIsNotReported() async {
        let table = FakeProcessTable()
        table.add(host)
        table.add(analyzer, FakeProcessTable.Behaviour(exitsAfterParent: 2))
        table.add(macros, FakeProcessTable.Behaviour(exitsWithParent: true))

        let report = await table.killer().kill(plan: singleRootPlan(), forceKillDelay: 2)

        XCTAssertTrue(report.leftRunning.isEmpty, "it was on its way out: \(report.summary)")
        XCTAssertFalse(table.isListed(1501))
    }

    func testAChildThatOutlastsTheShortWaitIsReported() async {
        let table = FakeProcessTable()
        table.add(host)
        table.add(analyzer, FakeProcessTable.Behaviour(exitsAfterParent: 50))
        table.add(macros, FakeProcessTable.Behaviour(exitsWithParent: true))

        let report = await table.killer().kill(plan: singleRootPlan(), forceKillDelay: 2)

        XCTAssertEqual(report.leftRunning.map(\.pid), [1501, 1502], "the child, and the helper that still has a parent")
        XCTAssertLessThan(table.elapsedSeconds, 5, "the wait for stragglers is short and bounded")
    }

    func testAChildThatExitedBeforeConfirmIsNotReported() async {
        let table = tree()
        let plan = singleRootPlan()
        let killer = table.killer()
        _ = await killer.preview(plan: plan, forceKillDelay: 2)
        // The grandchild exits between the preview and Confirm.
        try? table.send(signal: SIGKILL, to: 1502)

        let report = await killer.kill(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(report.leftRunning.map(\.pid), [1501], "what is left behind is read again when the stop runs")
    }

    // MARK: - Fixtures

    private func tree() -> FakeProcessTable {
        let table = FakeProcessTable()
        [host, analyzer, macros].forEach { table.add($0) }
        return table
    }

    private func singleRootPlan(childCount: Int? = nil) -> KillPlan {
        KillPlan.fixture(host, members: [host, analyzer, macros], familyChildCount: childCount)
            .targetingOnly(host.identity, name: "ext-host")
    }
}

private extension KillPlan {
    /// The same plan as a family the radar knows to have `familyChildCount`
    /// processes besides its root.
    static func fixture(_ root: KillProcessLite, members: [KillProcessLite], familyChildCount: Int?) -> KillPlan {
        let plan = fixture(root, members: members)
        guard let familyChildCount else { return plan }
        let metadata = KillFamilyMetadata(
            signatureID: "ext-host", displayName: root.name, scoreValue: 40, scoreLevel: .watch, forecastState: .quiet,
            devKindLabel: "Process family", memoryBytes: 0, cpuPercent: 0, childCount: familyChildCount
        )
        return KillPlan(rootIdentity: plan.rootIdentity, targetIdentities: plan.targetIdentities, protectedPIDs: [],
                        displayName: plan.displayName, familyMetadata: metadata, workload: plan.workload)
    }
}
