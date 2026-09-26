import Foundation

/// The shape of a family's memory behavior over the trend window. The shape
/// matters as much as the slope: a sawtooth that keeps reclaiming memory is
/// GC churn, not a leak, even when its net velocity is positive.
public enum MemoryPattern: String, Codable, CaseIterable, Sendable {
    case unknown
    case flat
    case steadyClimb
    case sawtooth
    /// Reclaims in cycles, but every trough sits higher: a leak under GC.
    case risingFloor
    case stepJump
    case volatile
    case declining

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .flat: "Flat"
        case .steadyClimb: "Steady Climb"
        case .sawtooth: "Sawtooth"
        case .risingFloor: "Leaking under GC"
        case .stepJump: "Step Jump"
        case .volatile: "Volatile"
        case .declining: "Declining"
        }
    }

    public var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .flat: "minus"
        case .steadyClimb: "chart.line.uptrend.xyaxis"
        case .sawtooth: "waveform.path"
        case .risingFloor: "drop.triangle"
        case .stepJump: "stairs"
        case .volatile: "waveform.path.ecg"
        case .declining: "chart.line.downtrend.xyaxis"
        }
    }

    /// Whether a positive net velocity with this shape is, by shape alone, an
    /// accumulating leak. Too few points or an irregular shape prove nothing;
    /// MemoryPatternAnalysis.indicatesAccumulation adds the fit evidence.
    public var indicatesAccumulation: Bool {
        switch self {
        case .steadyClimb, .risingFloor: true
        case .flat, .sawtooth, .stepJump, .declining, .volatile, .unknown: false
        }
    }
}

public struct MemoryPatternAnalysis: Equatable, Sendable {
    public let pattern: MemoryPattern
    public let confidence: Double
    public let detail: String
    /// R² of the memory regression the shape was judged with.
    public let fitQuality: Double
    /// Theil-Sen slope of the series, robust to jitter and single spikes.
    public let robustSlopeMegabytesPerMinute: Double
    /// Lower end of the slope's ~95% confidence band; > 0 means real growth.
    public let slopeLowerBoundMegabytesPerMinute: Double
    /// Theil-Sen slope through the reclaim troughs (0 without two dips).
    public let floorSlopeMegabytesPerMinute: Double
    /// Per-sample measurement noise estimated from first differences.
    public let noiseMegabytes: Double

    public static let unknown = MemoryPatternAnalysis(
        pattern: .unknown,
        confidence: 0,
        detail: "Collecting samples"
    )

    public init(
        pattern: MemoryPattern,
        confidence: Double,
        detail: String,
        fitQuality: Double = 0,
        robustSlopeMegabytesPerMinute: Double = 0,
        slopeLowerBoundMegabytesPerMinute: Double = 0,
        floorSlopeMegabytesPerMinute: Double = 0,
        noiseMegabytes: Double = 0
    ) {
        self.pattern = pattern
        self.confidence = min(1, max(0, confidence))
        self.detail = detail
        self.fitQuality = min(1, max(0, fitQuality))
        self.robustSlopeMegabytesPerMinute = robustSlopeMegabytesPerMinute
        self.slopeLowerBoundMegabytesPerMinute = slopeLowerBoundMegabytesPerMinute
        self.floorSlopeMegabytesPerMinute = floorSlopeMegabytesPerMinute
        self.noiseMegabytes = noiseMegabytes
    }

    /// An irregular series still accumulates when the trend explains most of
    /// it or its robust slope is significantly positive; every other shape
    /// answers by itself.
    public var indicatesAccumulation: Bool {
        guard pattern == .volatile else { return pattern.indicatesAccumulation }
        return fitQuality >= 0.5 || slopeLowerBoundMegabytesPerMinute > 0
    }
}

/// One plain-English judgment per family, synthesized from every signal the
/// engine has: forecast state, memory shape, baseline deviation, and rules.
public struct FamilyVerdict: Equatable, Sendable {
    public let headline: String
    public let detail: String
    public let level: GhostLevel
    public let systemImage: String

    public init(headline: String, detail: String, level: GhostLevel, systemImage: String) {
        self.headline = headline
        self.detail = detail
        self.level = level
        self.systemImage = systemImage
    }

