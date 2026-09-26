import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Holding back force must only hold back force: the graceful wait, the
/// polite follow-up and the approved timing all still happen.
final class KillForceHoldTests: XCTestCase {
    func testHeldForceStillWaitsForTheCleanExit() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 400, name: "postgres")
        table.add(postgres, .exits(on: SIGTERM, afterTicks: 3))

        let report = await table.killer().kill(
            plan: .fixture(postgres, commands: [400: KillFixture.postgresCommand]),
            forceKillDelay: 2,
            forceHeldCheck: { true }
        )

        XCTAssertEqual(report.strategyUsed, .carefulShutdown)
        XCTAssertGreaterThanOrEqual(table.tick, 3, "the database gets its shutdown time")
        XCTAssertTrue(report.survivorPIDs.isEmpty, report.summary)
        XCTAssertFalse(report.summary.hasPrefix("Still running"), report.summary)
        XCTAssertEqual(table.log.map(\.signal), [SIGTERM])
    }

    func testHeldForceWaitsTheWholeGraceForAnAppThatStaysOpen() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))

        let report = await table.killer().kill(
            plan: .fixture(app, paths: [300: KillFixture.pagesPath]),
            forceKillDelay: 2,
            forceHeldCheck: { true }
        )

        XCTAssertEqual(report.strategyUsed, .quitApp)
        XCTAssertEqual(table.quitRequests.map(\.pid), [300])
        XCTAssertEqual(table.elapsedSeconds, 10, accuracy: 0.1, "an editor gets its full 10 s to answer a save prompt")
        XCTAssertTrue(table.log.isEmpty, "the app is never signalled while force is held")
        XCTAssertEqual(report.survivorPIDs, [300])
        XCTAssertTrue(report.appStillOpen)
    }

    func testStopWaitingEndsTheGraceAndHoldsForce() async {
        let table = FakeProcessTable()
        let control = KillOperationControl()
        let worker = KillProcessLite.fake(pid: 540, name: "cruncher")
        table.add(worker, .ignoresTermination)
        let killer = table.killer(sleeper: { nanoseconds in
            table.advance(seconds: Double(nanoseconds) / 1_000_000_000)
            if table.tick == 2 { await control.stopWaiting() }
        })

        let report = await KillOperationRunner().runReport(plan: .fixture(worker), killer: killer, forceKillDelay: 5, control: control)

        XCTAssertLessThan(table.elapsedSeconds, 0.5, "the wait ends when the user stops waiting")
        XCTAssertEqual(table.log.map(\.signal), [SIGTERM])
        XCTAssertEqual(report.survivorPIDs, [540])
        XCTAssertTrue(report.skipForceRequested)
    }

    func testGraceWaitAnnouncesItsDeadline() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 550, name: "postgres")
        table.add(postgres, .exits(on: SIGTERM, afterTicks: 4))
        let events = EventLog()

        _ = await table.killer().kill(plan: .fixture(postgres, commands: [550: KillFixture.postgresCommand]),
                                      forceKillDelay: 2, skipForce: true, eventSink: { events.append($0) })

        let waits = events.all.filter { $0.kind == .graceWaiting }
        XCTAssertEqual(waits.count, 1, "only the graceful wait is announced")
        XCTAssertEqual(waits.first?.waitSeconds, 12)
        XCTAssertEqual(waits.first?.deadline, Date(timeIntervalSince1970: 1_000_012))
        XCTAssertEqual(waits.first?.message, "Waiting up to 12 s for postgres to shut down cleanly; nothing will be forced.")
    }

    func testHoldDuringTheSecondaryStepPreventsSigkill() async {
        let table = FakeProcessTable()
        let control = KillOperationControl()
        let server = KillProcessLite.fake(pid: 500, name: "node")
        table.add(server, .ignoresTermination)
        let killer = table.killer(sleeper: { nanoseconds in
            table.advance(seconds: Double(nanoseconds) / 1_000_000_000)
            if table.log.contains(where: { $0.signal == SIGTERM }) {
                await control.holdForce()
            }
        })

        let report = await KillOperationRunner().runReport(
            plan: .fixture(server, commands: [500: KillFixture.viteCommand]),
            killer: killer,
            forceKillDelay: 2,
            control: control
        )

        XCTAssertEqual(report.strategyUsed, .gentleDevServer)
        XCTAssertEqual(table.log.map(\.signal), [SIGINT, SIGTERM])
        XCTAssertEqual(report.survivorPIDs, [500])
        XCTAssertTrue(report.skipForceRequested)
    }

    func testHeldForceStillSendsThePoliteFollowUp() async {
        let table = FakeProcessTable()
        let server = KillProcessLite.fake(pid: 510, name: "node")
        table.add(server, .ignoresTermination)

        let report = await table.killer().kill(
            plan: .fixture(server, commands: [510: KillFixture.viteCommand]),
            forceKillDelay: 2,
            skipForce: true
        )

        XCTAssertEqual(report.strategyUsed, .gentleDevServer)
        XCTAssertEqual(table.log.map(\.signal), [SIGINT, SIGTERM], "only SIGKILL is held back")
        XCTAssertEqual(report.survivorPIDs, [510])
    }

    func testHeldQuitTerminatesLeftoverHelpersButNeverTheApp() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        let helper = KillProcessLite.fake(pid: 301, parent: 300, name: "Pages Helper")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        table.add(helper)

        let report = await table.killer().kill(
            plan: .fixture(app, members: [app, helper], paths: [300: KillFixture.pagesPath, 301: KillFixture.pagesHelperPath]),
            forceKillDelay: 2,
            skipForce: true
        )

        XCTAssertEqual(table.signals(to: 301), [SIGTERM])
        XCTAssertEqual(table.signals(to: 300), [], "SIGTERM would close the app past its save prompt")
        XCTAssertEqual(report.survivorPIDs, [300])
        XCTAssertTrue(report.appStillOpen)
    }

    func testQuitWithoutHoldOnlyForcesTheApp() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        let helper = KillProcessLite.fake(pid: 301, parent: 300, name: "Pages Helper")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        table.add(helper, .ignoresTermination)

        let report = await table.killer().kill(
            plan: .fixture(app, members: [app, helper], paths: [300: KillFixture.pagesPath, 301: KillFixture.pagesHelperPath]),
            forceKillDelay: 2
        )

        XCTAssertEqual(table.signals(to: 300), [SIGKILL])
        XCTAssertEqual(table.signals(to: 301), [SIGTERM, SIGKILL])
        XCTAssertEqual(report.attempts.filter { $0.pid == 300 && $0.signalName == "SIGKILL" }.map(\.stage), ["forced"])
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        XCTAssertFalse(report.appStillOpen)
    }

    func testConfirmRunsTheApprovedProfile() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 520, name: "worker")
        table.add(worker, .ignoresTermination)
        let gentle = KillStrategyProfile(strategy: .gentleDevServer, confidence: 0.8, phases: [
            KillSignalPhase(order: 0, label: "Interrupt", action: .signal(SIGINT), waitAfterSeconds: 1.2),
            KillSignalPhase(order: 1, label: "Terminate", action: .signal(SIGTERM), waitAfterSeconds: 0.45),
            KillSignalPhase(order: 2, label: "Force", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ], summary: "approved")
        let plan = KillPlan.fixture(worker)
            .binding(to: [worker.identity], expiresAt: Date().addingTimeInterval(60), profile: gentle)

        // Fresh evidence says "standard, wait 1 s": shorter than approved, so it changes nothing.
        let report = await table.killer().kill(plan: plan, forceKillDelay: 1)

        XCTAssertEqual(report.strategyUsed, .gentleDevServer)
        XCTAssertEqual(table.log.map(\.signal), [SIGINT, SIGTERM, SIGKILL])
        XCTAssertEqual(table.elapsedSeconds, 1.2 + 0.45, accuracy: 0.08, "the approved waits, not the fresh standard ones")
    }

    func testConfirmOnlyEverLengthensTheFirstWait() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 530, name: "postgres")
        table.add(postgres, .ignoresTermination)
        let quick = KillStrategyProfile(strategy: .standard, confidence: 0.7, phases: [
            KillSignalPhase(order: 0, label: "Terminate", action: .signal(SIGTERM), waitAfterSeconds: 0.5),
            KillSignalPhase(order: 1, label: "Force", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ], summary: "approved")
        let plan = KillPlan.fixture(postgres, commands: [530: KillFixture.postgresCommand])
            .binding(to: [postgres.identity], expiresAt: Date().addingTimeInterval(60), profile: quick)

        let report = await table.killer().kill(plan: plan, forceKillDelay: 2, skipForce: true)

        XCTAssertEqual(report.strategyUsed, .standard)
        XCTAssertEqual(table.elapsedSeconds, 12, accuracy: 0.08, "a database found at confirm still gets its 12 s")
        XCTAssertEqual(table.log.map(\.signal), [SIGTERM])
    }

    func testForceSurvivorsSendsOnlySigkillToVerifiedSurvivors() async throws {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 300, name: "Pages")
        let helper = KillProcessLite.fake(pid: 301, parent: 300, name: "Pages Helper")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 100_000))
        table.add(helper)
        let plan = KillPlan.fixture(app, members: [app, helper], paths: [300: KillFixture.pagesPath, 301: KillFixture.pagesHelperPath])
        let held = await table.killer().kill(plan: plan, forceKillDelay: 2, skipForce: true)
        XCTAssertEqual(held.survivorPIDs, [300])
        let waitedBefore = table.elapsedSeconds

        let followUp = try XCTUnwrap(plan.forcingSurvivors(of: held))
        let forced = await table.killer().kill(plan: followUp, forceKillDelay: 2)

        XCTAssertEqual(followUp.targetIdentities, [app.identity])
        XCTAssertEqual(table.quitRequests.count, 1, "the quit request is not repeated")
        XCTAssertEqual(table.signals(to: 300), [SIGKILL])
        XCTAssertEqual(table.elapsedSeconds, waitedBefore, accuracy: 0.001, "no grace period the second time")
        XCTAssertTrue(forced.isForceFollowUp)
        XCTAssertEqual(forced.forcedPIDs, [300])
        XCTAssertTrue(forced.survivorPIDs.isEmpty)
        XCTAssertNil(plan.forcingSurvivors(of: forced), "nothing is left to force")
    }
}
