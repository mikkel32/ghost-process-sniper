import Foundation

extension ProcessKiller {
    /// After a stop that left no survivor, confirms the ports the workload
    /// listened on are free, or names the process that still holds one.
    func verifyFreedPorts(
        _ ports: [Int],
        targets: [KillTarget],
        groupsFrom preflightArena: KillGraphArena?,
        since operationStart: Date,
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)?
    ) async {
        guard !ports.isEmpty, report.survivorPIDs.isEmpty, report.partiallySucceeded, let portProbe,
              let snapshot = try? await snapshotProvider.snapshot(policy: .verify) else {
            return
        }
        let arena = snapshot.arena ?? KillGraphArena(processes: snapshot.processes.map { KillProcessLite(process: $0) },
                                                     sampledAt: snapshot.sampledAt)
        let groups = Set(targets.compactMap { preflightArena?.process(for: $0.identity)?.processGroupID })
        let outcomes = KillOutcomeVerifier().verifyPorts(
            ports,
            arena: arena,
            stopped: Set(targets.map(\.identity)),
            stoppedNames: Set(targets.map(\.name)),
            targetGroups: groups,
            operationStart: operationStart,
            currentUserID: currentUserID,
            probe: portProbe
        )
        report.portOutcomes = outcomes
        guard !outcomes.isEmpty else { return }
        appendEvent(.verified, operationID: operationID, message: outcomes.map(\.text).joined(separator: " "),
                    report: &report, eventSink: eventSink)
    }
}
