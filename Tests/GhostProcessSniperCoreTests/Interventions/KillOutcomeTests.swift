import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// What a stop reports must match what happened to each process.
final class KillOutcomeTests: XCTestCase {
    func testRefusedSignalIsTriedOnceAndExplained() async {
        let table = FakeProcessTable()
        let agent = KillProcessLite.fake(pid: 500, name: "agent")
        table.add(agent, FakeProcessTable.Behaviour(deniesSignals: true))

        let report = await table.killer().kill(plan: .fixture(agent), forceKillDelay: 2)

        XCTAssertEqual(table.signals(to: 500).count, 1, "EPERM will not change on a retry")
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        XCTAssertEqual(report.deniedPIDs, [500])
        XCTAssertTrue(report.summary.contains("refused"), report.summary)
        XCTAssertLessThan(table.elapsedSeconds, 2, "nothing is left to wait for")
        XCTAssertEqual(report.targetResults.first { $0.pid == 500 }?.state, .locked)
    }

    func testZombieOnlyTargetIsNeitherSignalledNorASurvivor() async {
        let table = FakeProcessTable()
        let parent = KillProcessLite.fake(pid: 600, name: "buggyparent")
        let zombie = KillProcessLite.fake(pid: 601, parent: 600, name: "worker", status: FakeProcessTable.zombieStatus)
        table.add(parent, .ignoresTermination)
        table.add(zombie)

        let report = await table.killer().kill(plan: .fixture(zombie), forceKillDelay: 2)

        XCTAssertTrue(table.log.isEmpty)
        XCTAssertEqual(table.tick, 0, "no grace period for a process that already exited")
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        let result = report.targetResults.first { $0.pid == 601 }
        XCTAssertEqual(result?.state, .exitedBeforeSignal)
        XCTAssertTrue(result?.reason.contains("buggyparent") == true, result?.reason ?? "")
    }

    func testChildThatTurnsZombieIsNotForced() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 610, name: "runner")
        let child = KillProcessLite.fake(pid: 611, parent: 610, name: "worker")
        table.add(root, .ignoresTermination)
        table.add(child, FakeProcessTable.Behaviour(zombieOnExit: true))

        let report = await table.killer().kill(plan: .fixture(root, members: [root, child]), forceKillDelay: 0.2)

        XCTAssertEqual(table.signals(to: 611), [SIGTERM], "a zombie has nothing left to kill")
        XCTAssertEqual(table.signals(to: 610), [SIGTERM, SIGKILL])
        XCTAssertTrue(report.survivorPIDs.isEmpty)
        XCTAssertEqual(report.targetResults.first { $0.pid == 611 }?.state, .terminated)
    }

    func testTargetRowsAreNotQueuedOneByOne() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 620, name: "runner")
        let children = [KillProcessLite.fake(pid: 621, parent: 620), KillProcessLite.fake(pid: 622, parent: 620)]
        table.add(root)
        children.forEach { table.add($0) }
        let events = EventLog()

        _ = await table.killer().kill(plan: .fixture(root, members: [root] + children), forceKillDelay: 1,
                                      eventSink: { events.append($0) })

        let beforeSignals = events.all.prefix { $0.kind != .signaled }
        XCTAssertEqual(beforeSignals.filter { $0.kind == .queued }.count, 1)
        XCTAssertFalse(beforeSignals.contains { $0.kind == .targetUpdated }, "one queued event instead of one per target")
        XCTAssertTrue(events.all.filter { $0.kind == .signaled }.allSatisfy { $0.targetState == .stopping },
                      "a row is stopping, not terminated, until the process is gone")
    }

    func testChangedProcessNeedsAFreshPreview() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 650, name: "cruncher")
        table.add(worker)
        let rough = KillHistorySummary(signatureID: "cruncher", operationCount: 4, gracefulSuccessRate: 0.2, forceRate: 0.2,
                                       survivorRate: 0.6, averageReclaimBytes: 0, commonDenialCount: 0)
        let approved = KillPlan.fixture(worker).binding(to: [worker.identity], expiresAt: Date().addingTimeInterval(60), profile: .standard)
        let changed = KillPlan(rootIdentity: worker.identity, targetIdentities: [worker.identity], protectedPIDs: [],
                               displayName: "cruncher", killHistory: rough, approvedIdentities: approved.approvedIdentities,
                               approvalExpiresAt: approved.approvalExpiresAt, approvedProfile: approved.approvedProfile)

        let report = await table.killer().kill(plan: changed, forceKillDelay: 1)

        XCTAssertTrue(table.log.isEmpty)
        XCTAssertTrue(report.failures.first?.hasPrefix("This process changed since the preview (") == true, report.summary)
        XCTAssertTrue(report.failures.first?.hasSuffix("Review it again.") == true, report.summary)
    }

    func testOwnSignalsDoNotForceFullVerification() {
        let identity = ProcessIdentity(pid: 630, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let exit = KillWatcherHint(operationID: KillOperationID(), pid: 630, identity: identity, kind: .exit, message: "exit")
        let fork = KillWatcherHint(operationID: KillOperationID(), pid: 630, identity: identity, kind: .fork, message: "fork")

        XCTAssertEqual(KillVerificationPlanner().mode(stage: "pre-force", hints: [exit]), .targetOnly)
        XCTAssertEqual(KillVerificationPlanner().mode(stage: "pre-force", hints: [exit, fork]), .eventTriggeredComplete)
    }

    func testReusedPIDIsNeverSignalled() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 640, name: "cruncher")
        table.add(worker, .ignoresTermination)
        let killer = ProcessKiller(snapshotProvider: table, signaler: RecyclingSignaler(table: table, recycledPID: 640),
                                   currentUserID: 501, sleeper: table.sleeper, clock: table.now)

        let report = await killer.kill(plan: .fixture(worker), forceKillDelay: 1)

        XCTAssertTrue(table.log.isEmpty, "the identity check runs right before the signal")
        XCTAssertEqual(report.recycledPIDs, [640])
        XCTAssertEqual(report.targetResults.first { $0.pid == 640 }?.state, .recycled)
        XCTAssertFalse(report.attempts.contains { $0.succeeded })
        XCTAssertTrue(report.stalePIDs.isEmpty)
    }
}

/// Reports one PID as taken over by another process at signal time, the
/// way the Darwin signaler does after comparing start times.
private struct RecyclingSignaler: ProcessSignaling {
    let table: FakeProcessTable
    let recycledPID: Int32

    func send(signal: Int32, to pid: Int32) throws {
        try table.send(signal: signal, to: pid)
    }

    func send(signal: Int32, to identity: ProcessIdentity) throws {
        guard identity.pid != recycledPID else {
            throw SignalFailure(pid: identity.pid, signal: signal, errnoCode: ESRCH,
                                message: "PID was reused by another process", isRecycled: true)
        }
        try table.send(signal: signal, to: identity.pid)
    }

    func exists(pid: Int32) -> Bool {
        table.exists(pid: pid)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [KillOperationEvent] = []

    var all: [KillOperationEvent] { lock.withLock { events } }

    func append(_ event: KillOperationEvent) {
        lock.withLock { events.append(event) }
    }
}
