import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Stops of processes launchd runs, end to end against FakeProcessTable and
/// a scripted launchctl.
final class LaunchdAwareKillTests: XCTestCase {
    private var folder: LaunchAgentsFolder!
    private let postgresPath = "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres"
    private let listing = "PID\tStatus\tLabel\n812\t0\thomebrew.mxcl.postgresql@16\n"

    override func setUp() {
        folder = LaunchAgentsFolder()
        folder.write(label: "homebrew.mxcl.postgresql@16", program: ["/opt/homebrew/opt/postgresql@16/bin/postgres"], keepAlive: true)
    }

    override func tearDown() {
        folder.remove()
    }

    func testPreviewNamesTheKeepAliveJobAndDropsTheOrphanClaim() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 812, name: "postgres")
        table.add(postgres)

        let preview = await killer(table, FakeLaunchctl(list: listing)).preview(plan: plan(postgres))

        XCTAssertEqual(preview.launchdJob?.label, "homebrew.mxcl.postgresql@16")
        XCTAssertTrue(preview.offersLaunchdStop)
        XCTAssertEqual(preview.riskAssessment.supervisor?.name, "homebrew.mxcl.postgresql@16")
        XCTAssertFalse(preview.riskAssessment.risks.contains { $0.kind == .orphaned })
        let restart = preview.whyWaitEvidence.first { $0.title == "Will restart" }
        XCTAssertEqual(restart?.detail, "launchd keeps it running (KeepAlive in homebrew.mxcl.postgresql@16.plist), so a normal stop is undone within seconds. Run brew services stop postgresql@16 to keep it stopped.")
    }

    func testBootingOutTheJobSendsNoSignalToTheRoot() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 812, name: "postgres")
        table.add(postgres, .exits(on: SIGTERM, afterTicks: 2))
        let launchctl = FakeLaunchctl(list: listing, onBootout: { table.signalFromOutside(SIGTERM, to: 812) })
        let killer = killer(table, launchctl)

        let report = await killer.kill(plan: plan(postgres).binding(to: [postgres.identity], expiresAt: .distantFuture,
                                                                    launchdStop: .untilLogin), forceKillDelay: 2)

        XCTAssertTrue(table.signals(to: 812).isEmpty, "launchd stops it, not Ghost")
        XCTAssertFalse(table.isListed(812))
        XCTAssertEqual(launchctl.invocations, [["list"], ["bootout", "gui/501/homebrew.mxcl.postgresql@16"]])
        XCTAssertEqual(report.launchdBootout?.accepted, true)
        XCTAssertEqual(report.gracefulPIDs, [812])
        XCTAssertTrue(report.succeeded, report.summary)
        XCTAssertTrue(report.respawnedPIDs.isEmpty)
        XCTAssertEqual(report.targetResults.first { $0.pid == 812 }?.state, .terminated)
    }

    func testPreviewAndConfirmAskLaunchctlOnce() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 812, name: "postgres")
        table.add(postgres)
        let launchctl = FakeLaunchctl(list: listing, onBootout: { table.signalFromOutside(SIGTERM, to: 812) })
        let killer = killer(table, launchctl)

        let preview = await killer.preview(plan: plan(postgres))
        _ = await killer.preview(plan: plan(postgres))
        let report = await killer.kill(plan: plan(postgres).binding(to: preview.targetIdentities, expiresAt: .distantFuture,
                                                                    launchdStop: .untilLogin), forceKillDelay: 2)

        XCTAssertEqual(launchctl.invocations, [["list"], ["bootout", "gui/501/homebrew.mxcl.postgresql@16"]])
        XCTAssertTrue(report.succeeded, report.summary)
    }

    func testKeepOffDisablesTheJobToo() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 812, name: "postgres")
        table.add(postgres)
        let launchctl = FakeLaunchctl(list: listing, onBootout: { table.signalFromOutside(SIGTERM, to: 812) })

        let report = await killer(table, launchctl).kill(
            plan: plan(postgres).binding(to: [postgres.identity], expiresAt: .distantFuture, launchdStop: .keepOff), forceKillDelay: 2
        )

        XCTAssertEqual(launchctl.invocations.last, ["disable", "gui/501/homebrew.mxcl.postgresql@16"])
        XCTAssertEqual(report.launchdBootout?.disabled, true)
        XCTAssertTrue(table.log.isEmpty)
    }

    func testRefusedBootoutFallsBackToSignallingTheRoot() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 812, name: "postgres")
        table.add(postgres)

        let report = await killer(table, FakeLaunchctl(list: listing, bootoutStatus: 5)).kill(
            plan: plan(postgres).binding(to: [postgres.identity], expiresAt: .distantFuture, launchdStop: .untilLogin), forceKillDelay: 2
        )

        // The postgres master's own fast-shutdown request.
        XCTAssertEqual(table.signals(to: 812), [SIGINT])
        XCTAssertEqual(report.launchdBootout?.accepted, false)
        XCTAssertTrue(report.survivorPIDs.isEmpty)
    }

    func testPlainStopOfAKeepAliveJobReportsTheRestartByLabel() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 812, name: "postgres")
        let restarted = KillProcessLite.fake(pid: 830, name: "postgres", start: UInt64(Date().timeIntervalSince1970) + 60)
        table.add(postgres, FakeProcessTable.Behaviour(onSignal: [SIGINT: [.respawn(restarted, afterTicks: 1)]]))

        let report = await killer(table, FakeLaunchctl(list: listing)).kill(plan: plan(postgres), forceKillDelay: 2)

        XCTAssertEqual(table.signals(to: 812), [SIGINT])
        XCTAssertNil(report.launchdBootout)
        XCTAssertEqual(report.respawnedPIDs, [830])
        XCTAssertEqual(report.respawnedBy, "homebrew.mxcl.postgresql@16")
    }

    func testAppsAreNotLookedUpInLaunchd() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 900, name: "Notes")
        table.add(app)
        let launchctl = FakeLaunchctl(list: listing)

        let preview = await killer(table, launchctl).preview(
            plan: plan(app, path: "/System/Applications/Notes.app/Contents/MacOS/Notes")
        )

        XCTAssertNil(preview.launchdJob)
        XCTAssertTrue(launchctl.invocations.isEmpty)
    }

    // MARK: - Fixtures

    private func killer(_ table: FakeProcessTable, _ launchctl: FakeLaunchctl) -> ProcessKiller {
        ProcessKiller(
            snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper, clock: table.now,
            launchdResolver: LaunchdJobResolver(launchctl: launchctl, index: folder.index(), userID: 501)
        )
    }

    private func plan(_ root: KillProcessLite, path: String? = nil, command: String? = nil, ports: [Int] = []) -> KillPlan {
        let executable = path ?? (root.name == "postgres" ? postgresPath : "/usr/local/bin/\(root.name)")
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: root.pid, parentPID: root.parentPID, name: root.name, executablePath: executable,
                                            commandLine: command ?? executable, listeningPorts: ports, isRoot: true)],
            ancestors: [],
            parentIsLaunchd: root.parentPID == 1
        )
        return KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity], protectedPIDs: [],
                        displayName: root.name, workload: workload)
    }
}
