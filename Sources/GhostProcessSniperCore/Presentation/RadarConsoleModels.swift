import Foundation

public enum RadarFilter: String, CaseIterable, Sendable {
    case all
    case attention
    case leaking
    case killable
    case quiet

    public var label: String {
        switch self {
        case .all: "All"
        case .attention: "Attention"
        case .leaking: "Leaks"
        case .killable: "Killable"
        case .quiet: "Quiet"
        }
    }
}

public enum RadarSort: String, CaseIterable, Sendable {
    case smart
    case memory
    case cpu
    case leak
    case name

    public var label: String {
        switch self {
        case .smart: "Smart"
        case .memory: "Memory"
        case .cpu: "CPU"
        case .leak: "Leak"
        case .name: "Name"
        }
    }
}

public enum RadarIncidentFilter: String, CaseIterable, Sendable {
    case all
    case active
    case resolved
    case critical

    public var label: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .resolved: "Resolved"
        case .critical: "Critical"
        }
    }
}

public struct FamilyTriageViewModel: Identifiable, Equatable, Sendable {
    public var id: String { familyKey }

    public let familyKey: String
    public let assessment: ProcessAssessment
    public let signature: ProcessSignature
    public let familyID: ProcessIdentity
    public let displayName: String
    public let subtitle: String
    public let level: GhostLevel
    public let score: Double
    public let scoreText: String
    public let heat: Double
    public let heatText: String
    public let memoryBytes: UInt64
    public let memoryText: String
    public let cpuPercent: Double
    public let cpuText: String
    public let gpuPercent: Double
    public let gpuText: String
    public let leakVelocity: Double
    public let leakText: String
    public let childCount: Int
    public let devConfidence: Double
    public let isKillable: Bool
    public let kind: DevProcessKind
    public let kindText: String
    public let forecastState: ForecastState
    public let forecastConfidence: Double
    public let forecastPriority: Int
    public let hasCredibleLeak: Bool
    public let etaText: String
    public let confidenceText: String

    public init(
        family: ProcessFamily,
        classification providedClassification: DevClassification? = nil
    ) {
        familyKey = family.familyKey
        assessment = ProcessAssessment(family: family)
        signature = family.signature
        familyID = family.id
        displayName = family.displayName
        subtitle = family.commandHints.first ?? family.root.commandLine
        level = family.score.level
        score = family.score.value
        scoreText = "\(Int(family.score.value.rounded()))"
        heat = family.score.heat.value
        heatText = family.score.heat.valueText
        memoryBytes = family.totalPhysicalFootprintBytes
        memoryText = RadarFormat.bytes(family.totalPhysicalFootprintBytes)
        cpuPercent = family.totalCPUPercent
        cpuText = RadarFormat.percent(family.totalCPUPercent)
        gpuPercent = family.totalGPUPercent
        gpuText = family.totalGPUPercent > 0 ? RadarFormat.percent(family.totalGPUPercent) : "0%"
        leakVelocity = family.trend.memoryVelocityMegabytesPerMinute
        leakText = RadarFormat.leak(family.trend.memoryVelocityMegabytesPerMinute)
        childCount = family.childCount
        devConfidence = family.devConfidence
        isKillable = family.isKillable
        let classification = providedClassification ?? family.classification ?? DevProcessClassifier().classification(for: family)
        kind = classification.kind
        kindText = classification.kind.label
        forecastState = family.forecast.state
        forecastConfidence = family.forecast.confidence
        forecastPriority = family.forecastPresentationPriority
        hasCredibleLeak = family.hasCredibleLeak
        etaText = family.forecast.etaText
        confidenceText = "\(Int((family.forecast.confidence * 100).rounded()))%"
    }

    /// Elevated now, or trending toward trouble. Sidebar sections, the
    /// Attention filter and `is:attention` all use this one definition.
    public var needsAttention: Bool {
        level >= .watch || forecastState >= .warming
    }

    public func matches(_ filter: RadarFilter) -> Bool {
        switch filter {
        case .all: true
        case .attention: needsAttention
        // Credible leaks only: any positive memory slope is mostly noise.
        case .leaking: hasCredibleLeak
        case .killable: isKillable
        case .quiet: !needsAttention
        }
    }

    public static func areInIncreasingOrder(_ lhs: Self, _ rhs: Self, by sort: RadarSort) -> Bool {
        switch sort {
        case .smart:
            return SmartSortKey(lhs) < SmartSortKey(rhs)
        case .memory:
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
        case .cpu:
            if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
        case .leak:
            if lhs.leakVelocity != rhs.leakVelocity { return lhs.leakVelocity > rhs.leakVelocity }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
        case .name:
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return lhs.id < rhs.id
    }

    /// The smart order's inputs, small enough that sorting keys and permuting
    /// rows once beats swapping whole rows during the sort.
    struct SmartSortKey: Comparable {
        let level: GhostLevel
        let heat: Double
        let forecastPriority: Int
        let score: Double
        let leakVelocity: Double
        let memoryBytes: UInt64
        let cpuPercent: Double
        let familyKey: String

        init(_ row: FamilyTriageViewModel) {
            level = row.level
            heat = row.heat
            forecastPriority = row.forecastPriority
            score = row.score
            leakVelocity = row.leakVelocity
            memoryBytes = row.memoryBytes
            cpuPercent = row.cpuPercent
            familyKey = row.familyKey
        }

        /// Earlier means more urgent.
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            if lhs.heat != rhs.heat { return lhs.heat > rhs.heat }
            if lhs.forecastPriority != rhs.forecastPriority { return lhs.forecastPriority > rhs.forecastPriority }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.leakVelocity != rhs.leakVelocity { return lhs.leakVelocity > rhs.leakVelocity }
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
            if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
            return lhs.familyKey < rhs.familyKey
        }
    }
}
