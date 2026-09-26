import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Suspended, debugged and exiting processes do not answer a polite signal
/// the way a running one does; the stop has to know which is which.
final class KillTargetConditionTests: XCTestCase {
    func testStoppedJobIsResumedAfterSigterm() async {
        let table = FakeProcessTable()
        let job = KillProcessLite.fake(pid: 900, name: "cruncher", status: FakeProcessTable.stoppedStatus)
        table.add(job)

        let report = await table.killer().kill(plan: .fixture(job), forceKillDelay: 5)

        XCTAssertEqual(table.signals(to: 900), [SIGTERM, SIGCONT], "the pending SIGTERM lands once the job runs again")
        XCTAssertFalse(table.isListed(900))
        XCTAssertTrue(report.forcedPIDs.isEmpty)
        XCTAssertEqual(report.gracefulPIDs, [900])
        XCTAssertEqual(report.attempts.filter { $0.stage == "resume" }.map(\.signalName), ["SIGCONT"])
        XCTAssertLessThan(table.elapsedSeconds, 1, "no grace period is burnt waiting on a paused job")
        XCTAssertEqual(report.eventHistory.filter { $0.message == "Resumed cruncher so it can exit." }.count, 1)
    }

    func testRunningTargetsNeverGetSigcont() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 910, name: "runner")
        let job = KillProcessLite.fake(pid: 911, parent: 910, name: "cruncher", status: FakeProcessTable.stoppedStatus)
        table.add(root)
        table.add(job)

        _ = await table.killer().kill(plan: .fixture(root, members: [root, job]), forceKillDelay: 2)

        XCTAssertEqual(table.signals(to: 910), [SIGTERM])
        XCTAssertEqual(table.signals(to: 911), [SIGTERM, SIGCONT])
    }

    func testStoppedJobIsNotedInPreview() async {
        let table = FakeProcessTable()
        let job = KillProcessLite.fake(pid: 920, name: "cruncher", status: FakeProcessTable.stoppedStatus)
        table.add(job)

        let preview = await table.killer().preview(plan: .fixture(job), forceKillDelay: 2)

        XCTAssertEqual(preview.targets.first?.condition, .suspended)
        XCTAssertEqual(preview.targets.first?.reason, "Suspended (Ctrl-Z) \u{2014} still holds its ports")
        XCTAssertTrue(preview.decisionEvidence.contains {
            $0.title == "Paused job (Ctrl-Z)" && $0.detail == "Ghost resumes it so it can exit cleanly."
        })
    }

    func testSuspendedAppIsResumedBeforeTheQuitRequest() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 930, name: "Pages", status: FakeProcessTable.stoppedStatus)
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 2))

        let report = await table.killer().kill(plan: .fixture(app, paths: [930: KillFixture.pagesPath]), forceKillDelay: 2)

        XCTAssertEqual(report.strategyUsed, .quitApp)
        XCTAssertEqual(table.signals(to: 930), [SIGCONT], "a stopped app cannot answer the quit request")
        XCTAssertEqual(table.quitRequests.map(\.pid), [930])
        XCTAssertTrue(report.survivorPIDs.isEmpty)
    }

    func testDebuggerAttachedTargetIsExplainedAndDoesNotHoldTheWait() async {
        let table = FakeProcessTable()
        let debugged = KillProcessLite.fake(pid: 940, name: "cruncher", flags: KillProcessLite.tracedFlag)
        table.add(debugged, .ignoresTermination)
        let killer = table.killer()

        let preview = await killer.preview(plan: .fixture(debugged), forceKillDelay: 5)
        let report = await killer.kill(plan: .fixture(debugged), forceKillDelay: 5, skipForce: true)

        XCTAssertEqual(preview.targets.first?.condition, .traced)
        XCTAssertTrue(preview.whyWaitEvidence.contains {
            $0.detail == "A debugger is attached to cruncher: a polite stop only pauses it in the debugger. Stop it from the debugger, or allow force."
        })
        XCTAssertLessThan(table.elapsedSeconds, 0.5, "the grace is not held open for a process sitting in a debugger")
        XCTAssertEqual(report.survivorPIDs, [940])
    }

    func testSurvivorStuckInExitIsExplained() async {
        let table = FakeProcessTable()
        let stuck = KillProcessLite.fake(pid: 950, name: "cruncher", flags: KillProcessLite.exitingFlag)
        table.add(stuck, .ignoresTermination)

        let report = await table.killer().kill(plan: .fixture(stuck), forceKillDelay: 0.2, skipForce: true)

        XCTAssertEqual(report.survivorPIDs, [950])
        XCTAssertTrue(report.summary.contains("PID 950 is stuck finishing its exit in the kernel (hung disk or network I/O); it disappears when that I/O completes."),
                      report.summary)
    }
}
