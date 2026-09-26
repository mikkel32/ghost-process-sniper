import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The running stop's display: plain headlines, a countdown only for waits
/// long enough to read, and per-process states in event order.
final class KillLiveProgressTests: XCTestCase {
    private let operation = KillOperationID()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testSyntheticStopWalksThePhases() {
        var progress = KillLiveProgress(displayName: "postgres", kind: .dataStore, strategy: .carefulShutdown)
        XCTAssertEqual(progress.phase, .starting)

        progress.apply([event(.queued), event(.preflight), event(.targetUpdated, pid: 400, state: .ready),
                        event(.signaled, pid: 400, state: .stopping, signal: "SIGINT"),
                        event(.signaled, pid: 401, state: .stopping, signal: "SIGTERM")])
        XCTAssertEqual(progress.phase, .stopping)
        XCTAssertEqual(progress.headline, "Asking postgres to stop\u{2026}")

        progress.apply(event(.graceWaiting, wait: 12))
        XCTAssertEqual(progress.phase, .waiting)
        XCTAssertEqual(progress.headline, "Waiting for postgres to shut down cleanly\u{2026}")
        XCTAssertEqual(progress.wait?.deadline, start.addingTimeInterval(12))
        XCTAssertEqual(progress.wait?.startedAt, start)
        XCTAssertEqual(progress.wait?.showsIndicator, true)

        progress.apply(event(.targetUpdated, pid: 401, state: .terminated))
        XCTAssertNotNil(progress.wait, "an exit during the wait does not end the countdown")

        progress.apply([event(.verified), event(.forcePending),
                        event(.signaled, pid: 400, state: .stopping, signal: "SIGSTOP"),
                        event(.signaled, pid: 400, state: .forceKilled, signal: "SIGKILL")])
        XCTAssertNil(progress.wait)
        XCTAssertEqual(progress.phase, .forcing(1))
        XCTAssertEqual(progress.headline, "1 process ignored the request; force-stopping it\u{2026}")

        progress.apply(event(.completed))
        XCTAssertEqual(progress.phase, .done)
        XCTAssertEqual(progress.targetStates, [400: .forceKilled, 401: .terminated])
        XCTAssertEqual(progress.recentEvents.count, KillLiveProgress.recentEventLimit)
        XCTAssertEqual(progress.recentEvents.last?.kind, .completed, "newest last, in the order sent")
    }

    func testShortWaitShowsNoIndicator() {
        var progress = KillLiveProgress(displayName: "node", kind: .general, strategy: .standard)
        progress.apply(event(.graceWaiting, wait: 1.5))
        XCTAssertEqual(progress.wait?.showsIndicator, false)
        XCTAssertEqual(progress.headline, "Waiting for node to exit\u{2026}")
    }

    func testQuittingAppSaysSo() {
        var progress = KillLiveProgress(displayName: "Cursor", kind: .editor, strategy: .quitApp)
        progress.apply(event(.signaled, pid: 300, state: .stopping, signal: "Quit"))
        XCTAssertEqual(progress.headline, "Asked Cursor to quit, like \u{2318}Q\u{2026}")
        progress.apply(event(.graceWaiting, wait: 10))
        XCTAssertEqual(progress.headline, "Waiting for Cursor to quit\u{2026}")
    }

    func testRowsTakeTheLiveStateInPlace() {
        var progress = KillLiveProgress(displayName: "vite", kind: .devServer, strategy: .gentleDevServer)
        let row = KillTarget(identity: ProcessIdentity(pid: 100, startTimeSeconds: 1, startTimeMicroseconds: 0), parentPID: 1,
                             name: "vite", ownerName: "me", depth: 0, memoryBytes: 0, cpuPercent: 0, state: .ready,
                             reason: "Owned", isRoot: true)
        progress.apply(event(.signaled, pid: 100, state: .stopping, signal: "SIGINT"))
        let live = progress.rows(for: [row])
        XCTAssertEqual(live.first?.state, .stopping)
        XCTAssertEqual(live.first?.id, row.id)
    }

    func testRealStopFeedsTheWaitDeadline() async {
        let table = FakeProcessTable()
        let postgres = KillProcessLite.fake(pid: 550, name: "postgres")
        table.add(postgres, .exits(on: SIGINT, afterTicks: 4))
        let events = EventLog()

        let report = await table.killer().kill(plan: .fixture(postgres, commands: [550: KillFixture.postgresCommand]),
                                               forceKillDelay: 2, eventSink: { events.append($0) })
        var progress = KillLiveProgress(displayName: report.displayName, kind: .dataStore, strategy: report.strategyUsed)
        progress.apply(events.all.prefix { $0.kind != .verified })

        XCTAssertEqual(progress.wait, KillGraceWait(startedAt: Date(timeIntervalSince1970: 1_000_000),
                                                   deadline: Date(timeIntervalSince1970: 1_000_012)))
        XCTAssertEqual(progress.targetStates[550], .stopping, "asked, not yet seen to exit")
    }

    private func event(
        _ kind: KillOperationEventKind,
        pid: Int32? = nil,
        state: KillTargetState? = nil,
        signal: String? = nil,
        wait: TimeInterval? = nil
    ) -> KillOperationEvent {
        KillOperationEvent(operationID: operation, kind: kind, pid: pid, signalName: signal, targetState: state,
                           message: kind.rawValue, createdAt: start.addingTimeInterval(0.01),
                           waitSeconds: wait, deadline: wait.map { start.addingTimeInterval($0) })
    }
}
