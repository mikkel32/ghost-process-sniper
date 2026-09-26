import Darwin
import Foundation

/// What the force stage froze and killed.
struct KillForceOutcome {
    /// Every process stopped with SIGSTOP, then sent SIGKILL.
    let frozen: [KillTarget]
    /// Processes born while the tree was frozen.
    let newborn: [KillTarget]
    /// Refused by macOS or recycled: never reachable.
    let dropped: Set<ProcessIdentity>
}

extension ProcessKiller {
    /// SIGKILL cannot be caught, so there is no reason to go child first;
    /// parent first means no respawner inside the tree sees a child die.
    static func forceOrder(_ lhs: KillTarget, _ rhs: KillTarget) -> Bool {
        if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        return lhs.pid < rhs.pid
    }

    /// Freeze, sweep, then force: SIGSTOP every live target so none can
    /// fork, look again for anything born in the meantime and freeze that
    /// too, then SIGKILL everything frozen. SIGKILL ends a stopped process
    /// at once. If a look fails, everything frozen is resumed, so an error
    /// never leaves the user's tree stopped.
    func forceTree(
        _ live: [KillTarget],
        anchors: [KillTarget],
        known: inout Set<ProcessIdentity>,
        context: KillPhaseContext,
        report: inout KillReport,
        budget: KillSweepBudget = KillSweepBudget()
    ) async throws -> KillForceOutcome {
        var frozen: [KillTarget] = []
        var newborn: [KillTarget] = []
        var dropped = Set<ProcessIdentity>()
        let freeze = { (targets: [KillTarget], report: inout KillReport) in
            for target in targets.sorted(by: Self.forceOrder) {
                switch self.send(SIGSTOP, to: target, stage: "freeze", operationID: context.operationID,
                                 report: &report, eventSink: context.eventSink) {
                case .sent: frozen.append(target)
                case .refused, .recycled: dropped.insert(target.identity)
                case .exited, .failed: break
                }
            }
        }
        freeze(live, &report)
        known.formUnion(live.map(\.identity))
        if context.adoptsLateMembers {
            do {
                for round in 1...budget.maxRounds {
                    let arena = try await sweepSnapshot(plan: context.plan)
                    let found = lateMembers(in: arena, anchors: anchors + frozen, known: known, context: context)
                    guard !found.isEmpty else { break }
                    known.formUnion(found.map(\.identity))
                    let room = max(0, budget.maxTotal - frozen.count)
                    let before = frozen.count
                    freeze(Array(found.sorted(by: Self.forceOrder).prefix(room)), &report)
                    newborn += frozen.dropFirst(before)
                    if found.count > room || round == budget.maxRounds {
                        report.forkStorm = true
                        break
                    }
                }
            } catch {
                thaw(frozen, report: &report)
                throw error
            }
        }
        report.frozenCount += frozen.count
        if !frozen.isEmpty {
            appendEvent(.forcePending, operationID: context.operationID,
                        message: "Froze \(frozen.count) process\(frozen.count == 1 ? "" : "es") so none can start another before force.",
                        report: &report, eventSink: context.eventSink)
        }
        for target in frozen.sorted(by: Self.forceOrder) {
            let outcome = send(SIGKILL, to: target, stage: "forced", operationID: context.operationID,
                               report: &report, eventSink: context.eventSink)
            if outcome == .refused || outcome == .recycled { dropped.insert(target.identity) }
        }
        return KillForceOutcome(frozen: frozen, newborn: newborn, dropped: dropped)
    }

    /// Late members of this stop in `arena`, found after the preview.
    func lateMembers(
        in arena: KillGraphArena,
        anchors: [KillTarget],
        known: Set<ProcessIdentity>,
        context: KillPhaseContext
    ) -> [KillTarget] {
        KillTreeSweeper.lateMembers(
            arena: arena,
            anchors: anchors,
            known: known,
            bornAfter: context.bornAfter,
            currentUserID: currentUserID,
            protection: protection,
            rootIdentity: context.plan.rootIdentity
        )
    }

    private func sweepSnapshot(plan: KillPlan) async throws -> KillGraphArena {
        let snapshot = try await snapshotProvider.snapshot(request: KillSnapshotRequest(
            policy: .verify,
            rootIdentity: plan.rootIdentity,
            scope: plan.scope,
            includeHeavyMetricsForTargets: false,
            requiresCompleteGraph: true,
            conversionBudget: .targetsOnly
        ))
        return snapshot.liteArena
    }

    private func thaw(_ frozen: [KillTarget], report: inout KillReport) {
        for target in frozen {
            let resumed = (try? signaler.send(signal: SIGCONT, to: target.identity)) != nil
            report.attempts.append(KillAttempt(pid: target.pid, signal: SIGCONT, stage: "thaw", succeeded: resumed))
        }
    }
}

extension KillProcessSnapshot {
    /// The process table as lite processes, whichever form the provider
    /// filled in.
    var liteArena: KillGraphArena {
        arena ?? KillGraphArena(
            processes: graph?.processes ?? processes.map { KillProcessLite(process: $0) },
            sampledAt: sampledAt,
            pidReadCount: graphReadCount
        )
    }
}
