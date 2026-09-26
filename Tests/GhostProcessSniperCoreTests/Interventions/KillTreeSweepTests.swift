import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Force freezes the tree before it kills, so nothing forked in between
/// escapes, and goes parent first, so no respawner sees a child die.
final class KillTreeSweepTests: XCTestCase {
    /// After the virtual clock's start, so "born after the stop began".
    private let duringStop: UInt64 = 1_000_100

    func testChildForkedDuringTheGraceIsFrozenThenKilled() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1300, name: "forker")
        let child = KillProcessLite.fake(pid: 1301, parent: 1300, name: "worker", start: duringStop)
        table.add(root, FakeProcessTable.Behaviour(onSignal: [SIGTERM: [.forkChild(child, afterTicks: 1, behaviour: .ignoresTermination)]]))

        let report = await table.killer().kill(plan: .fixture(root), forceKillDelay: 0.5)

        XCTAssertEqual(table.signals(to: 1301), [SIGSTOP, SIGKILL])
        XCTAssertEqual(table.signals(to: 1300), [SIGTERM, SIGSTOP, SIGKILL])
        XCTAssertEqual(report.lateTargets.map(\.pid), [1301])
        XCTAssertEqual(report.lateTargets.first?.state, .forceKilled)
        XCTAssertTrue(report.lateTargets.first?.reason.hasPrefix("Started during the stop by forker (PID 1300)") == true,
                      report.lateTargets.first?.reason ?? "")
        XCTAssertTrue(report.targetResults.contains { $0.pid == 1301 && $0.state == .forceKilled })
        XCTAssertEqual(report.frozenCount, 2)
        XCTAssertFalse(report.forkStorm)
        XCTAssertTrue(table.listed.isEmpty, "nothing is left reparented to launchd")
    }

    func testForceFreezesEverythingFirstAndGoesParentFirst() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1310, name: "runner")
        let child = KillProcessLite.fake(pid: 1311, parent: 1310, name: "pool")
        let grandchild = KillProcessLite.fake(pid: 1312, parent: 1311, name: "worker")
        [root, child, grandchild].forEach { table.add($0, .ignoresTermination) }

        let report = await table.killer().kill(plan: .fixture(root, members: [root, child, grandchild]), forceKillDelay: 0.2)

        let log = table.log
        XCTAssertEqual(log.filter { $0.signal == SIGTERM }.map(\.pid), [1312, 1311, 1310], "polite signals still go deepest first")
        XCTAssertEqual(log.filter { $0.signal == SIGSTOP }.map(\.pid), [1310, 1311, 1312])
        XCTAssertEqual(log.filter { $0.signal == SIGKILL }.map(\.pid), [1310, 1311, 1312], "SIGKILL goes parent first")
        let lastStop = log.lastIndex { $0.signal == SIGSTOP } ?? .max
        let firstKill = log.firstIndex { $0.signal == SIGKILL } ?? .min
        XCTAssertLessThan(lastStop, firstKill, "every SIGSTOP comes before any SIGKILL")
        XCTAssertEqual(Set(report.forcedPIDs), [1310, 1311, 1312])
        XCTAssertTrue(report.lateTargets.isEmpty)
        XCTAssertTrue(table.listed.isEmpty)
    }

    func testHeldForceOnlyReportsTheOrphanAndFreezesNothing() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1320, name: "forker")
        let orphan = KillProcessLite.fake(pid: 1321, parent: 1320, name: "daemon", start: duringStop, group: 1320)
        table.add(root, FakeProcessTable.Behaviour(onSignal: [SIGTERM: [
            .forkChild(orphan, afterTicks: 1, behaviour: .ignoresTermination),
            .exit(afterTicks: 2)
        ]]))

        let report = await table.killer().kill(plan: .fixture(root), forceKillDelay: 2, skipForce: true)

        XCTAssertFalse(table.log.contains { $0.signal == SIGSTOP }, "a hold means no freeze")
        XCTAssertTrue(table.signals(to: 1321).isEmpty)
        XCTAssertTrue(table.isListed(1321))
        XCTAssertEqual(report.lateTargets.map(\.pid), [1321])
        XCTAssertEqual(report.lateTargets.first?.state, .locked)
        XCTAssertTrue(report.summary.contains("Kept running after forker stopped: daemon (PID 1321)."), report.summary)
    }

    func testForkStormIsCappedAfterThreeRounds() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1330, name: "forkbomb")
        table.add(root, .ignoresTermination)
        let start = duringStop
        // Snapshot 0 confirms, 1 verifies before force, 2-4 are the sweeps.
        table.onSnapshot { index in
            guard (2...4).contains(index) else { return [] }
            return (0..<40).map { KillProcessLite.fake(pid: Int32(2_000 + index * 100 + $0), parent: 1330, start: start) }
        }

        let report = await table.killer().kill(plan: .fixture(root), forceKillDelay: 0.2)

        XCTAssertTrue(report.forkStorm)
        XCTAssertEqual(report.frozenCount, 121)
        XCTAssertEqual(table.log.filter { $0.signal == SIGKILL }.count, 121, "everything frozen is killed")
        XCTAssertEqual(table.requests.count, 1 + 1 + 3 + 2, "three sweeps, then the post-force and final checks")
        XCTAssertTrue(table.listed.isEmpty)
        XCTAssertTrue(report.summary.contains("kept starting new processes"), report.summary)
    }

    func testPreexistingUnapprovedChildIsNeverSignalled() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1340, name: "runner")
        let child = KillProcessLite.fake(pid: 1341, parent: 1340, name: "worker")
        table.add(root, .ignoresTermination)
        table.add(child, .ignoresTermination)
        let plan = KillPlan.fixture(root).binding(to: [root.identity], expiresAt: .distantFuture,
                                                  approvedAt: Date(timeIntervalSince1970: 1_000_000))

        let report = await table.killer().kill(plan: plan, forceKillDelay: 0.2)

        XCTAssertTrue(table.signals(to: 1341).isEmpty, "it existed at the preview and was left out of it")
        XCTAssertEqual(table.signals(to: 1340), [SIGTERM, SIGSTOP, SIGKILL])
        XCTAssertTrue(report.lateTargets.isEmpty)
    }

    func testFailedSweepResumesEverythingItFroze() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1350, name: "runner")
        let child = KillProcessLite.fake(pid: 1351, parent: 1350, name: "worker")
        table.add(root, .ignoresTermination)
        table.add(child, .ignoresTermination)
        table.failSnapshots(from: 2)

        let report = await table.killer().kill(plan: .fixture(root, members: [root, child]), forceKillDelay: 0.2)

        XCTAssertEqual(table.signals(to: 1350), [SIGTERM, SIGSTOP, SIGCONT])
        XCTAssertEqual(table.signals(to: 1351), [SIGTERM, SIGSTOP, SIGCONT])
        XCTAssertNotEqual(table.status(of: 1350), FakeProcessTable.stoppedStatus, "an error never leaves the tree frozen")
        XCTAssertNotEqual(table.status(of: 1351), FakeProcessTable.stoppedStatus)
        XCTAssertFalse(report.failures.isEmpty)
    }

    /// The real kernel: a shell with a background child, forced through
    /// the freeze. Only meaningful on macOS.
    func testNativeForceFreezesAndKillsARealShellTree() async throws {
        #if os(macOS)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 60 & sleep 60"]
        try shell.run()
        defer { if shell.isRunning { shell.terminate() } }
        let provider = NativeKillSnapshotProvider()
        var tree: [KillGraphSliceMember] = []
        for _ in 0..<40 where tree.count < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let arena = try await provider.snapshot(policy: .confirm).liteArena
            if let root = arena.processes(for: shell.processIdentifier).first {
                tree = arena.descendants(of: root.identity)
            }
        }
        let root = try XCTUnwrap(tree.first { $0.depth == 0 }?.process)
        XCTAssertGreaterThanOrEqual(tree.count, 2, "the shell and its background sleep")
        let identities = tree.map(\.process.identity)
        let plan = KillPlan(rootIdentity: root.identity, targetIdentities: identities, protectedPIDs: [], displayName: "sh")
            .binding(to: identities, expiresAt: Date().addingTimeInterval(60), profile: .forceNow)

        let report = await ProcessKiller().kill(plan: plan, forceKillDelay: 1)
        shell.waitUntilExit()

        XCTAssertGreaterThanOrEqual(report.frozenCount, 2)
        XCTAssertTrue(report.survivorPIDs.isEmpty, report.summary)
        let after = try await provider.snapshot(policy: .verify).liteArena
        XCTAssertTrue(identities.allSatisfy { after.process(for: $0).map(\.isZombie) ?? true })
        #else
        throw XCTSkip("Needs the macOS process table")
        #endif
    }
}
