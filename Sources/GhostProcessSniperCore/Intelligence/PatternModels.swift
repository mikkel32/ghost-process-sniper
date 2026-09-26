import Foundation

/// The shape of a family's memory behavior over the trend window. The shape
/// matters as much as the slope: a sawtooth that keeps reclaiming memory is
/// GC churn, not a leak, even when its net velocity is positive.
public enum MemoryPattern: String, Codable, CaseIterable, Sendable {
    case unknown
    case flat
    case steadyClimb
    case sawtooth
    case stepJump
    case volatile
    case declining

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .flat: "Flat"
        case .steadyClimb: "Steady Climb"
        case .sawtooth: "Sawtooth"
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
        case .stepJump: "stairs"
        case .volatile: "waveform.path.ecg"
        case .declining: "chart.line.downtrend.xyaxis"
        }
    }

    /// Whether a positive net velocity with this shape should still be
    /// treated as an accumulating leak.
    public var indicatesAccumulation: Bool {
        switch self {
        case .steadyClimb, .volatile, .unknown: true
        case .flat, .sawtooth, .stepJump, .declining: false
        }
    }
}

public struct MemoryPatternAnalysis: Equatable, Sendable {
    public let pattern: MemoryPattern
    public let confidence: Double
    public let detail: String

    public static let unknown = MemoryPatternAnalysis(
        pattern: .unknown,
        confidence: 0,
        detail: "Collecting samples"
    )

    public init(pattern: MemoryPattern, confidence: Double, detail: String) {
        self.pattern = pattern
        self.confidence = min(1, max(0, confidence))
        self.detail = detail
    }

    /// Classify a memory series (bytes) by its shape.
    public static func analyze(points: [Double], fitQuality: Double) -> MemoryPatternAnalysis {
        guard points.count >= 4, let first = points.first, let last = points.last else {
            return .unknown
        }

        let megabytes = points.map { $0 / 1_048_576 }
        var totalRise = 0.0
        var totalFall = 0.0
        var largestStep = 0.0
        var dipCount = 0
        for index in 1..<megabytes.count {
            let delta = megabytes[index] - megabytes[index - 1]
            if delta > 0 {
                totalRise += delta
                largestStep = max(largestStep, delta)
            } else if delta < 0 {
                totalFall += -delta
                dipCount += 1
            }
        }

        let netMegabytes = (last - first) / 1_048_576
        let mean = megabytes.reduce(0, +) / Double(megabytes.count)
        let range = (megabytes.max() ?? 0) - (megabytes.min() ?? 0)

        if range < max(16, mean * 0.03) {
            return MemoryPatternAnalysis(
                pattern: .flat,
                confidence: 0.9,
                detail: String(format: "Memory holds within %.0f MB of %.0f MB", range, mean)
            )
        }

        if netMegabytes < -max(16, mean * 0.03) {
            return MemoryPatternAnalysis(
                pattern: .declining,
                confidence: 0.8,
                detail: String(format: "Released %.0f MB across the window", -netMegabytes)
            )
        }

        // One jump that dominates the total growth is an allocation event,
        // not a continuous leak.
        if totalRise > 0, largestStep >= totalRise * 0.7, largestStep >= 32 {
            return MemoryPatternAnalysis(
                pattern: .stepJump,
                confidence: min(1, largestStep / max(1, totalRise)),
                detail: String(format: "One %.0f MB step accounts for the growth", largestStep)
            )
        }

        // Repeated meaningful dips mean memory is being reclaimed in cycles.
        if dipCount >= 2, totalRise > 0, totalFall >= totalRise * 0.35 {
            let reclaimed = Int(min(1, totalFall / totalRise) * 100)
            return MemoryPatternAnalysis(
                pattern: .sawtooth,
                confidence: min(1, totalFall / totalRise),
                detail: "Reclaims \(reclaimed)% of what it allocates across \(dipCount) dips"
            )
        }

        if fitQuality >= 0.7, netMegabytes > 0 {
            return MemoryPatternAnalysis(
                pattern: .steadyClimb,
                confidence: fitQuality,
                detail: String(format: "Monotonic growth of %.0f MB with little reclaim", netMegabytes)
            )
        }

        return MemoryPatternAnalysis(
            pattern: .volatile,
            confidence: 0.5,
            detail: String(format: "Irregular swings across a %.0f MB range", range)
        )
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
                    detail: "Climbing \(Int(velocity.rounded())) MB/min with little reclaim. \(forecast.etaText == "No threshold ETA" ? "No threshold in sight yet." : "Threshold ETA \(forecast.etaText).")",
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

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else {
            return text
        }
        let capitalized = String(first).uppercased() + text.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
}
