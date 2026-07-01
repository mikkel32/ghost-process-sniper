import Foundation

public enum GhostScoreComponentKind: String, CaseIterable, Sendable {
    case memory
    case cpu
    case gpu
    case leak
    case baseline
    case fanout
    case background
    case recurrence
    case rules
    case system
}

public struct GhostScoreComponent: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: GhostScoreComponentKind
    public let title: String
    public let detail: String
    public let impact: Double
    public let level: GhostLevel

    public init(
        id: String? = nil,
        kind: GhostScoreComponentKind,
        title: String,
        detail: String,
        impact: Double,
        level: GhostLevel
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.impact = impact
        self.level = level
        self.id = id ?? "\(kind.rawValue)-\(title.lowercased())-\(Int(impact.rounded()))"
    }

    public static func inferred(from reason: String, impact: Double, level: GhostLevel) -> GhostScoreComponent {
        let lowercased = reason.lowercased()
        let kind: GhostScoreComponentKind
        if lowercased.contains("memory") || lowercased.contains("footprint") {
            kind = .memory
        } else if lowercased.contains("cpu") {
            kind = .cpu
        } else if lowercased.contains("gpu") {
            kind = .gpu
        } else if lowercased.contains("leak") || lowercased.contains("climbing") {
            kind = .leak
        } else if lowercased.contains("baseline") || lowercased.contains("usual") {
            kind = .baseline
        } else if lowercased.contains("child") || lowercased.contains("matching instance") {
            kind = .fanout
        } else if lowercased.contains("background") {
            kind = .background
        } else if lowercased.contains("recurring") {
            kind = .recurrence
        } else if lowercased.contains("rule") || lowercased.contains("snoozed") || lowercased.contains("ignored") {
            kind = .rules
        } else {
            kind = .system
        }

        return GhostScoreComponent(
            kind: kind,
            title: reason,
            detail: reason,
            impact: impact,
            level: level
        )
    }
}
