import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A "still open" result describes the moment the stop ended. Once the app
/// has quit, it must say so, and only then; looking again never signals.
final class KillSettlingTests: XCTestCase {
    // MARK: - The report

    func testAnAppThatQuitAfterTheStopSettlesTheResult() throws {
        let app = target(300, "Pages", root: true)
        let report = openApp(app)
        XCTAssertFalse(report.succeeded)

        let settled = report.settling(exited: [app.identity])

        XCTAssertTrue(settled.survivorPIDs.isEmpty)
        XCTAssertFalse(settled.appStillOpen)
        XCTAssertTrue(settled.succeeded)
        XCTAssertEqual(settled.exitedAfterStopPIDs, [300])
        let row = try XCTUnwrap(KillOutcomeRows.make(report: settled).first)
        XCTAssertEqual(row.state, .terminated)
        XCTAssertEqual(row.reason, "Closed after the stop")
        XCTAssertTrue(settled.narrative.headline.hasPrefix("Stopped Pages"), settled.narrative.headline)
        XCTAssertNil(settled.nextStep)
        XCTAssertNotNil(settled.cleanStopToastText, "closing the sheet now behaves as after a clean stop")
        XCTAssertNil(KillPlan.fixture(KillProcessLite.fake(pid: 300, name: "Pages")).forcingSurvivors(of: settled), "nothing is left to force")
        XCTAssertTrue(settled.diagnosticText.contains("Exited after the stop: 300"), settled.diagnosticText)
    }

    func testAnotherIdentityChangesNothing() {
        let app = target(300, "Pages", root: true)
        let report = openApp(app)
        let reused = ProcessIdentity(pid: 300, startTimeSeconds: 2_000, startTimeMicroseconds: 0)
        let stranger = ProcessIdentity(pid: 999, startTimeSeconds: 1_000, startTimeMicroseconds: 0)

        XCTAssertEqual(report.settling(exited: [reused]), report, "a reused PID is not the app")
        XCTAssertEqual(report.settling(exited: [stranger]), report)
        XCTAssertEqual(report.settling(exited: []), report)
        XCTAssertTrue(report.narrative.headline.contains("is still open"), report.narrative.headline)
    }

    func testHelpersThatOutliveTheAppStayListed() {
        let app = target(300, "Pages", root: true)
        let helper = target(301, "Pages Helper")
        let report = openApp(app, helpers: [helper])
        XCTAssertTrue(report.notes.contains(KillReport.helpersLeftAloneNote(app: "Pages")))

        let settled = report.settling(exited: [app.identity])

        XCTAssertEqual(settled.survivorPIDs, [301])
        XCTAssertFalse(settled.appStillOpen, "the app is no longer the thing to answer")
        XCTAssertFalse(settled.notes.contains(KillReport.helpersLeftAloneNote(app: "Pages")), "nothing is answering any more")
        XCTAssertFalse(settled.succeeded)
        XCTAssertTrue(settled.narrative.headline.contains("Pages Helper (PID 301) is still running"), settled.narrative.headline)
    }

    func testAHelperThatExitsFirstLeavesTheAppOpen() {
        let app = target(300, "Pages", root: true)
        let helper = target(301, "Pages Helper")
        let report = openApp(app, helpers: [helper])

        let settled = report.settling(exited: [helper.identity])

        XCTAssertEqual(settled.survivorPIDs, [300])
        XCTAssertTrue(settled.appStillOpen)
        XCTAssertTrue(settled.notes.contains(KillReport.helpersLeftAloneNote(app: "Pages")), "the app still answers")
        XCTAssertTrue(settled.narrative.headline.contains("Pages is still open"), settled.narrative.headline)
    }

    func testTheFreedMemoryGrowsByWhatClosedAndStaysWithinTheEstimate() {
        let app = target(300, "Pages", root: true, memory: 400)
        let helper = target(301, "Pages Helper", memory: 200)
        var report = openApp(app, helpers: [helper])
        report.estimatedMemoryReclaimBytes = 500

        XCTAssertEqual(report.settling(exited: [helper.identity]).realizedMemoryReclaimBytes, 200)
        XCTAssertEqual(report.settling(exited: [app.identity, helper.identity]).realizedMemoryReclaimBytes, 500,
                       "never more than the stop estimated")
    }

    func testAFamilyThatLeftTheScanHasNothingStillRunning() {
        let app = target(300, "Pages", root: true)
        let helper = target(301, "Pages Helper")
        var report = openApp(app, helpers: [helper])
        report.stuckExitingPIDs = [301]

        let settled = report.settlingSurvivors()

        XCTAssertTrue(settled.survivorPIDs.isEmpty)
        XCTAssertTrue(settled.stuckExitingPIDs.isEmpty)
        XCTAssertFalse(settled.appStillOpen)
        XCTAssertEqual(Set(settled.exitedAfterStopPIDs), [300, 301])
        XCTAssertTrue(settled.narrative.headline.hasPrefix("Stopped Pages and 1 helper"), settled.narrative.headline)
        XCTAssertEqual(settled.settlingSurvivors(), settled, "settling twice changes nothing")
    }

    // MARK: - Looking again

