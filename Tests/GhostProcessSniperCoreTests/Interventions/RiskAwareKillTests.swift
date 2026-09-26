import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class RiskAwareKillTests: XCTestCase {
    private let app = metrics(300, "Pages", path: "/Applications/Pages.app/Contents/MacOS/Pages")
    private let helper = metrics(301, "Pages Helper", path: "/Applications/Pages.app/Contents/XPCServices/Pages Helper.xpc/Contents/MacOS/Pages Helper", parent: 300)
    private let postgres = metrics(400, "postgres", command: "/opt/homebrew/bin/postgres -D /opt/homebrew/var/postgres")
    private let server = metrics(500, "node", command: "node server.js", parent: 499)

    func testAppsAreQuitLikeCommandQFirst() async {
        let preview = await killer(snapshots: [[app, helper]]).preview(plan: plan(app, members: [app, helper]), forceKillDelay: 2)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .quitApp)
        XCTAssertEqual(preview.strategyProfile.phases.map(\.signalName), ["QUIT", "SIGTERM", "SIGKILL"])
        XCTAssertEqual(preview.riskAssessment.kind, .editor)
        XCTAssertTrue(preview.riskAssessment.forceNeedsConfirmation)
        XCTAssertGreaterThanOrEqual(preview.recommendedGraceSeconds, 8, "apps get time to save")
        XCTAssertTrue(preview.whyWaitEvidence.contains { $0.title == "Unsaved documents" })
    }

    func testQuitRequestReplacesSignalsForTheApp() async {
        let signaler = RecordingSignaler(quits: true)
        let report = await killer(snapshots: [[app, helper], [], []], signaler: signaler)
            .kill(plan: plan(app, members: [app, helper]), forceKillDelay: 2)
        XCTAssertEqual(signaler.quitRequests, [300])
        XCTAssertTrue(signaler.signals.isEmpty, "helpers close with the app; no signal is needed")
        XCTAssertEqual(report.strategyUsed, .quitApp)
        XCTAssertEqual(report.attempts.first?.signalName, "QUIT")
        XCTAssertTrue(report.survivorPIDs.isEmpty)
    }

    func testNonAppsFallBackToSigterm() async {
        let signaler = RecordingSignaler(quits: false)
        _ = await killer(snapshots: [[app, helper], [], []], signaler: signaler)
            .kill(plan: plan(app, members: [app, helper]), forceKillDelay: 2)
        XCTAssertEqual(Set(signaler.signals.map(\.pid)), [300, 301])
        XCTAssertTrue(signaler.signals.allSatisfy { $0.signal == SIGTERM })
    }

    func testDatabasesKeepTheirLongGraceDespiteCalibration() async {
        let learned = KillCalibrationSnapshot(
            signatureID: "postgres", devKind: nil, strategy: .carefulShutdown, operationCount: 8,
            gracefulSuccessRate: 0.95, forceRate: 0, survivorRate: 0, averageGraceSeconds: 0.5,
            reclaimAccuracy: 0.9, denialPenalty: 0, updatedAt: Date(timeIntervalSince1970: 1)
        )
        let preview = await killer(snapshots: [[postgres]])
            .preview(plan: plan(postgres, calibrations: [.carefulShutdown: learned]), forceKillDelay: 2)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .carefulShutdown)
        XCTAssertGreaterThanOrEqual(preview.recommendedGraceSeconds, 12, "learning never cuts a database's shutdown time")
    }

    func testCalibrationOnlyTunesTheStrategyItWasLearnedFrom() async {
        let standardOnly = KillCalibrationSnapshot(
            signatureID: "postgres", devKind: nil, strategy: .standard, operationCount: 5,
            gracefulSuccessRate: 0.2, forceRate: 0.8, survivorRate: 0.1, averageGraceSeconds: 0.5,
            reclaimAccuracy: 0.9, denialPenalty: 0, updatedAt: Date(timeIntervalSince1970: 1)
        )
        let preview = await killer(snapshots: [[postgres]])
            .preview(plan: plan(postgres, calibrations: [.standard: standardOnly]), forceKillDelay: 2)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .carefulShutdown)
        XCTAssertFalse(preview.strategySimulation.summary.contains("Calibrated"), preview.strategySimulation.summary)
    }

    func testSupervisorRestartIsDetectedAndExplained() async {
        let restarted = metrics(777, "node", command: "node server.js", parent: 499,
                                start: UInt64(Date().timeIntervalSince1970) + 5)
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 500, parentPID: 499, name: "node", executablePath: "",
                                            commandLine: "node server.js", isRoot: true)],
            ancestors: [KillWorkloadAncestor(pid: 499, name: "node", executablePath: "/usr/local/bin/node",
                                             commandLine: "node /usr/local/bin/nodemon server.js")],
            parentIsLaunchd: false
        )
        let report = await killer(snapshots: [[server], [], [], [restarted]])
            .kill(plan: plan(server, workload: workload), forceKillDelay: 2)
        XCTAssertEqual(report.respawnedPIDs, [777])
        XCTAssertEqual(report.respawnedBy, "nodemon")
        XCTAssertTrue(report.summary.contains("Stop nodemon instead"), report.summary)
    }

    // MARK: - Fixtures

    private func killer(snapshots: [[ProcessMetrics]], signaler: RecordingSignaler = RecordingSignaler(quits: false)) -> ProcessKiller {
        ProcessKiller(
            snapshotProvider: SequencedSnapshots(snapshots),
            signaler: signaler,
            currentUserID: 501,
            sleeper: { _ in }
        )
    }

    private func plan(
        _ root: ProcessMetrics,
        members: [ProcessMetrics]? = nil,
        workload: KillWorkloadProfile? = nil,
        calibrations: [KillStrategy: KillCalibrationSnapshot] = [:]
    ) -> KillPlan {
        let members = members ?? [root]
        let profile = workload ?? KillWorkloadProfile(
            processes: members.map {
                KillWorkloadProcess(pid: $0.pid, parentPID: $0.parentPID, name: $0.name, executablePath: $0.executablePath,
                                    commandLine: $0.commandLine, isRoot: $0.identity == root.identity)
            },
            ancestors: [],
            parentIsLaunchd: root.parentPID == 1
        )
        return KillPlan(rootIdentity: root.identity, targetIdentities: members.map(\.identity), protectedPIDs: [],
                        displayName: root.name, workload: profile, strategyCalibrations: calibrations)
    }
}

