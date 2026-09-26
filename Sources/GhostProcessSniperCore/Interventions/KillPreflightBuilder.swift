import Darwin
import Foundation

struct KillPreflight {
    let preview: KillPreview
    let targets: [KillTarget]
    let locked: [KillTarget]
    let stale: [KillTarget]
    let recycled: [KillTarget]
}

/// Turns a snapshot into the preview a stop is approved from and the target
/// lists a confirmed stop runs against.
struct KillPreflightBuilder: Sendable {
    let currentUserID: UInt32
    let usesDarwinProcessNamespace: Bool
    private let reclaimEstimator = KillReclaimEstimator()
    private let policyEngine = InterventionPolicyEngine()
    private let deltaEngine = KillGraphDeltaEngine()
    private let advisor = KillTargetAdvisor()

    func build(
        plan: KillPlan,
        snapshot: KillProcessSnapshot,
        profile: KillEscalationProfile
    ) -> KillPreflight {
        let index = KillProcessIndex(snapshot: snapshot)
        let arena = snapshot.arena ?? KillGraphArena(
            processes: snapshot.graph?.processes ?? snapshot.processes.map { KillProcessLite(process: $0) },
            sampledAt: snapshot.sampledAt,
            pidReadCount: snapshot.graphReadCount
        )
        let slice = arena.slice(plan: plan, currentUserID: currentUserID)
        let treeIdentities = slice.treeIdentities
        var targets: [KillTarget] = []
        var locked: [KillTarget] = []
        var stale: [KillTarget] = []
        var recycled: [KillTarget] = []
        var seen = Set<ProcessIdentity>()

        if slice.targetMembers.isEmpty && slice.lockedMembers.isEmpty {
            classifyPlanIdentities(plan, index: index, targets: &targets, locked: &locked, stale: &stale, recycled: &recycled, seen: &seen)
        } else {
            for member in slice.targetMembers {
                targets.append(KillTarget(process: member.process, depth: member.depth, state: .ready, reason: "Owned live descendant", rootIdentity: plan.rootIdentity))
                seen.insert(member.process.identity)
            }
            for member in slice.lockedMembers {
                locked.append(KillTarget(process: member.process, depth: member.depth, state: .locked, reason: "Owned by \(member.process.ownerName)", rootIdentity: plan.rootIdentity))
            }
            classifyPlanIdentities(
                plan,
                index: index,
                targets: &targets,
                locked: &locked,
                stale: &stale,
                recycled: &recycled,
                seen: &seen,
                allowReadyOutsideTree: false,
                treeIdentities: treeIdentities
            )
        }

        for pid in plan.protectedPIDs where !locked.contains(where: { $0.pid == pid }) {
            locked.append(
                KillTarget(
                    identity: ProcessIdentity(pid: pid, startTimeSeconds: 0, startTimeMicroseconds: 0),
                    parentPID: nil,
                    name: "Protected PID \(pid)",
                    ownerName: "protected",
                    depth: 0,
                    memoryBytes: 0,
                    cpuPercent: 0,
                    state: .locked,
                    reason: "Protected by source family",
                    isRoot: false
                )
            )
        }

        if let approved = plan.approvedIdentities {
            let additions = targets.filter { !approved.contains($0.identity) }
            locked.append(contentsOf: additions.map { $0.updating(state: .locked, reason: "Not included in the confirmed preview") })
            targets.removeAll { !approved.contains($0.identity) }
        }
        targets = targets.sorted(by: ProcessKiller.signalOrder)
        locked.sort { $0.pid < $1.pid }
        stale.sort { $0.pid < $1.pid }
        recycled.sort { $0.pid < $1.pid }

        let reclaim = reclaimEstimator.estimate(plan: plan, targets: targets)
        let nearby = slice.nearbyCandidates
        let diff = deltaEngine.diff(plan: plan, targets: targets, stale: stale, recycled: recycled, locked: locked, treeIdentities: treeIdentities)
        let scopePreview = KillScopePreview(
            scope: plan.scope,
            targetCount: targets.count,
            lockedCount: locked.count,
            nearbyCandidates: Array(nearby),
            drift: diff,
            summary: "\(targets.count) target\(targets.count == 1 ? "" : "s"), \(locked.count + stale.count + recycled.count) skipped, \(nearby.count) nearby."
        )
        let policy = policyEngine.evaluate(
            plan: plan,
            targets: targets,
            locked: locked,
            stale: stale,
            recycled: recycled,
            reclaim: reclaim,
            diff: diff,
            forceKillDelay: profile.forceKillDelay
        )
        let decisionScore = policy.decisionScore
        let strategy = policy.recommendation
        let strategyProfile = policy.profile
        let readiness = decisionScore.readiness(hasTargets: !targets.isEmpty)
        let performanceReport = KillPerformanceReport(snapshot: snapshot)

        let preview = KillPreview(
            displayName: plan.displayName,
            rootPID: plan.rootIdentity.pid,
            protectedPIDs: plan.protectedPIDs.sorted(),
            forceKillDelay: profile.forceKillDelay,
            targets: targets,
            lockedTargets: locked,
            staleTargets: stale,
            recycledTargets: recycled,
            readiness: readiness,
            usedCheapSnapshot: snapshot.usedCheapPath,
            reclaimEstimate: reclaim,
            scopePreview: scopePreview,
            strategyRecommendation: strategy,
            targetDiff: diff,
            decisionScore: decisionScore,
            strategyProfile: strategyProfile,
            performanceReport: performanceReport,
            strategyForecast: policy.forecast,
            watcherAvailable: !targets.isEmpty && usesDarwinProcessNamespace,
            arenaStats: arena.stats,
            riskAssessment: policy.risk,
            alternatives: advisor.alternatives(plan: plan, arena: arena, targets: targets, risk: policy.risk, currentUserID: currentUserID)
        )
        return KillPreflight(preview: preview, targets: targets, locked: locked, stale: stale, recycled: recycled)
    }

    private func classifyPlanIdentities(
        _ plan: KillPlan,
        index: KillProcessIndex,
        targets: inout [KillTarget],
        locked: inout [KillTarget],
        stale: inout [KillTarget],
        recycled: inout [KillTarget],
        seen: inout Set<ProcessIdentity>,
        allowReadyOutsideTree: Bool = true,
        treeIdentities: Set<ProcessIdentity> = []
    ) {
        for identity in plan.targetIdentities where !seen.contains(identity) {
            guard let process = index.liteProcess(for: identity) else {
                let target = KillTarget(unresolved: identity, state: index.hasRecycledPID(for: identity) ? .recycled : .stale, reason: index.hasRecycledPID(for: identity) ? "PID was reused by another process" : "Identity is no longer live")
                if target.state == .recycled {
                    recycled.append(target)
                } else {
                    stale.append(target)
                }
                continue
            }
            if !allowReadyOutsideTree && !treeIdentities.contains(identity) {
                locked.append(KillTarget(process: process, depth: 0, state: .locked, reason: "Outside selected family tree", rootIdentity: plan.rootIdentity))
                continue
            }
            if process.userID == currentUserID {
                targets.append(KillTarget(process: process, depth: identity == plan.rootIdentity ? 0 : 1, state: .ready, reason: "Owned live plan target", rootIdentity: plan.rootIdentity))
                seen.insert(identity)
            } else {
                locked.append(KillTarget(process: process, depth: 0, state: .locked, reason: "Owned by \(process.ownerName)", rootIdentity: plan.rootIdentity))
            }
        }
    }
}
