import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// End-to-end stops against FakeProcessTable, where processes react to what
/// the engine sends. Each scenario states the cause and checks the effect.
final class KillEngineScenarioTests: XCTestCase {
    func testStandardStopEndsAsSoonAsTheProcessExitsAfterSigterm() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 700, name: "cruncher")
        table.add(worker, .exits(on: SIGTERM, afterTicks: 2))

        let report = await killer(table).kill(plan: plan(worker), forceKillDelay: 5)

        XCTAssertEqual(report.strategyUsed, .standard)
        XCTAssertEqual(table.log.map(\.signal), [SIGTERM])
        XCTAssertEqual(report.gracefulPIDs, [700])
        XCTAssertTrue(report.forcedPIDs.isEmpty)
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        XCTAssertTrue(report.succeeded, report.summary)
        XCTAssertEqual(report.targetResults.first { $0.pid == 700 }?.state, .terminated)
        XCTAssertGreaterThanOrEqual(table.tick, 2, "the grace period waits for the exit")
        XCTAssertFalse(table.isListed(700))
    }

    func testAppThatQuitsOnRequestNeedsNoSignal() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 710, name: "Pages")
        let helper = KillProcessLite.fake(pid: 711, parent: 710, name: "Pages Helper")
        table.add(app, FakeProcessTable.Behaviour(quitsOnRequest: 3))
        table.add(helper, FakeProcessTable.Behaviour(exitsWithParent: true))

        let report = await killer(table).kill(
            plan: plan(app, members: [app, helper], paths: [
                710: "/Applications/Pages.app/Contents/MacOS/Pages",
                711: "/Applications/Pages.app/Contents/XPCServices/Pages Helper.xpc/Contents/MacOS/Pages Helper"
            ]),
            forceKillDelay: 2
        )

        XCTAssertEqual(report.strategyUsed, .quitApp)
        XCTAssertEqual(table.quitRequests.map(\.pid), [710])
        XCTAssertTrue(table.log.isEmpty, "the helper closes with the app")
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        XCTAssertTrue(report.forcedPIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(table.tick, 3)
        XCTAssertTrue(table.listed.isEmpty)
    }

    func testProcessThatIgnoresSigtermIsForcedAfterTheGracePeriod() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 720, name: "cruncher")
        table.add(worker, .ignoresTermination)

        let report = await killer(table).kill(plan: plan(worker), forceKillDelay: 0.05)

        XCTAssertEqual(table.log.map(\.signal), [SIGTERM, SIGSTOP, SIGKILL], "frozen, then forced")
        XCTAssertEqual(report.forcedPIDs, [720])
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        XCTAssertEqual(report.targetResults.first { $0.pid == 720 }?.state, .forceKilled)
        XCTAssertFalse(table.isListed(720))
    }

    // MARK: - Fixtures

    private func killer(_ table: FakeProcessTable) -> ProcessKiller {
        ProcessKiller(snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper)
    }

    private func plan(
        _ root: KillProcessLite,
        members: [KillProcessLite]? = nil,
        paths: [Int32: String] = [:]
    ) -> KillPlan {
        let members = members ?? [root]
        let workload = KillWorkloadProfile(
            processes: members.map {
                KillWorkloadProcess(pid: $0.pid, parentPID: $0.parentPID, name: $0.name, executablePath: paths[$0.pid] ?? "",
                                    commandLine: paths[$0.pid] ?? $0.name, isRoot: $0.identity == root.identity)
            },
            ancestors: [],
            parentIsLaunchd: root.parentPID == 1
        )
        return KillPlan(rootIdentity: root.identity, targetIdentities: members.map(\.identity), protectedPIDs: [],
                        displayName: root.name, workload: workload)
    }
}
