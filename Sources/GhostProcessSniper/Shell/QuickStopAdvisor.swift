import GhostProcessSniperCore
import Observation

/// One-click stop actions for the culprits the popover, status menu and
/// Overview show. It recomputes only when the findings change, never per
/// sample, and views read `actions[row.id]` instead of the live families,
/// so a stop button costs no risk assessment in any body.
@MainActor
@Observable
final class QuickStopAdvisor {
    private(set) var actions: [String: QuickStopAction] = [:]

    @ObservationIgnored private let monitor: ProcessMonitor
    @ObservationIgnored private var lastRevision: SnapshotContentRevision?

    init(monitor: ProcessMonitor) {
        self.monitor = monitor
    }

    func update() {
        let snapshot = monitor.consoleSnapshot
        guard snapshot.contentRevision != lastRevision else { return }
        lastRevision = snapshot.contentRevision
        let compact = snapshot.compact
        var candidates = (compact.topRiskRows + compact.warmingRows).map {
            QuickStopAction.Candidate(familyKey: $0.id, level: $0.level)
        }
        if let key = compact.intelligenceBrief.familyKey {
            candidates.append(QuickStopAction.Candidate(familyKey: key, level: compact.intelligenceBrief.level))
        }
        let next = QuickStopAction.actions(
            for: candidates,
            families: monitor.families,
            processes: monitor.sampledProcesses
        )
        if next != actions { actions = next }
    }
}