/// Returns each scripted sample once, then repeats the last one.
private actor SequencedSnapshots: KillSnapshotProviding {
    private var remaining: [[ProcessMetrics]]

    init(_ snapshots: [[ProcessMetrics]]) {
        remaining = snapshots
    }

    func snapshot(request: KillSnapshotRequest) async throws -> KillProcessSnapshot {
        let processes = remaining.count > 1 ? remaining.removeFirst() : remaining.first ?? []
        return KillProcessSnapshot(processes: processes, policy: request.policy, usedCheapPath: true, request: request)
    }
}

private final class RecordingSignaler: ProcessSignaling, @unchecked Sendable {
    struct Sent: Equatable {
        let pid: Int32
        let signal: Int32
    }

    private let quits: Bool
    private let lock = NSLock()
    private var sent: [Sent] = []
    private var quitPIDs: [Int32] = []

    init(quits: Bool) {
        self.quits = quits
    }

    var signals: [Sent] { lock.withLock { sent } }
    var quitRequests: [Int32] { lock.withLock { quitPIDs } }

    func send(signal: Int32, to pid: Int32) throws {
        lock.withLock { sent.append(Sent(pid: pid, signal: signal)) }
    }

    func exists(pid: Int32) -> Bool { false }

    func requestQuit(pid: Int32) async -> Bool {
        guard quits else { return false }
        lock.withLock { quitPIDs.append(pid) }
        return true
    }
}

private func metrics(
    _ pid: Int32,
    _ name: String,
    path: String = "",
    command: String? = nil,
    parent: Int32 = 1,
    start: UInt64 = 1_000
) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
        parentPID: parent,
        userID: 501,
        ownerName: "me",
        name: name,
        executablePath: path,
        commandLine: command ?? (path.isEmpty ? name : path),
        residentMemoryBytes: 200_000_000,
        physicalFootprintBytes: 200_000_000,
        virtualMemoryBytes: 400_000_000,
        cpuPercent: 5,
        totalProcessorSeconds: 10,
        threadCount: 4,
        isSystemProcess: false,
        sampledAt: Date()
    )
}