    func testRecheckSettlesAnAppThatQuitWhileTheResultWasOnScreen() async throws {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        let killer = table.killer()
        let held = await killer.kill(plan: .fixture(app, paths: [300: KillFixture.pagesPath]), forceKillDelay: 2, skipForce: true)
        XCTAssertTrue(held.appStillOpen)
        let signalsBefore = table.log.count

        let stillWaiting = await killer.recheck(held)
        XCTAssertEqual(stillWaiting, held, "the prompt has not been answered yet")

        // The user answered the save prompt and the app quit.
        table.signalFromOutside(SIGTERM, to: 300)
        let settled = await killer.recheck(held)

        XCTAssertTrue(settled.survivorPIDs.isEmpty)
        XCTAssertFalse(settled.appStillOpen)
        XCTAssertTrue(settled.succeeded, settled.summary)
        XCTAssertTrue(settled.summary.hasPrefix("Stopped Pages"), settled.summary)
        XCTAssertEqual(table.log.count, signalsBefore, "looking again never signals")
        let request = try XCTUnwrap(table.requests.last)
        XCTAssertEqual(request.policy, .verify)
        XCTAssertEqual(request.verificationMode, .targetOnly)
        XCTAssertEqual(request.targetIdentities, [app.identity], "one look at the survivors only")
    }

    func testRecheckSettlesAnAppAndTheHelpersThatClosedWithIt() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        let helper = KillProcessLite.fake(pid: 301, parent: 300, name: "Pages Helper")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        table.add(helper, FakeProcessTable.Behaviour(exitsWithParent: true))
        let killer = table.killer()
        let held = await killer.kill(
            plan: .fixture(app, members: [app, helper], paths: [300: KillFixture.pagesPath, 301: KillFixture.pagesHelperPath]),
            forceKillDelay: 2, skipForce: true
        )
        XCTAssertEqual(Set(held.survivorPIDs), [300, 301])

        table.signalFromOutside(SIGTERM, to: 300)
        let settled = await killer.recheck(held)

        XCTAssertTrue(settled.survivorPIDs.isEmpty)
        XCTAssertTrue(settled.succeeded, settled.summary)
        XCTAssertTrue(table.signals(to: 301).isEmpty, "the helper closed with its app; it was never signalled")
    }

    func testRecheckKeepsWhatIsStillRunning() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        let helper = KillProcessLite.fake(pid: 301, parent: 300, name: "Pages Helper")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        table.add(helper)
        let killer = table.killer()
        let held = await killer.kill(
            plan: .fixture(app, members: [app, helper], paths: [300: KillFixture.pagesPath, 301: KillFixture.pagesHelperPath]),
            forceKillDelay: 2, skipForce: true
        )

        table.signalFromOutside(SIGTERM, to: 300)
        let settled = await killer.recheck(held)

        XCTAssertEqual(settled.survivorPIDs, [301], "launchd adopted the helper; it is still there")
        XCTAssertFalse(settled.appStillOpen)
        XCTAssertFalse(settled.succeeded)
    }

    func testARecycledPIDIsNotTheApp() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        let killer = table.killer()
        let held = await killer.kill(plan: .fixture(app, paths: [300: KillFixture.pagesPath]), forceKillDelay: 2, skipForce: true)

        table.signalFromOutside(SIGTERM, to: 300)
        table.add(.fake(pid: 300, name: "unrelated", start: 2_000))
        let settled = await killer.recheck(held)

        XCTAssertTrue(settled.survivorPIDs.isEmpty, "the app is gone; its PID belongs to another process now")
        XCTAssertFalse(settled.appStillOpen)
        XCTAssertTrue(table.signals(to: 300).isEmpty)
        XCTAssertTrue(table.isListed(300))
    }

    func testRecheckOfAFinishedStopAsksNothing() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 540, name: "cruncher")
        table.add(worker)
        let killer = table.killer()
        let done = await killer.kill(plan: .fixture(worker), forceKillDelay: 2)
        XCTAssertTrue(done.survivorPIDs.isEmpty)
        let requestsBefore = table.requests.count

        let again = await killer.recheck(done)

        XCTAssertEqual(again, done)
        XCTAssertEqual(table.requests.count, requestsBefore, "nothing was listed as running, so nothing is looked at")
    }

    func testRecheckThatCannotLookChangesNothing() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        let killer = table.killer()
        let held = await killer.kill(plan: .fixture(app, paths: [300: KillFixture.pagesPath]), forceKillDelay: 2, skipForce: true)

        table.signalFromOutside(SIGTERM, to: 300)
        table.failSnapshots(from: table.requests.count)
        let again = await killer.recheck(held)

        XCTAssertEqual(again, held, "an unanswered look is not proof the app quit")
    }

    // MARK: - Fixtures

    private func target(_ pid: Int32, _ name: String, root: Bool = false, memory: UInt64 = 0) -> KillTarget {
        KillTarget(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0), parentPID: root ? 1 : 300,
                   name: name, ownerName: "me", depth: root ? 0 : 1, memoryBytes: memory, cpuPercent: 0, state: .survived,
                   reason: "Still alive after verification", isRoot: root)
    }

    /// The result of a held quit that the app has not answered yet.
    private func openApp(_ app: KillTarget, helpers: [KillTarget] = []) -> KillReport {
        var report = KillReport(
            displayName: "Pages",
            rootPID: app.pid,
            gracefulPIDs: [app.pid],
            targetResults: helpers + [app],
            survivorPIDs: ([app] + helpers).map(\.pid).sorted(),
            attempts: [KillAttempt(pid: app.pid, action: .quitRequest, stage: "graceful", succeeded: true)],
            timeline: KillExecutionTimeline(preflightMilliseconds: 0, signalMilliseconds: 0, verificationMilliseconds: 0,
                                            totalMilliseconds: 10_000),
            skipForceRequested: true
        )
        report.appStillOpen = true
        if !helpers.isEmpty {
            report.notes = [KillReport.helpersLeftAloneNote(app: "Pages")]
        }
        return report
    }
}
