import Darwin
import Foundation
@testable import GhostProcessSniperCore

/// One owned target with a workload, radar state and history, evaluated
/// by the policy engine as a preview would.
enum PolicyFixture {
    static func evaluate(
        command: String,
        name: String,
        memory: UInt64 = 200_000_000,
        cpu: Double = 5,
        history: KillHistorySummary? = nil,
        level: GhostLevel = .watch,
        forecast: ForecastState = .quiet,
        label: String = "Process family",
        reason: String = "",
        parent: Int32 = 700,
        path: String = "",
        locked: [KillTarget] = [],
        forceKillDelay: TimeInterval = 2
    ) -> InterventionPolicyEvaluation {
        let identity = ProcessIdentity(pid: 800, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let lite = KillProcessLite(identity: identity, parentPID: parent, userID: 501, ownerName: "me", name: name, status: 2,
                                   flags: 0, processGroupID: 800, openFileCount: 0, physicalFootprintBytes: memory, cpuPercent: cpu)
        let target = KillTarget(process: lite, depth: 0, state: .ready, reason: "owned", rootIdentity: identity)
        let metadata = KillFamilyMetadata(signatureID: "sig", displayName: name, scoreValue: 90, scoreLevel: level,
                                          forecastState: forecast, devKindLabel: label, memoryBytes: memory,
                                          cpuPercent: cpu, childCount: 0, forecastReason: reason)
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 800, parentPID: parent, name: name, executablePath: path, commandLine: command, isRoot: true)],
            ancestors: [], parentIsLaunchd: parent == 1
        )
        let plan = KillPlan(rootIdentity: identity, targetIdentities: [identity], protectedPIDs: [], displayName: name,
                            familyMetadata: metadata, killHistory: history, workload: workload)
        return InterventionPolicyEngine().evaluate(
            plan: plan, targets: [target], locked: locked, stale: [], recycled: [],
            reclaim: KillReclaimEstimate(memoryBytes: memory, cpuPercent: cpu, confidence: 0.8, sourceText: "test"),
            diff: .empty, forceKillDelay: forceKillDelay
        )
    }
}
