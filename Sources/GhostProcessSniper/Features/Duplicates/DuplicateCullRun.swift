import Darwin
import Foundation
import GhostProcessSniperCore
import Observation

/// One copy in a "Stop the extras" run, from checklist to result.
struct DuplicateCullCopy: Identifiable {
    enum Status: Equatable {
        case waiting
        case checking
        case skipped(String)
        case stopping
        case finished(succeeded: Bool, summary: String)
    }

    let id: ProcessIdentity
    let name: String
    let reason: String
    let memoryText: String
    var isChecked = true
    var status: Status = .waiting
    /// The copy's stop preview targets, with live states while it stops.
    var targets: [KillTarget] = []

    var pid: Int32 { id.pid }

    var isSkipped: Bool {
        if case .skipped = status { true } else { false }
    }
}

/// The checklist and live progress behind the duplicate cull sheet.
@MainActor
@Observable
final class DuplicateCullRun: Identifiable {
    enum Phase {
        case choosing, checking, stopping, finished
    }

    let clusterName: String
    let summary: String
    private(set) var copies: [DuplicateCullCopy]
    private(set) var phase: Phase = .choosing
    private(set) var stoppedCount = 0
    private(set) var reclaimedBytes: UInt64 = 0
    private(set) var resultText = ""
    private let positions: [ProcessIdentity: Int]

    init(plan: DuplicateCullPlan) {
        clusterName = plan.displayName
        summary = plan.summary
        var riders: [ProcessIdentity: Int] = [:]
        for decision in plan.decisions {
            if let root = decision.stopsWith { riders[root, default: 0] += 1 }
        }
        copies = plan.stopTargets.map { decision in
            let rideAlong = riders[decision.identity].map { $0 == 1 ? " \u{00b7} takes the copy it started" : " \u{00b7} takes the \($0) copies it started" }
            return DuplicateCullCopy(
                id: decision.identity,
                name: decision.name,
                reason: decision.reason + (rideAlong ?? ""),
                memoryText: decision.memoryText
            )
        }
        positions = Dictionary(uniqueKeysWithValues: copies.enumerated().map { ($1.id, $0) })
    }

    var checkedCount: Int { copies.count(where: \.isChecked) }
    var skippedCount: Int { copies.count(where: \.isSkipped) }
    var isRunning: Bool { phase == .checking || phase == .stopping }

    func setChecked(_ id: ProcessIdentity, _ isChecked: Bool) {
        guard phase == .choosing, let index = positions[id] else { return }
        copies[index].isChecked = isChecked
    }

    fileprivate func begin() -> [ProcessIdentity] {
        phase = .checking
        let checked = copies.filter(\.isChecked).map(\.id)
        for id in checked { update(id) { $0.status = .checking } }
        return checked
    }

    fileprivate func beginStopping() {
        phase = .stopping
    }

    fileprivate func skip(_ id: ProcessIdentity, reason: String) {
        update(id) { $0.status = .skipped(reason) }
    }

    fileprivate func approve(_ id: ProcessIdentity, targets: [KillTarget]) {
        update(id) {
            $0.status = .stopping
            $0.targets = targets
        }
    }

    fileprivate func apply(_ event: KillOperationEvent, to id: ProcessIdentity) {
        guard let pid = event.pid, let state = event.targetState else { return }
        update(id) { copy in
            guard let target = copy.targets.firstIndex(where: { $0.pid == pid }) else { return }
            copy.targets[target] = copy.targets[target].updating(state: state, reason: event.message)
        }
    }

    fileprivate func finish(_ id: ProcessIdentity, report: KillReport) {
        if report.succeeded { stoppedCount += 1 }
        reclaimedBytes += report.realizedMemoryReclaimBytes
        update(id) { copy in
            copy.status = .finished(succeeded: report.succeeded, summary: report.summary)
            if !report.targetResults.isEmpty { copy.targets = report.targetResults }
        }
    }

    fileprivate func end() {
        phase = .finished
        var parts = ["Stopped \(stoppedCount) of \(checkedCount)"]
        if skippedCount > 0 { parts.append("skipped \(skippedCount)") }
        if reclaimedBytes > 0 { parts.append("freed \(RadarFormat.bytes(reclaimedBytes))") }
        resultText = parts.joined(separator: " \u{00b7} ")
    }

    private func update(_ id: ProcessIdentity, _ change: (inout DuplicateCullCopy) -> Void) {
        guard let index = positions[id] else { return }
        change(&copies[index])
    }
}

