import Foundation

/// A report describes the moment its stop ended, and what it lists as still
/// running can end afterwards: an app whose save prompt was answered once the
/// wait was over. Settling brings the displayed report up to date, so an app
/// that has quit is not left "still open"; nothing is ever signalled.
public extension KillReport {
    /// This report once `exited` are known to be gone. Only processes it lists
    /// as survivors count, matched by identity, so a reused PID settles
    /// nothing. They become terminated rows, drop out of the survivors, and
    /// count toward what the stop freed (never past what it estimated). Once
    /// the app that accepted the quit is among them, it is no longer "still
    /// open" and the note about its held-back helpers goes.
    func settling(exited: Set<ProcessIdentity>) -> KillReport {
        let closed = survivingTargets.filter { exited.contains($0.identity) }
        guard !closed.isEmpty else { return self }
        let closedIdentities = Set(closed.map(\.identity))
        let closedPIDs = Set(closed.map(\.pid))
        var settled = self
        settled.survivorPIDs.removeAll { closedPIDs.contains($0) }
        settled.stuckExitingPIDs.removeAll { closedPIDs.contains($0) }
        settled.exitedAfterStopPIDs = Set(exitedAfterStopPIDs).union(closedPIDs).sorted()
        settled.targetResults = targetResults.map {
            $0.state == .survived && closedIdentities.contains($0.identity)
                ? $0.updating(state: .terminated, reason: "Closed after the stop") : $0
        }
        let freed = closed.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        settled.realizedMemoryReclaimBytes = min(max(estimatedMemoryReclaimBytes, realizedMemoryReclaimBytes),
                                                 realizedMemoryReclaimBytes + freed)
        if appStillOpen, let app = quitAcceptedPID, !settled.survivorPIDs.contains(app) {
            settled.appStillOpen = false
            settled.notes.removeAll { $0 == Self.helpersLeftAloneNote(app: displayName) }
        }
        return settled
    }

    /// This report for a family that has left the scan: none of its
    /// processes is running any more, whatever the report listed.
    func settlingSurvivors() -> KillReport {
        settling(exited: Set(survivingTargets.map(\.identity)))
    }
}

extension KillReport {
    /// The processes the report lists as still running, one row each.
    var survivingTargets: [KillTarget] {
        targetResults.filter { $0.state == .survived }
    }

    /// The app that accepted the quit request, if the stop asked one.
    var quitAcceptedPID: Int32? {
        attempts.first { $0.action == .quitRequest && $0.succeeded }?.pid
    }
}
