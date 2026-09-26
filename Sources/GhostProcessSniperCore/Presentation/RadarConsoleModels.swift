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
    public let heatConfidenceText: String
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
    public let classificationReason: String
    public let likelyCauseText: String
    public let nextActionText: String
    public let forecastState: ForecastState
    public let forecastConfidence: Double
    public let forecastPresentationLevel: GhostLevel
    public let forecastPriority: Int
    public let hasCredibleLeak: Bool
    public let forecastText: String
    public let etaText: String
    public let confidenceText: String
    public let whyNowText: String
    public let recommendationText: String
    public let alertMessage: String
    public let primaryComponent: GhostScoreComponent?
    public let reasonCount: Int
    public let metricsVersion: UInt64
    public let forensicsFreshness: Date?

    public init(
        family: ProcessFamily,
        classification providedClassification: DevClassification? = nil,
        culprit providedCulprit: CulpritAnalysis? = nil
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
        heatConfidenceText = family.score.heat.confidenceText
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
        let culprit = providedCulprit ?? CulpritAnalysis(family: family, classification: classification)
        kind = classification.kind
        kindText = classification.kind.label
        classificationReason = classification.reason
        likelyCauseText = culprit.likelyCause
        nextActionText = culprit.nextAction
        forecastState = family.forecast.state
        forecastConfidence = family.forecast.confidence
        forecastPresentationLevel = family.forecastPresentationLevel
        forecastPriority = family.forecastPresentationPriority
        hasCredibleLeak = family.hasCredibleLeak
        forecastText = family.forecastPresentationText
        etaText = family.forecast.etaText
        confidenceText = "\(Int((family.forecast.confidence * 100).rounded()))%"
        whyNowText = family.forecast.whyNow
        recommendationText = family.presentedForecastRecommendation.title
        if family.alertState.kind != .normal {
            alertMessage = family.alertState.message
        } else if family.forecastIsCredibleEarlyWarning {
            alertMessage = "\(family.forecast.state.label) - \(family.forecast.etaText)"
        } else if family.forecast.state >= .warming {
            alertMessage = "Confirming \(family.forecast.state.label.lowercased()) signal"
        } else {
            alertMessage = level.label
        }
        primaryComponent = family.score.components.max { $0.impact < $1.impact }
        reasonCount = family.score.reasons.count
        metricsVersion = family.metricsVersion
        forensicsFreshness = family.forensicsFreshness
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
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            if lhs.heat != rhs.heat { return lhs.heat > rhs.heat }
            if lhs.forecastPriority != rhs.forecastPriority { return lhs.forecastPriority > rhs.forecastPriority }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.leakVelocity != rhs.leakVelocity { return lhs.leakVelocity > rhs.leakVelocity }
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
            if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
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
}
