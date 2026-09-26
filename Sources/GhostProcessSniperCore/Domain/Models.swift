import Foundation

public enum GhostLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case quiet = 0
    case watch = 1
    case hot = 2
    case critical = 3

    public static func < (lhs: GhostLevel, rhs: GhostLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .quiet: "Quiet"
        case .watch: "Watch"
        case .hot: "Hot"
        case .critical: "Critical"
        }
    }
}

public enum RadarMode: String, Codable, CaseIterable, Sendable {
    case dev
    case heavy
    case all

    public var label: String {
        switch self {
        case .dev: "Dev"
        case .heavy: "Heavy"
        case .all: "All"
        }
    }
}

public enum RadarPerformanceMode: String, Codable, CaseIterable, Sendable {
    case batterySaver
    case balanced
    case realtime

    public var label: String {
        switch self {
        case .batterySaver: "Battery Saver"
        case .balanced: "Balanced"
        case .realtime: "Realtime"
        }
    }
}

public struct GhostScore: Equatable, Sendable {
    public let value: Double
    public let level: GhostLevel
    public let heat: GhostHeat
    public let reasons: [String]
    public let components: [GhostScoreComponent]

    public init(
        value: Double,
        level: GhostLevel,
        reasons: [String],
        components: [GhostScoreComponent] = [],
        heat: GhostHeat? = nil
    ) {
        self.value = value
        let resolvedHeat = heat ?? GhostHeat.compatibility(score: value, level: level)
        self.heat = resolvedHeat
        self.level = resolvedHeat.level
        self.reasons = reasons
        if components.isEmpty {
            let distributedImpact = max(1, value / Double(max(reasons.count, 1)))
            self.components = reasons.enumerated().map { offset, reason in
                GhostScoreComponent.inferred(
                    from: reason,
                    impact: distributedImpact + Double(offset) * 0.01,
                    level: level,
                    slot: "reason.\(offset)"
                )
            }
        } else {
            self.components = components
        }
    }
}
