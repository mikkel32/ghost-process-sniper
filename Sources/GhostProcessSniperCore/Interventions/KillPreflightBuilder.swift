import Darwin
import Foundation

struct KillPreflight {
    let preview: KillPreview
    let targets: [KillTarget]
    let locked: [KillTarget]
    let stale: [KillTarget]
    let recycled: [KillTarget]
    /// Zombies: already exited, so never signalled.
    let exited: [KillTarget]
    let zombieParentName: String?
    /// The children a single-process stop does not touch.
    let leftBehind: [KillTarget]
}

/// Turns a snapshot into the preview a stop is approved from and the target
/// lists a confirmed stop runs against.
struct KillPreflightBuilder: Sendable {
    let currentUserID: UInt32
    let usesDarwinProcessNamespace: Bool
    let protection: KillProtectionPolicy
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
                let reason = member.lockedUnder.map { "Runs under \($0.ownerName)-owned \($0.name) (PID \($0.pid))" }
                    ?? "Owned by \(member.process.ownerName)"
                locked.append(KillTarget(process: member.process, depth: member.depth, state: .locked, reason: reason, rootIdentity: plan.rootIdentity))
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

        let protectionFloor = applyProtection(plan: plan, arena: arena, index: index, targets: &targets, locked: &locked)
        let zombies = separateZombies(arena: arena, index: index, targets: &targets)

        if let approved = plan.approvedIdentities {
            let adopted = adoptions(plan: plan, arena: arena, targets: targets, approved: approved)
            let adoptedIdentities = Set(adopted.map(\.identity))
            let additions = targets.filter { !approved.contains($0.identity) && !adoptedIdentities.contains($0.identity) }
            locked.append(contentsOf: additions.map { $0.updating(state: .locked, reason: "Not included in the confirmed preview") })
            targets = targets.filter { approved.contains($0.identity) } + adopted
        }
        targets = targets.sorted(by: ProcessKiller.signalOrder).map {
            $0.condition == .suspended ? $0.updating(state: .ready, reason: "Suspended (Ctrl-Z) \u{2014} still holds its ports") : $0
        }
        locked.sort { $0.pid < $1.pid }
        stale.sort { $0.pid < $1.pid }
        recycled.sort { $0.pid < $1.pid }

