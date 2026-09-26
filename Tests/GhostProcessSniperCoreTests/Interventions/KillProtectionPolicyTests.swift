import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The floor no plan can go below: Ghost itself, the processes it runs
/// inside, and the ones that end the login session.
final class KillProtectionPolicyTests: XCTestCase {
    func testLoginWindowRootCannotBeStopped() async {
        let table = FakeProcessTable()
        let loginwindow = KillProcessLite.fake(pid: 150, name: "loginwindow")
        table.add(loginwindow)

        let killer = table.killer()
        let preview = await killer.preview(plan: .fixture(loginwindow), forceKillDelay: 2)
        let report = await killer.kill(plan: .fixture(loginwindow), forceKillDelay: 2)

        XCTAssertFalse(preview.canKill)
        XCTAssertTrue(preview.lockedTargets.contains { $0.pid == 150 && $0.reason.contains("logs you out") })
        XCTAssertTrue(table.log.isEmpty)
        XCTAssertTrue(report.attempts.isEmpty)
    }

    func testGhostItselfIsNeverSignalled() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 160, name: "runner")
        let ghost = KillProcessLite.fake(pid: Int32(getpid()), parent: 160, name: "GhostProcessSniper")
        table.add(root)
        table.add(ghost)

        _ = await table.killer().kill(plan: .fixture(ghost, members: [ghost]), forceKillDelay: 1)
        _ = await table.killer().kill(plan: .fixture(root, members: [root]), forceKillDelay: 1)

        XCTAssertTrue(table.signals(to: Int32(getpid())).isEmpty)
    }

    func testTheProcessGhostRunsInsideIsLocked() async {
        let table = FakeProcessTable()
        let shell = KillProcessLite.fake(pid: 170, name: "zsh")
        let ghost = KillProcessLite.fake(pid: Int32(getpid()), parent: 170, name: "GhostProcessSniper")
        let sibling = KillProcessLite.fake(pid: 171, parent: 170, name: "worker")
        table.add(shell)
        table.add(ghost)
        table.add(sibling)

        let preview = await table.killer().preview(plan: .fixture(shell), forceKillDelay: 1)

        XCTAssertFalse(preview.canKill)
        XCTAssertTrue(preview.lockedTargets.contains { $0.pid == 170 })
        XCTAssertEqual(preview.strategyRecommendation.strategy, .inspectOnly)
    }

    func testDarwinSignalerRefusesPidZeroOneAndItself() {
        let signaler = DarwinProcessSignaler()
        for pid in [0, 1, Int32(getpid())] {
            XCTAssertThrowsError(try signaler.send(signal: 0, to: pid), "PID \(pid)")
        }
    }

    func testSelfAndAncestorsAreNeverTargets() async {
        let table = FakeProcessTable()
        let terminal = KillProcessLite.fake(pid: 180, name: "Terminal")
        let shell = KillProcessLite.fake(pid: 181, parent: 180, name: "zsh")
        let ghost = KillProcessLite.fake(pid: 182, parent: 181, name: "GhostProcessSniper")
        let other = KillProcessLite.fake(pid: 183, parent: 180, name: "zsh")
        [terminal, shell, ghost, other].forEach { table.add($0) }
        let policy = KillProtectionPolicy(selfPID: 182)
        let arena = KillGraphArena(processes: table.listed, sampledAt: Date())

        XCTAssertNotNil(Self.never(policy.verdict(for: ghost, executablePath: nil, arena: arena)))
        XCTAssertEqual(Self.never(policy.verdict(for: terminal, executablePath: nil, arena: arena)),
                       "Ghost runs inside Terminal; stopping it would stop Ghost mid-way.")
        XCTAssertNotNil(Self.never(policy.verdict(for: shell, executablePath: nil, arena: arena)))
        XCTAssertNil(Self.never(policy.verdict(for: other, executablePath: nil, arena: arena)))

        let preview = await table.killer(protection: policy).preview(plan: .fixture(terminal), forceKillDelay: 1)
        XCTAssertFalse(preview.canKill)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .inspectOnly)
        XCTAssertEqual(preview.riskAssessment.headline, "Ghost runs inside Terminal; stopping it would stop Ghost mid-way.")
        XCTAssertEqual(Set(preview.lockedTargets.map(\.pid)), [180, 181, 182])
        XCTAssertEqual(policy.neverReason(forRoot: terminal.asProcessMetrics(), in: table.listed.map { $0.asProcessMetrics() }),
                       "Ghost runs inside Terminal; stopping it would stop Ghost mid-way.")
    }

    func testDockIsCautionNotBlocked() async {
        let table = FakeProcessTable()
        let dock = KillProcessLite.fake(pid: 190, name: "Dock")
        table.add(dock)

        let preview = await table.killer().preview(
            plan: .fixture(dock, paths: [190: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"]),
            forceKillDelay: 1
        )

        XCTAssertTrue(preview.canKill, "killall Dock is a legitimate fix")
        XCTAssertTrue(preview.riskAssessment.risks.contains { $0.title == "macOS restarts it" })
    }

    func testTmuxServerWarnsEverySessionCloses() {
        let server = KillProcessLite.fake(pid: 200, parent: 1, name: "tmux")
        let panes = (201...203).map { KillProcessLite.fake(pid: Int32($0), parent: 200, name: "zsh") }
        let nested = KillProcessLite.fake(pid: 204, parent: 201, name: "bash")
        let arena = KillGraphArena(processes: [server] + panes + [nested], sampledAt: Date())

        guard case .caution(let risk) = KillProtectionPolicy(selfPID: 9_999).verdict(for: server, executablePath: nil, arena: arena) else {
            return XCTFail("a tmux server needs a warning")
        }
        XCTAssertEqual(risk.detail, "Stopping the tmux server closes 3 terminal sessions and everything running in them.")
    }

    func testLoginShellWarnsItsSessionCloses() {
        let shell = KillProcessLite.fake(pid: 210, name: "zsh")
        let arena = KillGraphArena(processes: [shell], sampledAt: Date())

        let verdict = KillProtectionPolicy(selfPID: 9_999).verdict(for: shell, executablePath: "/bin/zsh", commandLine: "-zsh", arena: arena)

        guard case .caution(let risk) = verdict else { return XCTFail("a login shell needs a warning") }
        XCTAssertTrue(risk.detail.contains("1 terminal session"), risk.detail)
    }

    private static func never(_ verdict: KillProtection?) -> String? {
        if case .never(let reason) = verdict { return reason }
        return nil
    }
}
