import Foundation

public enum ForecastState: String, Codable, CaseIterable, Comparable, Sendable {
    case quiet
    case warming
    case leaking
    case runaway
    case stale
    case critical

    public var label: String {
        switch self {
        case .quiet: "Quiet"
        case .warming: "Warming"
        case .leaking: "Leaking"
        case .runaway: "Runaway"
        case .stale: "Stale"
        case .critical: "Critical"
        }
    }

    public var level: GhostLevel {
        switch self {
        case .quiet: .quiet
        case .warming, .stale: .watch
        case .leaking: .hot
        case .runaway, .critical: .critical
        }
    }

    public static func < (lhs: ForecastState, rhs: ForecastState) -> Bool {
        lhs.severityRank < rhs.severityRank
    }

    public var severityRank: Int {
        switch self {
        case .quiet: 0
        case .warming: 1
        case .stale: 2
        case .leaking: 3
        case .runaway: 4
        case .critical: 5
        }
    }
}

public enum ForecastHorizon: String, Codable, CaseIterable, Sendable {
    case unknown
    case later
    case soon
    case imminent
    case breached

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .later: "Later"
        case .soon: "Soon"
        case .imminent: "Imminent"
        case .breached: "Breached"
        }
    }

    public static func from(etaSeconds: TimeInterval?) -> ForecastHorizon {
        guard let etaSeconds else {
            return .unknown
        }
        if etaSeconds <= 0 {
            return .breached
        }
        if etaSeconds <= 5 * 60 {
            return .imminent
        }
        if etaSeconds <= 30 * 60 {
            return .soon
        }
        return .later
    }
}

/// What a forecast's ETA counts down to. CPU never has an ETA: a linear CPU%
/// extrapolation is meaningless, so a CPU breach is evidence, not a countdown.
public enum ForecastETAKind: String, Codable, CaseIterable, Sendable {
    case none
    case memoryLimit
    /// Reserved for time-to-host-memory-pressure.
    case hostMemory
}

public struct AnomalyBaseline: Codable, Equatable, Sendable {
    public let memoryMultiple: Double
    public let cpuMultiple: Double
    public let recurrenceCount: Int
    public let sampleCount: Int

    public static let unknown = AnomalyBaseline(
        memoryMultiple: 1,
        cpuMultiple: 1,
        recurrenceCount: 0,
        sampleCount: 0
    )

    public init(memoryMultiple: Double, cpuMultiple: Double, recurrenceCount: Int, sampleCount: Int) {
        self.memoryMultiple = memoryMultiple
        self.cpuMultiple = cpuMultiple
        self.recurrenceCount = recurrenceCount
        self.sampleCount = sampleCount
    }

    public init(family: ProcessFamily) {
        if let baseline = family.baseline, baseline.isMeasurementTrusted {
            self.init(
                memoryMultiple: baseline.memoryMultiple(for: family.totalPhysicalFootprintBytes),
                cpuMultiple: baseline.cpuMultiple(for: family.totalCPUPercent),
                recurrenceCount: family.recentIncidentCount,
                sampleCount: baseline.sampleCount
            )
        } else {
            self = .unknown
        }
    }
}

public struct TriageRecommendation: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let action: RadarActionType
    public let confidence: Double

    public init(title: String, detail: String, action: RadarActionType, confidence: Double) {
        self.title = title
        self.detail = detail
        self.action = action
        self.confidence = confidence
    }
}

public struct PredictiveAlert: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let signatureID: String
    public let state: ForecastState
    public let message: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        signatureID: String,
        state: ForecastState,
        message: String,
        createdAt: Date
    ) {
        self.id = id
        self.signatureID = signatureID
        self.state = state
        self.message = message
        self.createdAt = createdAt
    }
}

public struct RiskForecast: Codable, Equatable, Sendable {
    public let state: ForecastState
    public let horizon: ForecastHorizon
    public let confidence: Double
    public let etaSeconds: TimeInterval?
    public let etaText: String
    public let whyNow: String
    public let recommendedAction: TriageRecommendation
    public let projectedMemoryBytes: UInt64
    public let projectedCPUPercent: Double
    public let leakAccelerationMegabytesPerMinute2: Double
    public let recurrenceRisk: Double
    public let staleLikelihood: Double
    public let baseline: AnomalyBaseline
    public let generatedAt: Date
    public let etaKind: ForecastETAKind

    public static let quiet = RiskForecast(
        state: .quiet,
        horizon: .unknown,
        confidence: 0,
        etaSeconds: nil,
        etaText: "No threshold ETA",
        whyNow: "No predictive signal yet",
        recommendedAction: TriageRecommendation(
            title: "Keep watching",
            detail: "This family is inside its learned range.",
            action: .inspect,
            confidence: 0
        ),
        projectedMemoryBytes: 0,
        projectedCPUPercent: 0,
        leakAccelerationMegabytesPerMinute2: 0,
        recurrenceRisk: 0,
        staleLikelihood: 0,
        baseline: .unknown,
        generatedAt: Date(timeIntervalSince1970: 0)
    )

