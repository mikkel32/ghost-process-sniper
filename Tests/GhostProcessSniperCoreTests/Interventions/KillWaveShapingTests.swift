import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Databases and prefork servers stop their own workers in order, so the
/// first polite signal goes to the main process alone; force still reaches
/// every process that is left.
final class KillWaveShapingTests: XCTestCase {
    func testPostgresGetsSigintAtRootOnlyFirst() async {
        let table = FakeProcessTable()
        let (postmaster, backends) = postgresFamily(in: table, rootBehaviour: .exits(on: SIGINT, afterTicks: 2))

        let report = await table.killer().kill(plan: plan(postmaster, backends), forceKillDelay: 2)

        XCTAssertEqual(report.strategyUsed, .carefulShutdown)
        XCTAssertEqual(table.log.map(\.pid), [postmaster.pid], "the backends are the postmaster's to stop")
        XCTAssertEqual(table.log.map(\.signal), [SIGINT], "fast shutdown, which does not wait for clients")
        XCTAssertTrue(report.survivorPIDs.isEmpty, report.summary)
        XCTAssertEqual(Set(report.targetResults.filter { $0.state == .terminated }.map(\.pid)), Set([postmaster.pid] + backends.map(\.pid)))
        XCTAssertTrue(report.eventHistory.contains { $0.message == "Asked postgres to shut down its workers." })
    }

    func testDatabasePreviewShowsTheRootOnlyPhaseFirst() async {
        let table = FakeProcessTable()
        let (postmaster, backends) = postgresFamily(in: table, rootBehaviour: .ignoresTermination)

        let preview = await table.killer().preview(plan: plan(postmaster, backends), forceKillDelay: 2)

        XCTAssertEqual(preview.strategyProfile.phases.map(\.signalName), ["SIGINT", "SIGTERM", "SIGKILL"])
        XCTAssertEqual(preview.strategyProfile.phases.map(\.reach), [.rootOnly, .tree, .tree])
        XCTAssertEqual(preview.recommendedGraceSeconds, 12)
    }

    func testDatabaseForceWaveReachesWholeTree() async {
        let table = FakeProcessTable()
        let (postmaster, backends) = postgresFamily(in: table, rootBehaviour: .ignoresTermination, backendBehaviour: .ignoresTermination)
        let everyone = Set([postmaster.pid] + backends.map(\.pid))

        let report = await table.killer().kill(plan: plan(postmaster, backends), forceKillDelay: 2)

        XCTAssertEqual(table.log.first.map { [$0.pid] }, [postmaster.pid])
        XCTAssertEqual(table.log.filter { $0.signal == SIGINT }.map(\.pid), [postmaster.pid])
        XCTAssertEqual(Set(table.log.filter { $0.signal == SIGTERM }.map(\.pid)), everyone, "leftovers get the tree-wide polite step")
        XCTAssertEqual(Set(table.log.filter { $0.signal == SIGKILL }.map(\.pid)), everyone, "SIGKILL on the postmaster alone would leave backends holding shared memory")
        XCTAssertTrue(report.survivorPIDs.isEmpty)
    }

    func testPreforkMasterAloneGetsTheFirstSignal() async {
        let table = FakeProcessTable()
        let master = KillProcessLite.fake(pid: 1100, name: "Python")
        let workers = [KillProcessLite.fake(pid: 1101, parent: 1100, name: "Python"),
                       KillProcessLite.fake(pid: 1102, parent: 1100, name: "Python")]
        table.add(master, .exits(on: SIGINT, afterTicks: 1))
        workers.forEach { table.add($0, FakeProcessTable.Behaviour(exitsWithParent: true)) }
        let command = "/usr/bin/python3 /work/venv/bin/gunicorn app:app --workers 2"

        let report = await table.killer().kill(
            plan: .fixture(master, members: [master] + workers, commands: [1100: command, 1101: command, 1102: command]),
            forceKillDelay: 2
        )

        XCTAssertEqual(table.log.map(\.pid), [1100], "a worker signalled before its master is simply re-forked")
        XCTAssertTrue(report.survivorPIDs.isEmpty)
    }

    func testDevServerKeepsTheDeepestFirstWave() async {
        let table = FakeProcessTable()
        let vite = KillProcessLite.fake(pid: 1200, name: "node")
        let esbuild = KillProcessLite.fake(pid: 1201, parent: 1200, name: "esbuild")
        table.add(vite)
        table.add(esbuild)

        _ = await table.killer().kill(plan: .fixture(vite, members: [vite, esbuild], commands: [1200: KillFixture.viteCommand]),
                                      forceKillDelay: 2)

        XCTAssertEqual(table.log.map(\.pid), [1201, 1200])
        XCTAssertEqual(table.log.map(\.signal), [SIGINT, SIGINT])
    }

    // MARK: - Fixtures

    private func postgresFamily(
        in table: FakeProcessTable,
        rootBehaviour: FakeProcessTable.Behaviour,
        backendBehaviour: FakeProcessTable.Behaviour = FakeProcessTable.Behaviour(exitsWithParent: true)
    ) -> (KillProcessLite, [KillProcessLite]) {
        let postmaster = KillProcessLite.fake(pid: 1000, name: "postgres")
        let backends = (1001...1003).map { KillProcessLite.fake(pid: Int32($0), parent: 1000, name: "postgres") }
        table.add(postmaster, rootBehaviour)
        backends.forEach { table.add($0, backendBehaviour) }
        return (postmaster, backends)
    }

    private func plan(_ postmaster: KillProcessLite, _ backends: [KillProcessLite]) -> KillPlan {
        var commands = [postmaster.pid: KillFixture.postgresCommand]
        for (backend, role) in zip(backends, ["checkpointer", "walwriter", "autovacuum launcher"]) {
            commands[backend.pid] = "postgres: \(role)"
        }
        return .fixture(postmaster, members: [postmaster] + backends, commands: commands)
    }
}
