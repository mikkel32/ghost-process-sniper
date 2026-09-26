import Darwin
import Foundation

struct RawProcessSample: Sendable {
    let pid: pid_t
    let liteRecord: ProcessLiteRecord
    /// Raw `pbi_name`; empty when the kernel has none (the lite record then says `pid-N`).
    let kernelName: String
    let usage: ProbeUsage?
    var task: ProbeTask?
    /// 2 is explicit focus or alert demand, 1 a developer hint, 0 discovery.
    let priority: Int
}

struct ProbeReadStats: Sendable {
    var bsdReadCount = 0
    var bsdDeniedCount = 0
    var usageReadCount = 0
    var usageFailedCount = 0
    var taskInfoReadCount = 0
    var expensiveCallCount = 0
    var didHitDeadline = false
}

/// Reads the identity graph and the CPU and memory lane for every readable
/// process, then spends the bounded task-info budget on thread and VM counts.
enum ProcessProbeReader {
    static func read(
        _ pids: [pid_t],
        count: Int,
        plan: SamplingPlan,
        source: any ProcessProbeSource,
        deadline: TickDeadline,
        pass: UInt64,
        known: ProcessScanCache,
        hints: inout DeveloperNameHints,
        samples: inout [RawProcessSample],
        priorities: inout [Int]
    ) -> ProbeReadStats {
        samples.removeAll(keepingCapacity: true)
        priorities.removeAll(keepingCapacity: true)
        samples.reserveCapacity(count)
        priorities.reserveCapacity(count)
        var stats = ProbeReadStats()

        // Mandatory and never deadline-bound: a dropped tail would be the
        // oldest processes, and their families would lose members and history.
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let bsd: ProbeBSD
            switch source.bsd(pid) {
            case .record(let record): bsd = record
            case .denied:
                stats.bsdDeniedCount += 1
                continue
            case .missing: continue
            }
            stats.bsdReadCount += 1

            // The usage lane is never gated by budget or thermal pressure.
            var usage = source.usage(pid)
            if usage != nil {
                usage?.sampledAtUptimeNanoseconds = source.now()
                stats.usageReadCount += 1
            } else {
                stats.usageFailedCount += 1
            }

            let identity = ProcessIdentity(pid: Int32(pid), startTimeSeconds: bsd.startTimeSeconds,
                startTimeMicroseconds: bsd.startTimeMicroseconds)
            let name = bsd.name.isEmpty ? "pid-\(pid)" : bsd.name
            let requested = plan.candidateSet.contains(identity: identity, pid: Int32(pid)) ||
                plan.includeForensicsFor.contains(identity) || plan.includeForensicsForPIDs.contains(Int32(pid)) ||
                plan.probePolicy.richMetricIdentities.contains(identity) || plan.probePolicy.richMetricPIDs.contains(Int32(pid))
            let hinted = !requested && (plan.hintedIdentities.contains(identity) ||
                known.record(for: identity) == nil && hints.isDeveloperName(bsd.name))
            let priority = requested ? 2 : hinted ? 1 : 0
            let lite = ProcessLiteRecord(identity: identity, parentPID: bsd.parentPID,
                userID: bsd.userID, name: name, processGroupID: bsd.processGroupID, status: bsd.status,
                flags: bsd.flags, openFileCount: bsd.openFileCount, sampledAt: plan.sampledAt,
                controllingTerminal: bsd.controllingTerminal, terminalForegroundGroupID: bsd.terminalForegroundGroupID)
            priorities.append(priority)
            samples.append(RawProcessSample(pid: pid, liteRecord: lite, kernelName: bsd.name,
                usage: usage, task: nil, priority: priority))
        }

        let budget = plan.probePolicy.allowsRichMetrics
            ? plan.metricsEnrichmentBudget
            : max(4, plan.metricsEnrichmentBudget / 4)
        for index in RichProbeSelector.indices(priorities: priorities, budget: budget, pass: pass) {
            if deadline.isExpired(at: source.now()) {
                stats.didHitDeadline = true
                break
            }
            stats.expensiveCallCount += 1
            // A denied or raced task read keeps the cached thread and VM counts.
            guard let task = source.taskInfo(samples[index].pid) else { continue }
            stats.taskInfoReadCount += 1
            samples[index].task = task
        }
        return stats
    }
}