        let (measured, usedRadarMemory) = reclaimEstimator.takingRadarMemory(targets, plan: plan)
        targets = measured
        let reclaim = reclaimEstimator.estimate(plan: plan, targets: targets, usedRadarMemory: usedRadarMemory)
        let radarCPU = KillReclaimEstimator.radarCPU(plan)
        targets = targets.map { target in
            guard target.cpuPercent <= 0, let reading = radarCPU[target.identity] else { return target }
            return target.updating(cpuPercent: reading)
        }
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
        var strategy = policy.recommendation
        var strategyProfile = policy.profile
        var forecast = policy.forecast
        // The floor's warnings are risk cards too, each replacing the
        // assessor's card of its kind; as factors they weigh on readiness
        // like the assessor's own.
        let replaced = policy.risk.risks.filter { risk in protectionFloor.cautions.contains { $0.kind == risk.kind } }
        let appQuits = policy.risk.appQuitPID == plan.rootIdentity.pid
        let children = targets.isEmpty ? KillLeftBehind.none : leftBehind(plan: plan, arena: arena, appQuits: appQuits)
        // A quitting app takes its helpers along, so only other stops warn.
        let leavesChildren = appQuits ? nil : leavesChildrenRisk(children, plan: plan)
        let notes = protectionFloor.cautions + [leavesChildren].compactMap { $0 }
        var decisionScore = policy.decisionScore.removing { factor in
            factor.source == .risk && replaced.contains { $0.title == factor.title && $0.detail == factor.detail }
        }.adding(notes.map {
            KillDecisionFactor(kind: .whyWait, title: $0.title, detail: $0.detail, weight: $0.severity == .info ? -1 : -6, source: .risk)
        })
        if targets.contains(where: { $0.condition == .suspended }) {
            // Worth knowing, not worth waiting for: the stop resumes it.
            decisionScore = decisionScore.adding([KillDecisionFactor(kind: .whyWait, title: "Paused job (Ctrl-Z)",
                                                                     detail: "Ghost resumes it so it can exit cleanly.", weight: 0)])
        }
        if let reason = protectionFloor.rootReason {
            // Stopping the rest of the tree without its root is not what
            // anyone asked for, so the whole plan becomes inspect-only.
            strategy = KillStrategyRecommendation(strategy: .inspectOnly, confidence: 1, reasons: [reason], previewText: reason)
            strategyProfile = KillStrategyProfile(strategy: .inspectOnly, confidence: 1, phases: [], summary: reason)
            forecast = .none
            decisionScore = decisionScore.adding([KillDecisionFactor(kind: .blocking, title: "Protected", detail: reason, weight: -35)])
        }
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
            exitedTargets: zombies.exited,
            readiness: readiness,
            usedCheapSnapshot: snapshot.usedCheapPath,
            reclaimEstimate: reclaim,
            scopePreview: scopePreview,
            strategyRecommendation: strategy,
            targetDiff: diff,
            decisionScore: decisionScore,
            strategyProfile: strategyProfile,
            performanceReport: performanceReport,
            strategyForecast: forecast,
            watcherAvailable: !targets.isEmpty && usesDarwinProcessNamespace,
            arenaStats: arena.stats,
            riskAssessment: policy.risk.merging(notes, headline: protectionFloor.rootReason),
            alternatives: advisor.alternatives(plan: plan, arena: arena, targets: targets, risk: policy.risk, currentUserID: currentUserID),
            launchdJob: plan.workload?.launchdJob,
            leftBehind: children.targets
        )
        return KillPreflight(preview: preview, targets: targets, locked: locked, stale: stale, recycled: recycled,
                             exited: zombies.exited, zombieParentName: zombies.parentName, leftBehind: children.targets)
    }

    /// Children an approved process started after the preview stop with it;
    /// anything older was shown in the preview, or deliberately left out.
    private func adoptions(
        plan: KillPlan,
        arena: KillGraphArena,
        targets: [KillTarget],
        approved: Set<ProcessIdentity>
    ) -> [KillTarget] {
        guard plan.scope != .singleRoot, let approvedAt = plan.approvedAt else { return [] }
        let candidates = Set(targets.map(\.identity)).subtracting(approved)
        guard !candidates.isEmpty else { return [] }
        return KillTreeSweeper.lateMembers(
            arena: arena,
            anchors: targets.filter { approved.contains($0.identity) },
            known: approved,
            bornAfter: approvedAt,
            currentUserID: currentUserID,
            protection: protection,
            rootIdentity: plan.rootIdentity,
            startedWhen: "after the preview"
        )
        .filter { candidates.contains($0.identity) }
        .prefix(32)
        .map { $0 }
    }

    /// Moves every target below the protection floor to `locked` and
    /// collects the warnings for the rest; the root's warning comes first.
    private func applyProtection(
        plan: KillPlan,
        arena: KillGraphArena,
        index: KillProcessIndex,
        targets: inout [KillTarget],
        locked: inout [KillTarget]
    ) -> (rootReason: String?, cautions: [KillRisk]) {
        let workload = Dictionary((plan.workload?.processes ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let chain = protection.selfAndAncestors { arena.processes(for: $0).first?.parentPID }
        var rootReason: String?
        var cautions: [KillRisk] = []
        var protected = Set<ProcessIdentity>()
        for target in targets {
            guard let process = arena.process(for: target.identity) ?? index.liteProcess(for: target.identity) else { continue }
            let known = workload[target.pid]
            switch protection.verdict(for: process, executablePath: known?.executablePath, commandLine: known?.commandLine,
                                      arena: arena, selfAndAncestors: chain) {
            case .never(let reason):
                locked.append(target.updating(state: .locked, reason: reason))
                protected.insert(target.identity)
                if target.identity == plan.rootIdentity { rootReason = reason }
            case .caution(let risk):
                if target.identity == plan.rootIdentity { cautions.insert(risk, at: 0) } else { cautions.append(risk) }
            case nil:
                break
            }
        }
        targets.removeAll { protected.contains($0.identity) }
        var seenKinds = Set<KillRiskKind>()
        return (rootReason, cautions.filter { seenKinds.insert($0.kind).inserted })
    }

    /// A zombie has already exited: a signal does nothing, and only its
    /// parent collecting it makes it disappear.
    private func separateZombies(
        arena: KillGraphArena,
        index: KillProcessIndex,
        targets: inout [KillTarget]
    ) -> (exited: [KillTarget], parentName: String?) {
        var exited: [KillTarget] = []
        var parentName: String?
        for target in targets {
            guard let process = arena.process(for: target.identity) ?? index.liteProcess(for: target.identity),
                  process.isZombie else { continue }
            let parent = arena.processes(for: process.parentPID).first
            let name = parent?.name ?? "its parent"
            let pidText = parent.map { " (PID \($0.pid))" } ?? ""
            exited.append(target.updating(
                state: .exitedBeforeSignal,
                reason: "Already exited; its parent \(name)\(pidText) has not collected it. It disappears when \(name) exits or collects it \u{2014} stop \(name) to clear it."
            ))
            parentName = parentName ?? name
        }
        let zombieIdentities = Set(exited.map(\.identity))
        targets.removeAll { zombieIdentities.contains($0.identity) }
        return (exited, parentName)
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
