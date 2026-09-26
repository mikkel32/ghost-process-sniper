import Foundation

/// Tells a supervisor's restart apart from an unrelated process that
/// happens to share a stopped target's name, such as another `node`.
enum KillRespawnDetector {
    /// New processes with a stopped target's name, owned by the user,
    /// started at or after `start`, whose parent chain (at most three hops,
    /// to allow an `sh -c` in between) reaches the supervisor. A launchd
    /// job's restart has launchd itself as its parent.
    static func respawned(
        in lites: [KillProcessLite],
        targets: [KillTarget],
        supervisor: KillSupervisor,
        since start: Date,
        currentUserID: UInt32
    ) -> [KillProcessLite] {
        let stoppedNames = Set(targets.map(\.name))
        let stopped = Set(targets.map(\.identity))
        let parents = Dictionary(lites.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        let threshold = start.timeIntervalSince1970
        return lites.filter { process in
            guard !stopped.contains(process.identity), stoppedNames.contains(process.name),
                  process.userID == currentUserID, KillTreeSweeper.startTime(of: process) >= threshold else { return false }
            guard let supervisorPID = supervisor.pid else { return process.parentPID == 1 }
            var cursor: Int32? = process.parentPID
            for _ in 0..<3 {
                guard let pid = cursor, pid > 1 else { return false }
                if pid == supervisorPID { return true }
                cursor = parents[pid]
            }
            return false
        }
    }
}

extension ProcessKiller {
    /// Cumulative times after the stop at which to look for a restart:
    /// 150, 400, 900 and 1800 ms. The first match ends the wait.
    static let respawnProbeDelays: [UInt64] = [150_000_000, 250_000_000, 500_000_000, 900_000_000]

    /// Looks for a restart, only for supervisors that restart on exit; a
    /// file watcher waits for the next save, and saying so beats waiting.
    func detectRespawn(
        of targets: [KillTarget],
        by supervisor: KillSupervisor,
        since lastSignal: Date,
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)?
    ) async {
        switch supervisor.kind.restartPolicy {
        case .onFileChange:
            report.notes.append("\(supervisor.name) is waiting for file changes; it will start the app again the next time you save. Stop \(supervisor.name) to prevent that.")
            return
        case .stopsSiblings:
            report.notes.append("\(supervisor.name) stops the other processes it runs when this one exits.")
            return
        case .onExit:
            break
        }
        for delay in Self.respawnProbeDelays {
            await sleeper(delay)
            guard let snapshot = try? await snapshotProvider.snapshot(request: KillSnapshotRequest(
                policy: .verify, includeHeavyMetricsForTargets: false, requiresCompleteGraph: true, conversionBudget: .targetsOnly
            )) else { return }
            let respawned = KillRespawnDetector.respawned(in: snapshot.liteArena.processes, targets: targets, supervisor: supervisor,
                                                          since: lastSignal, currentUserID: currentUserID)
            guard !respawned.isEmpty else { continue }
            report.respawnedPIDs = respawned.map(\.pid).sorted()
            report.respawnedBy = supervisor.name
            appendEvent(.verified, operationID: operationID,
                        message: "\(supervisor.name) restarted it as PID \(report.respawnedPIDs.map(String.init).joined(separator: ", ")).",
                        report: &report, eventSink: eventSink)
            return
        }
    }
}