    public init(
        state: ForecastState,
        horizon: ForecastHorizon,
        confidence: Double,
        etaSeconds: TimeInterval?,
        etaText: String,
        whyNow: String,
        recommendedAction: TriageRecommendation,
        projectedMemoryBytes: UInt64,
        projectedCPUPercent: Double,
        leakAccelerationMegabytesPerMinute2: Double,
        recurrenceRisk: Double,
        staleLikelihood: Double,
        baseline: AnomalyBaseline,
        generatedAt: Date,
        etaKind: ForecastETAKind? = nil
    ) {
        self.state = state
        self.horizon = horizon
        self.confidence = min(1, max(0, confidence))
        self.etaSeconds = etaSeconds
        self.etaText = etaText
        self.whyNow = whyNow
        self.recommendedAction = recommendedAction
        self.projectedMemoryBytes = projectedMemoryBytes
        self.projectedCPUPercent = projectedCPUPercent
        self.leakAccelerationMegabytesPerMinute2 = leakAccelerationMegabytesPerMinute2
        self.recurrenceRisk = min(1, max(0, recurrenceRisk))
        self.staleLikelihood = min(1, max(0, staleLikelihood))
        self.baseline = baseline
        self.generatedAt = generatedAt
        self.etaKind = etaKind ?? (etaSeconds == nil ? .none : .memoryLimit)
    }

    /// A low-confidence forecast is useful as directional context, but should
    /// not independently drive urgent queues, expensive sampling, or scary UI.
    public var isCredibleEarlyWarning: Bool {
        state >= .warming && confidence >= 0.42
    }

    public var isCredibleEscalation: Bool {
        state >= .leaking && confidence >= 0.55
    }
}

public struct ForecastStoreSnapshot: Codable, Equatable, Sendable {
    public let signatureID: String
    public let state: ForecastState
    public let confidence: Double
    public let etaSeconds: TimeInterval?
    public let whyNow: String
    public let generatedAt: Date

    public init(
        signatureID: String,
        state: ForecastState,
        confidence: Double,
        etaSeconds: TimeInterval?,
        whyNow: String,
        generatedAt: Date
    ) {
        self.signatureID = signatureID
        self.state = state
        self.confidence = min(1, max(0, confidence))
        self.etaSeconds = etaSeconds
        self.whyNow = whyNow
        self.generatedAt = generatedAt
    }

    public init(family: ProcessFamily) {
        signatureID = family.signature.id
        state = family.forecast.state
        confidence = family.forecast.confidence
        etaSeconds = family.forecast.etaSeconds
        whyNow = family.forecast.whyNow
        generatedAt = family.forecast.generatedAt
    }
}

public extension ProcessFamily {
    /// Forecast confidence alone is not enough: two samples can create an
    /// impressive ETA while still being just one allocation jump. Keep the
    /// history requirement next to the family so every subsystem uses the same
    /// credibility policy.
    var forecastHasUsefulHistory: Bool {
        forecastHasUsefulHistory(heat: score.heat)
    }

    /// Only trend-proven persistence substitutes for samples; baseline and
    /// host-pressure votes (corroborationCount) never do.
    func forecastHasUsefulHistory(heat: GhostHeat) -> Bool {
        trend.sampleCount >= 3 || heat.sustainedSignalCount > 0
    }

    var forecastHasEscalationHistory: Bool {
        trend.sampleCount >= 4 || score.heat.sustainedSignalCount > 0
    }

    var forecastIsCredibleEarlyWarning: Bool {
        forecast.isCredibleEarlyWarning && forecastHasUsefulHistory
    }

    var forecastIsCredibleEscalation: Bool {
        forecast.isCredibleEscalation && forecastHasEscalationHistory
    }

    /// The level the product should present and sort by. Raw model output is
    /// still retained for diagnostics, but immature predictions do not get
    /// the same visual authority as measured or corroborated Heat.
    var forecastPresentationLevel: GhostLevel {
        if forecastIsCredibleEscalation {
            return forecast.state.level
        }
        if forecastIsCredibleEarlyWarning {
            return .watch
        }
        return .quiet
    }

    var forecastPresentationPriority: Int {
        forecastPresentationLevel.rawValue * 10 +
            (forecastIsCredibleEarlyWarning ? forecast.state.severityRank : 0)
    }

    var forecastPresentationText: String {
        guard forecast.state != .quiet else {
            return forecast.state.label
        }
        if forecastIsCredibleEscalation {
            return forecast.state.label
        }
        if forecastIsCredibleEarlyWarning {
            if forecast.state >= .leaking {
                return "Confirming \(forecast.state.label.lowercased())"
            }
            return forecast.state.label
        }
        return "Collecting evidence"
    }

    var presentedForecastRecommendation: TriageRecommendation {
        guard forecastIsCredibleEarlyWarning else {
            return TriageRecommendation(
                title: "Collecting evidence",
                detail: "No action is recommended until the trend has enough history and confidence.",
                action: .highlight,
                confidence: forecast.confidence
            )
        }
        if (forecast.recommendedAction.action == .suggestKill || forecast.recommendedAction.action == .kill),
           !forecastIsCredibleEscalation,
           score.level < .critical {
            return TriageRecommendation(
                title: "Confirming \(forecast.state.label.lowercased()) signal",
                detail: "Keep watching while the prediction earns escalation confidence.",
                action: .highlight,
                confidence: forecast.confidence
            )
        }
        return forecast.recommendedAction
    }

    var hasCredibleLeak: Bool {
        (forecastIsCredibleEscalation && forecast.state >= .leaking) ||
            (score.level >= .hot && score.components.contains { component in
                component.kind == .leak && component.level >= .hot
            })
    }
}
