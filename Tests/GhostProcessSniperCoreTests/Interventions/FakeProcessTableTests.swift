import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The fake must behave like the kernel where the engine depends on it.
final class FakeProcessTableTests: XCTestCase {
    func testExitHappensAfterTheScriptedTicks() throws {
        let table = FakeProcessTable()
        table.add(.fake(pid: 10), .exits(on: SIGTERM, afterTicks: 2))

        try table.send(signal: SIGTERM, to: 10)
        table.advance()
        XCTAssertTrue(table.exists(pid: 10))
        table.advance()
        XCTAssertFalse(table.exists(pid: 10))
        XCTAssertThrowsError(try table.send(signal: SIGTERM, to: 10)) { error in
            XCTAssertEqual((error as? SignalFailure)?.errnoCode, ESRCH)
        }
    }

    func testStoppedProcessHoldsSignalsUntilSigcont() throws {
        let table = FakeProcessTable()
        table.add(.fake(pid: 20, status: FakeProcessTable.stoppedStatus))

        try table.send(signal: SIGTERM, to: 20)
        XCTAssertEqual(table.status(of: 20), FakeProcessTable.stoppedStatus, "SIGTERM stays pending while stopped")
        try table.send(signal: SIGCONT, to: 20)
        XCTAssertFalse(table.isListed(20), "the pending SIGTERM lands on SIGCONT")

        table.add(.fake(pid: 21, status: FakeProcessTable.stoppedStatus))
        try table.send(signal: SIGKILL, to: 21)
        XCTAssertFalse(table.isListed(21), "SIGKILL needs no SIGCONT")
    }

    func testZombieStaysListedUntilItsParentExits() throws {
        let table = FakeProcessTable()
        table.add(.fake(pid: 30), .ignoresTermination)
        table.add(.fake(pid: 31, parent: 30), FakeProcessTable.Behaviour(zombieOnExit: true))

        try table.send(signal: SIGKILL, to: 31)
        XCTAssertEqual(table.status(of: 31), FakeProcessTable.zombieStatus)
        XCTAssertTrue(table.exists(pid: 31), "kill(pid, 0) succeeds on a zombie")
        XCTAssertTrue(table.isZombieOrGone(pid: 31), "but its BSD status says it has exited")
        XCTAssertFalse(table.isZombieOrGone(pid: 30))
        try table.send(signal: SIGKILL, to: 30)
        XCTAssertFalse(table.isListed(31), "launchd reaps the zombie once its parent is gone")
    }

    func testDeniedProcessRefusesEverySignal() {
        let table = FakeProcessTable()
        table.add(.fake(pid: 40, userID: 0), FakeProcessTable.Behaviour(deniesSignals: true))

        XCTAssertThrowsError(try table.send(signal: SIGKILL, to: 40)) { error in
            XCTAssertEqual((error as? SignalFailure)?.errnoCode, EPERM)
        }
        XCTAssertTrue(table.exists(pid: 40))
        XCTAssertEqual(table.log.map(\.signal), [SIGKILL])
    }

    func testForkAndRespawnAppearAfterTheirDelay() throws {
        let table = FakeProcessTable()
        let child = KillProcessLite.fake(pid: 51, parent: 50)
        let replacement = KillProcessLite.fake(pid: 53, parent: 1, start: 2_000)
        table.add(.fake(pid: 50), FakeProcessTable.Behaviour(onSignal: [SIGINT: [.forkChild(child, afterTicks: 1)]]))
        table.add(.fake(pid: 52), FakeProcessTable.Behaviour(onSignal: [SIGTERM: [.respawn(replacement, afterTicks: 2)]]))

        try table.send(signal: SIGINT, to: 50)
        try table.send(signal: SIGTERM, to: 52)
        XCTAssertFalse(table.isListed(51))
        XCTAssertFalse(table.isListed(52))
        table.advance()
        XCTAssertTrue(table.isListed(50) && table.isListed(51))
        XCTAssertFalse(table.isListed(53))
        table.advance()
        XCTAssertTrue(table.isListed(53))
    }

    func testOrphansAreAdoptedAndHelpersFollowTheirParent() throws {
        let table = FakeProcessTable()
        table.add(.fake(pid: 60))
        table.add(.fake(pid: 61, parent: 60))
        table.add(.fake(pid: 62, parent: 60), FakeProcessTable.Behaviour(exitsWithParent: true))

        try table.send(signal: SIGTERM, to: 60)
        XCTAssertEqual(table.listed.map(\.pid), [61])
        XCTAssertEqual(table.listed.first?.parentPID, 1)
    }

    func testALateFollowerIsListedUnderLaunchdUntilItExits() throws {
        let table = FakeProcessTable()
        table.add(.fake(pid: 63))
        table.add(.fake(pid: 64, parent: 63), FakeProcessTable.Behaviour(exitsAfterParent: 2))

        try table.send(signal: SIGTERM, to: 63)
        XCTAssertEqual(table.listed.map(\.pid), [64])
        XCTAssertEqual(table.listed.first?.parentPID, 1)
        table.advance()
        XCTAssertTrue(table.isListed(64))
        table.advance()
        XCTAssertFalse(table.isListed(64))
    }

    func testQuitRequestOnlyWorksForApps() async {
        let table = FakeProcessTable()
        table.add(.fake(pid: 70), FakeProcessTable.Behaviour(quitsOnRequest: 1))
        table.add(.fake(pid: 71))

        let appAccepted = await table.requestQuit(pid: 70)
        let toolAccepted = await table.requestQuit(pid: 71)
        XCTAssertTrue(appAccepted)
        XCTAssertFalse(toolAccepted)
        table.advance()
        XCTAssertFalse(table.isListed(70))
        XCTAssertEqual(table.quitRequests.map(\.pid), [70])
    }

    func testSleeperAdvancesTicksAndTheClock() async {
        let table = FakeProcessTable(start: Date(timeIntervalSince1970: 100))
        await table.sleeper(500_000_000)
        await table.sleeper(250_000_000)
        XCTAssertEqual(table.tick, 2)
        XCTAssertEqual(table.now().timeIntervalSince1970, 100.75, accuracy: 0.0001)
    }

    func testTargetOnlySnapshotReadsWhoeverHoldsTheRequestedPIDs() async throws {
        let table = FakeProcessTable()
        let original = KillProcessLite.fake(pid: 80, start: 1_000)
        table.add(.fake(pid: 80, start: 2_000))
        table.add(.fake(pid: 81))

        let snapshot = try await table.snapshot(request: KillSnapshotRequest(
            policy: .verify,
            targetIdentities: [original.identity],
            requiresCompleteGraph: false,
            verificationMode: .targetOnly
        ))
        XCTAssertEqual(snapshot.arena?.processes.map(\.pid), [80])
        XCTAssertEqual(snapshot.arena?.hasRecycledPID(for: original.identity), true)

        let complete = try await table.snapshot(policy: .verify)
        XCTAssertEqual(complete.arena?.processes.map(\.pid), [80, 81])
    }
}
