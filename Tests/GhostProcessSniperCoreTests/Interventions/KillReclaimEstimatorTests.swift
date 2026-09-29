import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// What a stop gives back: memory measured now, and CPU from the radar's
/// last scan (a kill snapshot cannot measure CPU). Memory the snapshot did
/// not get to measure comes from the radar too, and nothing a supervisor
/// immediately takes again is counted.
final class KillReclaimEstimatorTests: XCTestCase {
    private let estimator = KillReclaimEstimator()
    private let identity = ProcessIdentity(pid: 1600, startTimeSeconds: 1_000, startTimeMicroseconds: 0)

    func testLiteTargetsWithoutCPUTakeTheRadarCPU() {
        let estimate = estimator.estimate(plan: plan(radarCPU: 90, for: identity), targets: [target(cpu: 0)])

        XCTAssertEqual(estimate.cpuPercent, 90)
        XCTAssertEqual(estimate.memoryBytes, 200_000_000)
        XCTAssertEqual(estimate.sourceText, "Memory now, CPU from the last scan")
    }

    func testRadarCPUNeedsTheSameProcess() {
        let reused = ProcessIdentity(pid: 1600, startTimeSeconds: 1_001, startTimeMicroseconds: 0)
        let estimate = estimator.estimate(plan: plan(radarCPU: 90, for: reused), targets: [target(cpu: 0)])

        XCTAssertEqual(estimate.cpuPercent, 0, "a reused PID is another process")
    }

    func testMeasuredCPUWins() {
        XCTAssertEqual(estimator.estimate(plan: plan(radarCPU: 90, for: identity), targets: [target(cpu: 12)]).cpuPercent, 12)
    }

    func testRespawnIsSubtractedFromRealizedReclaim() {
        let stopped = target(cpu: 0).updating(state: .terminated, reason: "fixture")
        let estimate = KillReclaimEstimate(memoryBytes: 200_000_000, cpuPercent: 0, confidence: 0.8, sourceText: "fixture")

        XCTAssertEqual(estimator.realizedEstimate(from: estimate, targets: [stopped]), 200_000_000)
        XCTAssertEqual(estimator.realizedEstimate(from: estimate, targets: [stopped], respawnedNames: ["node"]), 0,
                       "the restarted copy takes the memory back")
    }