    public static func synthesize(family: ProcessFamily, pattern: MemoryPatternAnalysis) -> FamilyVerdict {
        if family.alertState.kind == .ignored {
            return FamilyVerdict(
                headline: "Muted",
                detail: "Ignored by rule — it will not raise alerts. Undo under Rules.",
                level: .quiet,
                systemImage: "eye.slash"
            )
        }
        if family.alertState.kind == .snoozed {
            return FamilyVerdict(
                headline: "Snoozed",
                detail: "Alerts are paused for this family. It stays visible here.",
                level: .quiet,
                systemImage: "moon"
            )
        }
        if !family.hasRecentMeasurements(at: family.lastScoredAt ?? family.root.sampledAt) {
            return FamilyVerdict(
                headline: "Waiting for a current reading",
                detail: "Some process measurements are missing or outside the current 15-second window. Scan again before assessing this process.",
                level: .quiet,
                systemImage: "clock"
            )
        }

        let forecast = family.forecast
        let velocity = max(0, family.trend.memoryVelocityMegabytesPerMinute)
        let trustedBaseline = family.baseline.flatMap { $0.isMeasurementTrusted ? $0 : nil }
        let baselineMultiple = trustedBaseline?.memoryMultiple(for: family.totalPhysicalFootprintBytes) ?? 1
        let effectiveForecastState: ForecastState
        if family.score.level >= .critical {
            effectiveForecastState = .critical
        } else if family.forecastIsCredibleEscalation {
            effectiveForecastState = forecast.state
        } else if family.forecastIsCredibleEarlyWarning, forecast.state >= .leaking {
            // Keep the directional warning without presenting an immature
            // forecast as a confirmed leak/runaway verdict.
            effectiveForecastState = .warming
        } else if family.forecastIsCredibleEarlyWarning {
            effectiveForecastState = forecast.state
        } else {
            effectiveForecastState = .quiet
        }

        switch effectiveForecastState {
        case .critical:
            return FamilyVerdict(
                headline: "Out of bounds",
                detail: sentence(forecast.whyNow),
                level: .critical,
                systemImage: "exclamationmark.octagon"
            )
        case .runaway:
            return FamilyVerdict(
                headline: "Running away",
                detail: sentence(forecast.whyNow),
                level: .critical,
                systemImage: "bolt"
            )
        case .leaking:
            if pattern.pattern == .steadyClimb {
                return FamilyVerdict(
                    headline: "Likely leak",
                    detail: "Climbing \(Int(velocity.rounded())) MB/min with little reclaim. \(leakETASentence(forecast))",
                    level: .hot,
                    systemImage: "drop.triangle"
                )
            }
            if pattern.pattern == .risingFloor {
                return FamilyVerdict(
                    headline: "Leaking under GC",
                    detail: "\(pattern.detail): memory is reclaimed in cycles, but not all of it.",
                    level: .hot,
                    systemImage: "drop.triangle"
                )
            }
            return FamilyVerdict(
                headline: "Leaking",
                detail: sentence(forecast.whyNow),
                level: .hot,
                systemImage: "drop.triangle"
            )
        case .stale:
            return FamilyVerdict(
                headline: "Probably forgotten",
                detail: "Long-lived detached tree with idle CPU — looks like a dev process nobody is using.",
                level: .watch,
                systemImage: "moon.zzz"
            )
        case .warming:
            if pattern.pattern == .sawtooth {
                return FamilyVerdict(
                    headline: "Churning, not leaking",
                    detail: "\(pattern.detail) — likely GC or cache cycles, no net accumulation to fear yet.",
                    level: .watch,
                    systemImage: "waveform.path"
                )
            }
            if pattern.pattern == .stepJump {
                return FamilyVerdict(
                    headline: "Stepped up",
                    detail: "\(pattern.detail). Watching whether it repeats before treating it as a leak.",
                    level: .watch,
                    systemImage: "stairs"
                )
            }
            if baselineMultiple >= 2 {
                return FamilyVerdict(
                    headline: "Above its normal",
                    detail: String(format: "Using %.1fx its usual memory. %@", baselineMultiple, sentence(forecast.whyNow)),
                    level: .watch,
                    systemImage: "arrow.up.right.circle"
                )
            }
            return FamilyVerdict(
                headline: "Warming up",
                detail: sentence(forecast.whyNow),
                level: .watch,
                systemImage: "thermometer.medium"
            )
        case .quiet:
            if pattern.pattern == .declining {
                return FamilyVerdict(
                    headline: "Recovering",
                    detail: "\(pattern.detail) — pressure is easing on its own.",
                    level: .quiet,
                    systemImage: "chart.line.downtrend.xyaxis"
                )
            }
            if baselineMultiple >= 2 {
                return FamilyVerdict(
                    headline: "Above its normal",
                    detail: String(format: "Using %.1fx its usual memory but otherwise calm.", baselineMultiple),
                    level: .watch,
                    systemImage: "arrow.up.right.circle"
                )
            }
            if trustedBaseline != nil {
                return FamilyVerdict(
                    headline: "Behaving normally",
                    detail: "Inside its learned range with no predictive signals.",
                    level: .quiet,
                    systemImage: "checkmark.seal"
                )
            }
            return FamilyVerdict(
                headline: "No unusual activity observed",
                detail: "Current readings show no confirmed resource problem. A reliable normal range has not been learned yet.",
                level: .quiet,
                systemImage: "checkmark.circle"
            )
        }
    }

    private static func leakETASentence(_ forecast: RiskForecast) -> String {
        switch (forecast.etaKind, forecast.horizon) {
        case (.none, _): "No memory limit in sight yet."
        case (_, .breached): "Already above its memory limit."
        default: "Memory limit in \(forecast.etaText)."
        }
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else {
            return text
        }
        let capitalized = String(first).uppercased() + text.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
}
