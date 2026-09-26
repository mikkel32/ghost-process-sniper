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
    case forecast
    case rules
    case system
}

public struct GhostScoreComponent: Identifiable, Equatable, Sendable {
    /// What the component measures ("memory", "baseline.cpu",
    /// "hardware.cpuPressure.0"). It is the identity, so a row keeps its
    /// place while its title, detail and impact change every refresh.
    public let slot: String
    public let kind: GhostScoreComponentKind
    public let title: String
    public let detail: String
    public let impact: Double
    public let level: GhostLevel

    public var id: String { slot }

    public init(
        slot: String? = nil,
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
        self.slot = slot ?? "\(kind.rawValue).\(title.lowercased())"
    }

    public static func inferred(from reason: String, impact: Double, level: GhostLevel, slot: String? = nil) -> GhostScoreComponent {
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
        } else if lowercased.contains("forecast") || lowercased.contains("eta") || lowercased.contains("warming") {
            kind = .forecast
        } else if lowercased.contains("rule") || lowercased.contains("snoozed") || lowercased.contains("ignored") {
            kind = .rules
        } else {
            kind = .system
        }

        return GhostScoreComponent(
            slot: slot,
            kind: kind,
            title: reason,
            detail: reason,
            impact: impact,
            level: level
        )
    }
}

enum GhostScoreComponentMath {
    /// Scales positive impacts to `targetTotal`, keeping one component per
    /// slot (the larger impact) so identities stay unique.
    static func normalized(
        _ components: [GhostScoreComponent],
        to targetTotal: Double
    ) -> [GhostScoreComponent] {
        var positive: [GhostScoreComponent] = []
        var indexBySlot: [String: Int] = [:]
        for component in components where component.impact > 0 {
            if let index = indexBySlot[component.slot] {
                if component.impact > positive[index].impact { positive[index] = component }
            } else {
                indexBySlot[component.slot] = positive.count
                positive.append(component)
            }
        }
        guard targetTotal > 0, !positive.isEmpty else {
            return []
        }
        let total = positive.reduce(0) { $0 + $1.impact }
        guard total > 0 else {
            return []
        }
        let scale = targetTotal / total
        return positive.map { component in
            GhostScoreComponent(
                slot: component.slot,
                kind: component.kind,
                title: component.title,
                detail: component.detail,
                impact: component.impact * scale,
                level: component.level
            )
        }
    }
}