    func testPreviewShowsTheRadarCPUOfARunaway() async {
        let table = FakeProcessTable()
        let runaway = KillProcessLite.fake(pid: 1610, name: "node")
        table.add(runaway)
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 1610, name: "node", executablePath: "", commandLine: "node spin.js",
                                            isRoot: true, identity: runaway.identity, cpuPercent: 250)],
            ancestors: [], parentIsLaunchd: true
        )
        let plan = KillPlan(rootIdentity: runaway.identity, targetIdentities: [runaway.identity], protectedPIDs: [],
                            displayName: "node", workload: workload)

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.estimatedCPUReclaimPercent, 250)
        XCTAssertEqual(preview.targets.first?.cpuPercent, 250, "the row shows it too")
    }

    func testTargetsTheKillSnapshotDidNotMeasureTakeTheRadarMemory() async {
        // In a big tree the snapshot's read budget runs out: this row says 0.
        let table = FakeProcessTable()
        let unread = KillProcessLite.fake(pid: 1620, name: "node", memory: 0)
        table.add(unread)

        let preview = await table.killer().preview(plan: radarPlan(for: unread, radarIdentity: unread.identity, memory: 300_000_000),
                                                   forceKillDelay: 2)

        XCTAssertEqual(preview.estimatedMemoryReclaimBytes, 300_000_000)
        XCTAssertEqual(preview.targets.first?.memoryBytes, 300_000_000, "the row shows it too")
        XCTAssertEqual(preview.reclaimEstimate.sourceText, "Memory now (some from the last scan)")
    }

    func testRadarMemoryNeedsTheSameProcess() async {
        let table = FakeProcessTable()
        let unread = KillProcessLite.fake(pid: 1621, name: "node", memory: 0)
        table.add(unread)
        let reused = ProcessIdentity(pid: 1621, startTimeSeconds: 1_001, startTimeMicroseconds: 0)

        let preview = await table.killer().preview(plan: radarPlan(for: unread, radarIdentity: reused, memory: 300_000_000),
                                                   forceKillDelay: 2)

        XCTAssertEqual(preview.estimatedMemoryReclaimBytes, 0, "a reused PID is another process")
        XCTAssertEqual(preview.targets.first?.memoryBytes, 0)
    }

    func testMeasuredMemoryWinsOverTheRadar() async {
        let table = FakeProcessTable()
        let measured = KillProcessLite.fake(pid: 1622, name: "node", memory: 200_000_000)
        table.add(measured)

        let preview = await table.killer().preview(plan: radarPlan(for: measured, radarIdentity: measured.identity, memory: 300_000_000),
                                                   forceKillDelay: 2)

        XCTAssertEqual(preview.estimatedMemoryReclaimBytes, 200_000_000)
        XCTAssertEqual(preview.reclaimEstimate.sourceText, "Current owned target footprint")
    }

    func testReadAndUnreadTargetsAddUpAndSayWhereEachCameFrom() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 1623, name: "node", memory: 200_000_000)
        let unread = KillProcessLite.fake(pid: 1624, parent: 1623, name: "worker", memory: 0)
        table.add(root)
        table.add(unread)
        let workload = KillWorkloadProfile(
            processes: [
                KillWorkloadProcess(pid: 1623, name: "node", executablePath: "", commandLine: "node work.js", isRoot: true,
                                    identity: root.identity, memoryBytes: 180_000_000),
                KillWorkloadProcess(pid: 1624, parentPID: 1623, name: "worker", executablePath: "", commandLine: "worker",
                                    identity: unread.identity, cpuPercent: 40, memoryBytes: 300_000_000)
            ],
            ancestors: [], parentIsLaunchd: true
        )
        let plan = KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity, unread.identity], protectedPIDs: [],
                            displayName: "node", workload: workload)

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.estimatedMemoryReclaimBytes, 500_000_000, "the root as measured now, the worker as last seen")
        XCTAssertEqual(preview.estimatedCPUReclaimPercent, 40)
        XCTAssertEqual(preview.reclaimEstimate.sourceText, "Memory now (some from the last scan), CPU from the last scan")
    }

    // MARK: - Fixtures

    /// A plan for `process` whose radar workload knows `radarIdentity` at `memory`.
    private func radarPlan(for process: KillProcessLite, radarIdentity: ProcessIdentity, memory: UInt64) -> KillPlan {
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: process.pid, name: "node", executablePath: "", commandLine: "node work.js",
                                            isRoot: true, identity: radarIdentity, memoryBytes: memory)],
            ancestors: [], parentIsLaunchd: true
        )
        return KillPlan(rootIdentity: process.identity, targetIdentities: [process.identity], protectedPIDs: [],
                        displayName: "node", workload: workload)
    }

    private func target(cpu: Double) -> KillTarget {
        KillTarget(identity: identity, parentPID: 1, name: "node", ownerName: "me", depth: 0, memoryBytes: 200_000_000,
                   cpuPercent: cpu, state: .ready, reason: "fixture", isRoot: true)
    }

    private func plan(radarCPU: Double, for identity: ProcessIdentity) -> KillPlan {
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: identity.pid, name: "node", executablePath: "", commandLine: "node spin.js",
                                            isRoot: true, identity: identity, cpuPercent: radarCPU)],
            ancestors: [], parentIsLaunchd: false
        )
        return KillPlan(rootIdentity: self.identity, targetIdentities: [self.identity], protectedPIDs: [], displayName: "node",
                        workload: workload)
    }
}
