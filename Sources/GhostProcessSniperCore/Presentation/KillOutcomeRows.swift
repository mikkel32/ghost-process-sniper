import Foundation

/// The per-process outcome list of a finished stop: one row per process,
/// problems first, so what still needs attention is read before what went
/// as planned.
public enum KillOutcomeRows {
    public static func make(report: KillReport) -> [KillTarget] {
        var rows: [ProcessIdentity: KillTarget] = [:]
        var order: [ProcessIdentity] = []
        for target in report.targetResults + report.lateTargets {
            guard let kept = rows[target.identity] else {
                rows[target.identity] = target
                order.append(target.identity)
                continue
            }
            // A process can be reported twice, such as a late member that was
            // also stopped; the most final word on it wins.
            if finality(target.state) > finality(kept.state) {
                rows[target.identity] = target
            }
        }
        return order.compactMap { rows[$0] }.enumerated().sorted { lhs, rhs in
            let left = (rank(lhs.element.state), lhs.element.isRoot ? 0 : 1, lhs.offset)
            let right = (rank(rhs.element.state), rhs.element.isRoot ? 0 : 1, rhs.offset)
            return left < right
        }
        .map(\.element)
    }

    /// Display order: what needs attention first.
    static func rank(_ state: KillTargetState) -> Int {
        switch state {
        case .survived: 0
        case .failed: 1
        case .locked: 2
        case .forceKilled: 3
        case .terminated: 4
        case .exitedBeforeSignal: 5
        case .stopping: 6
        case .stale: 7
        case .recycled: 8
        case .ready: 9
        }
    }

    /// How settled a state is, for picking between two reports of one process.
    static func finality(_ state: KillTargetState) -> Int {
        switch state {
        case .survived, .failed: 6
        case .forceKilled: 5
        case .terminated: 4
        case .exitedBeforeSignal: 3
        case .locked, .stale, .recycled: 2
        case .stopping: 1
        case .ready: 0
        }
    }
}
