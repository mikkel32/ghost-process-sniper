import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class KillOutcomeVerifierTests: XCTestCase {
    private let operationStart = Date(timeIntervalSince1970: 2_000_000)
    private let stoppedRoot = ProcessIdentity(pid: 700, startTimeSeconds: 1_000, startTimeMicroseconds: 0)

    func testPortWithNoHolderIsFree() {
        let arena = arena([lite(pid: 500, name: "Finder", group: 500)])
        let probe = FakeListeningPortProbe()

        XCTAssertEqual(verify([5173], arena: arena, probe: probe), [.freed(5173)])
        XCTAssertTrue(probe.probedPIDs.isEmpty, "an unrelated older process is not a likely holder")
    }

    func testOrphanInTheStoppedGroupStillHoldsThePort() {
        let orphan = lite(pid: 720, name: "vite", group: 700, start: 2_000_001)
        let probe = FakeListeningPortProbe([720: [5173, 24678]])

        XCTAssertEqual(verify([5173, 3000], arena: arena([orphan]), probe: probe),
                       [.freed(3000), .heldBy(port: 5173, pid: 720, name: "vite", startedDuringStop: true)])
    }

    func testOlderNamesakeHoldsThePortButDidNotStartDuringTheStop() {
        let namesake = lite(pid: 612, name: "node", group: 612)
        let probe = FakeListeningPortProbe([612: [3000]])

        let outcomes = verify([3000], arena: arena([namesake]), probe: probe, stoppedNames: ["node"])

        XCTAssertEqual(outcomes, [.heldBy(port: 3000, pid: 612, name: "node", startedDuringStop: false)])
        XCTAssertEqual(outcomes.first?.text, "Port 3000 is still held by node (PID 612).")
    }

    func testLikelyHoldersAreReadFirst() {
        let processes = [
            lite(pid: 612, name: "node", group: 612),
            lite(pid: 640, name: "esbuild", group: 640, start: 2_000_002),
            lite(pid: 721, name: "vite", group: 700, parent: 650),
            lite(pid: 720, name: "vite", group: 700),
            lite(pid: 800, name: "node", group: 800, user: 0)
        ]
        let probe = FakeListeningPortProbe()

        XCTAssertEqual(verify([5173], arena: arena(processes), probe: probe, stoppedNames: ["node"]), [.freed(5173)])
        XCTAssertEqual(probe.probedPIDs, [720, 721, 640, 612], "orphans of the group, the rest of the group, newcomers, namesakes; never another user's")
    }

    func testStoppedTargetsAreNotCandidates() {
        let stillListed = KillProcessLite(identity: stoppedRoot, parentPID: 1, userID: 501, ownerName: "me", name: "vite",
                                          status: 2, flags: 0, processGroupID: 700, openFileCount: 4)
        let probe = FakeListeningPortProbe([700: [5173]])

        XCTAssertEqual(verify([5173], arena: arena([stillListed]), probe: probe), [.freed(5173)])
    }

    func testExhaustedBudgetLeavesThePortUnverified() {
        let orphan = lite(pid: 720, name: "vite", group: 700)
        let probe = FakeListeningPortProbe()

        XCTAssertEqual(verify([5173], arena: arena([orphan]), probe: probe, budget: 0), [.unverified(5173)])
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    func testProcessCapLeavesThePortUnverified() {
        let processes = (0..<5).map { lite(pid: 720 + Int32($0), name: "vite", group: 700) }
        let probe = FakeListeningPortProbe()

        let outcomes = verify([5173], arena: arena(processes), probe: probe, maxProcesses: 3)

        XCTAssertEqual(outcomes, [.unverified(5173)])
        XCTAssertEqual(outcomes.first?.text, "Port 5173 should now be free.")
        XCTAssertEqual(probe.probedPIDs.count, 3)
    }

    func testUnreadableCandidateLeavesThePortUnverified() {
        let probe = FakeListeningPortProbe([720: nil])

        XCTAssertEqual(verify([5173], arena: arena([lite(pid: 720, name: "vite", group: 700)]), probe: probe), [.unverified(5173)])
    }

    func testScanStopsOnceEveryPortHasAHolder() {
        let processes = [lite(pid: 720, name: "vite", group: 700), lite(pid: 721, name: "vite", group: 700)]
        let probe = FakeListeningPortProbe([721: [5173]])

        XCTAssertEqual(verify([5173], arena: arena(processes), probe: probe),
                       [.heldBy(port: 5173, pid: 721, name: "vite", startedDuringStop: false)])
        XCTAssertEqual(probe.probedPIDs, [721])
    }

    // MARK: - Engine

    func testStopConfirmsItsPortIsFree() async {
        let table = FakeProcessTable()
        let vite = KillProcessLite.fake(pid: 700, name: "vite")
        table.add(vite)
        let probe = FakeListeningPortProbe()

        let report = await killer(table, probe).kill(plan: plan(vite, ports: [5173]), forceKillDelay: 2)

        XCTAssertTrue(report.succeeded, report.summary)
        XCTAssertEqual(report.portOutcomes, [.freed(5173)])
        XCTAssertTrue(report.eventHistory.contains { $0.message == "Port 5173 is free." })
    }

    func testStopNamesTheEscapedChildThatKeptThePort() async {
        let table = FakeProcessTable()
        // A daemonized child: its own session, adopted by launchd, holding
        // the inherited listening socket.
        let escaped = KillProcessLite.fake(pid: 740, name: "vite", start: UInt64(Date().timeIntervalSince1970) + 60)
        let vite = KillProcessLite.fake(pid: 700, name: "vite")
        let escapes: [FakeProcessTable.Reaction] = [.forkChild(escaped, afterTicks: 0), .exit(afterTicks: 1)]
        table.add(vite, FakeProcessTable.Behaviour(onSignal: [SIGINT: escapes, SIGTERM: escapes]))
        let probe = FakeListeningPortProbe([740: [5173]])

        let report = await killer(table, probe).kill(plan: plan(vite, ports: [5173]), forceKillDelay: 2)

        XCTAssertTrue(report.survivorPIDs.isEmpty, report.summary)
        XCTAssertEqual(report.portOutcomes, [.heldBy(port: 5173, pid: 740, name: "vite", startedDuringStop: true)])
        XCTAssertEqual(report.portOutcomes.first?.text, "Port 5173 is still held by vite (PID 740), started during the stop.")
    }

    func testStopWithoutPortsReadsNoSockets() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 700, name: "worker")
        table.add(worker)
        let probe = FakeListeningPortProbe()

        let report = await killer(table, probe).kill(plan: plan(worker, ports: []), forceKillDelay: 2)

        XCTAssertTrue(report.portOutcomes.isEmpty)
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    // MARK: - Fixtures

    private func verify(
        _ ports: [Int],
        arena: KillGraphArena,
        probe: FakeListeningPortProbe,
        stoppedNames: Set<String> = ["vite"],
        maxProcesses: Int = 64,
        budget: TimeInterval = 10
    ) -> [KillPortOutcome] {
        KillOutcomeVerifier().verifyPorts(
            ports, arena: arena, stopped: [stoppedRoot], stoppedNames: stoppedNames, targetGroups: [700],
            operationStart: operationStart, currentUserID: 501, probe: probe, maxProcesses: maxProcesses, budget: budget
        )
    }

    private func arena(_ processes: [KillProcessLite]) -> KillGraphArena {
        KillGraphArena(processes: processes, sampledAt: operationStart.addingTimeInterval(5))
    }

    private func lite(
        pid: Int32,
        name: String,
        group: Int32,
        parent: Int32 = 1,
        start: UInt64 = 1_500,
        user: UInt32 = 501
    ) -> KillProcessLite {
        KillProcessLite(identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
                        parentPID: parent, userID: user, ownerName: user == 501 ? "me" : "root", name: name,
                        status: 2, flags: 0, processGroupID: group, openFileCount: 4)
    }

    private func killer(_ table: FakeProcessTable, _ probe: FakeListeningPortProbe) -> ProcessKiller {
        ProcessKiller(snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper, portProbe: probe)
    }

    private func plan(_ root: KillProcessLite, ports: [Int]) -> KillPlan {
        let path = "/usr/local/bin/\(root.name)"
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: root.pid, parentPID: root.parentPID, name: root.name, executablePath: path,
                                            commandLine: path, listeningPorts: ports, isRoot: true)],
            ancestors: [],
            parentIsLaunchd: false
        )
        return KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity], protectedPIDs: [],
                        displayName: root.name, workload: workload)
    }
}
