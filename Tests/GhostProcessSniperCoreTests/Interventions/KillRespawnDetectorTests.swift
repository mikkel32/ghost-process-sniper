import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A restart is a new process with the stopped one's name that the
/// supervisor itself started after the stop, not any `node` that appears.
final class KillRespawnDetectorTests: XCTestCase {
    private let stopAt = Date(timeIntervalSince1970: 2_000)
    private let pm2 = KillSupervisor(pid: 499, name: "PM2", kind: .pm2)
    private lazy var stopped = KillTarget(process: lite(500, parent: 499, start: 1_000), depth: 0, state: .ready,
                                          reason: "fixture", rootIdentity: lite(500, parent: 499, start: 1_000).identity)

    func testUnrelatedSameNameProcessUnderLaunchdIsNotReported() {
        XCTAssertTrue(respawned([lite(900, parent: 1, start: 2_001)], by: pm2).isEmpty)
    }

    func testProcessStartedJustBeforeTheStopIsNotReported() {
        let early = lite(901, parent: 499, start: 1_999, micro: 500_000)
        XCTAssertTrue(respawned([early], by: pm2).isEmpty, "0.5 s before the last signal is not a restart")
    }

    func testRespawnThroughAShellIsReported() {
        let shell = lite(902, parent: 499, start: 2_000, name: "sh")
        let node = lite(903, parent: 902, start: 2_000, micro: 200_000)
        XCTAssertEqual(respawned([shell, node], by: pm2).map(\.pid), [903])
    }

    func testLaunchdAgentRespawnIsReported() {
        let launchd = KillSupervisor(pid: nil, name: "launchd", kind: .launchd)
        XCTAssertEqual(respawned([lite(904, parent: 1, start: 2_003)], by: launchd).map(\.pid), [904])
    }

    func testOtherUsersAndTheStoppedProcessItselfAreNotReported() {
        let foreign = lite(905, parent: 499, start: 2_003, userID: 0)
        XCTAssertTrue(respawned([foreign, lite(500, parent: 499, start: 1_000)], by: pm2).isEmpty)
    }

    func testOnlyRestartingSupervisorsAreProbed() {
        XCTAssertEqual(KillSupervisorKind.pm2.restartPolicy, .onExit)
        XCTAssertEqual(KillSupervisorKind.launchd.restartPolicy, .onExit)
        XCTAssertEqual(KillSupervisorKind.nodemon.restartPolicy, .onFileChange)
        XCTAssertEqual(KillSupervisorKind.watchexec.restartPolicy, .onFileChange)
        XCTAssertEqual(KillSupervisorKind.overmind.restartPolicy, .stopsSiblings)
    }

    // MARK: - Fixtures

    private func respawned(_ lites: [KillProcessLite], by supervisor: KillSupervisor) -> [KillProcessLite] {
        KillRespawnDetector.respawned(in: lites, targets: [stopped], supervisor: supervisor, since: stopAt, currentUserID: 501)
    }

    private func lite(_ pid: Int32, parent: Int32, start: UInt64, micro: UInt64 = 0, name: String = "node", userID: UInt32 = 501) -> KillProcessLite {
        KillProcessLite(identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: micro),
                        parentPID: parent, userID: userID, ownerName: "me", name: name, status: 2, flags: 0,
                        processGroupID: pid, openFileCount: 0)
    }
}
