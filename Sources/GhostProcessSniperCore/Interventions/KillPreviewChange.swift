import Foundation

/// How a refreshed preview differs from the one the user was reading, when
/// the difference changes what Confirm would do.
public struct KillPreviewChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case rootGone
        case targetsExited([Int32])
        case targetsJoined([Int32])
        case strategyChanged(from: KillStrategy, to: KillStrategy)
    }

    public let kind: Kind
    /// One plain sentence for the sheet's banner.
    public let text: String
}

public extension KillPreview {
    /// The one change worth telling, most serious first; nil when the stop
    /// would hit the same processes the same way. Metrics alone never count.
    func materialChange(from old: KillPreview) -> KillPreviewChange? {
        let now = Set(targetIdentities)
        let before = Set(old.targetIdentities)
        if let root = old.targets.first(where: \.isRoot), !now.contains(root.identity) {
            let rest = now.isEmpty ? "; nothing to stop" : ""
            return KillPreviewChange(kind: .rootGone, text: "\(root.name) exited on its own\(rest).")
        }
        let strategy = strategyRecommendation.strategy
        let oldStrategy = old.strategyRecommendation.strategy
        if strategy != oldStrategy {
            let reason = strategyRecommendation.reasons.first.map { ": \($0)" } ?? "."
            return KillPreviewChange(kind: .strategyChanged(from: oldStrategy, to: strategy),
                                     text: "The plan changed from \(oldStrategy.label) to \(strategy.label)\(reason)")
        }
        let joined = targets.filter { !before.contains($0.identity) }
        if !joined.isEmpty {
            let count = joined.count
            return KillPreviewChange(kind: .targetsJoined(joined.map(\.pid).sorted()),
                                     text: "\(Self.names(joined)) started since you opened this; \(count == 1 ? "it stops" : "they stop") too.")
        }
        let exited = old.targets.filter { !now.contains($0.identity) }
        if !exited.isEmpty {
            return KillPreviewChange(kind: .targetsExited(exited.map(\.pid).sorted()),
                                     text: "\(Self.names(exited)) exited on \(exited.count == 1 ? "its" : "their") own.")
        }
        return nil
    }

    private static func names(_ targets: [KillTarget]) -> String {
        let shown = targets.prefix(2).map { "\($0.name) (PID \($0.pid))" }
        return targets.count > 2 ? "\(shown.joined(separator: ", ")) and \(targets.count - 2) more" : shown.joined(separator: " and ")
    }
}
