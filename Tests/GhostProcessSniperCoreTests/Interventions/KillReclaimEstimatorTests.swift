import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// What a stop gives back: memory measured now, CPU from the radar's last
/// scan (a kill snapshot cannot measure CPU), and nothing a supervisor
/// immediately takes again.
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

    // MARK: - Fixtures

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