extension RadarConsoleSession {
    /// Stops each checked copy through a stop preview of its own. One
    /// preview cannot cover them all: copies outside its root's tree are
    /// never approved. Copies the preview would not stop, or that deserve a
    /// closer look, are skipped and left running. Stops run four at a time,
    /// and the scan refreshes once at the end rather than after every stop.
    func stopDuplicateCopies(_ run: DuplicateCullRun) async {
        guard run.phase == .choosing else { return }
        let checked = run.begin()
        let sample = monitor.sampledProcesses
        let delay = monitor.settings.forceKillDelay
        let killer = killer

        var planned: [PlannedStop] = []
        for id in checked {
            guard let family = ProcessFamily.adHoc(rootedAt: id, in: sample, currentUserID: geteuid()) else {
                run.skip(id, reason: "Already exited")
                continue
            }
            planned.append(PlannedStop(id: id, family: family, plan: await monitor.killPlan(for: family)))
        }

        var approved: [ProcessIdentity: PreviewedStop] = [:]
        await Self.forEach(planned, limit: 4) { stop in
            PreviewedStop(stop: stop, preview: await killer.preview(plan: stop.plan, forceKillDelay: delay))
        } result: { (previewed: PreviewedStop) in
            if let reason = Self.batchSkipReason(previewed.preview) {
                run.skip(previewed.stop.id, reason: reason)
                return
            }
            approved[previewed.stop.id] = previewed
            run.approve(previewed.stop.id, targets: previewed.preview.targets)
        }

        run.beginStopping()
        let (events, sink) = AsyncStream.makeStream(of: (ProcessIdentity, KillOperationEvent).self)
        let liveStates = Task {
            for await (id, event) in events { run.apply(event, to: id) }
        }
        var reports: [(family: ProcessFamily, report: KillReport)] = []
        // Checklist order, so the first stops to start are the largest copies.
        let stops = checked.compactMap { approved[$0] }
        await Self.forEach(stops, limit: 4) { previewed in
            let stop = previewed.stop
            // Approve only what the preview showed. The clock starts when this
            // stop does, since later copies wait for earlier grace periods.
            let approvedPlan = stop.plan.binding(
                to: previewed.preview.targetIdentities,
                expiresAt: Date().addingTimeInterval(60),
                strategy: previewed.preview.strategyRecommendation.strategy
            )
            let report = await killer.kill(plan: approvedPlan, forceKillDelay: delay, eventSink: { event in
                sink.yield((stop.id, event))
            })
            return FinishedStop(stop: stop, report: report)
        } result: { (finished: FinishedStop) in
            run.finish(finished.stop.id, report: finished.report)
            reports.append((finished.stop.family, finished.report))
        }
        sink.finish()
        await liveStates.value
        run.end()

        for (family, report) in reports {
            await monitor.recordKill(report: report, family: family)
        }
        if !reports.isEmpty { await monitor.refresh() }
        let skipped = run.skippedCount
        let stopped = "Stopped \(run.stoppedCount) \(run.stoppedCount == 1 ? "copy" : "copies") of \(run.clusterName)"
        showToast(skipped > 0 ? "\(stopped), skipped \(skipped)" : stopped,
                  systemImage: run.stoppedCount > 0 ? "checkmark.circle" : "exclamationmark.triangle")
    }

    /// Why a copy is left out of a batch stop even though its preview would
    /// allow it: it needs the full stop sheet, where the risks are spelled out.
    private static func batchSkipReason(_ preview: KillPreview) -> String? {
        if !preview.canKill { return "Nothing of yours left to stop" }
        if preview.strategyRecommendation.strategy == .inspectOnly { return "The stop preview advises inspecting it first" }
        let risk = preview.riskAssessment
        if let supervisor = risk.supervisor { return "\(supervisor.name) would start it again" }
        if risk.forceNeedsConfirmation { return "\(risk.kind.label) \u{2014} stop it on its own to review the risks" }
        return nil
    }

    /// Runs `work` for every item, at most `limit` at a time, and hands each
    /// result to `result` on the main actor as it arrives.
    private static func forEach<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        limit: Int,
        work: @escaping @Sendable (Item) async -> Output,
        result: (Output) -> Void
    ) async {
        await withTaskGroup(of: Output.self) { group in
            var pending = items[...]
            for _ in 0..<min(limit, pending.count) {
                let item = pending.removeFirst()
                group.addTask { await work(item) }
            }
            for await output in group {
                result(output)
                if let item = pending.popFirst() {
                    group.addTask { await work(item) }
                }
            }
        }
    }
}

private struct PlannedStop: Sendable {
    let id: ProcessIdentity
    let family: ProcessFamily
    let plan: KillPlan
}

private struct PreviewedStop: Sendable {
    let stop: PlannedStop
    let preview: KillPreview
}

private struct FinishedStop: Sendable {
    let stop: PlannedStop
    let report: KillReport
}
