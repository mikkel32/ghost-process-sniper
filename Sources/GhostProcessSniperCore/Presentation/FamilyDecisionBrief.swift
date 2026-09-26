import Foundation

/// The family page's single judgement: what is wrong, how sure the engine
/// is, and what to do. It merges the verdict, the assessment and the trend
/// evidence so the page never shows competing sentences side by side.
public struct FamilyDecisionBrief: Equatable, Sendable {
    public enum Confidence: Int, Comparable, Sendable {
        case low
        case medium
        case high

        public var label: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum Recommendation: Equatable, Sendable {
        case stop
        case watch
        case leaveAlone
        case waitForReading
    }

    public enum Mute: Equatable, Sendable {
        case none
        case snoozed
        case ignored
    }

    public let headline: String
    public let detail: String
    public let level: GhostLevel
    public let systemImage: String
    public let confidence: Confidence
    public let confidenceText: String
    public let recommendation: Recommendation
    public let recommendationText: String
    public let evidence: [String]
    /// What a stop would give back, such as "Frees 1.2 GB and 45% CPU".
    public let reclaimText: String
    /// Memory against the learned normal, such as "2.1x usual".
    public let baselineText: String
    public let mute: Mute

    public init(
        family: ProcessFamily,
        verdict: FamilyVerdict,
        assessment: ProcessAssessment,
        pattern: MemoryPatternAnalysis,
        culprit: CulpritAnalysis
    ) {
        headline = verdict.headline
        detail = verdict.detail
        level = verdict.level
        systemImage = verdict.systemImage
        mute = switch family.alertState.kind {
        case .snoozed: .snoozed
        case .ignored: .ignored
        default: .none
        }

        let isCurrent = family.hasRecentMeasurements(at: family.lastScoredAt ?? family.root.sampledAt)
        let observed = family.trend.observedSeconds
        let fit = family.trend.memoryFitQuality
        // A flat or clearly cyclic shape is as trustworthy as a clean regression.
        let shapeIsClear = pattern.pattern != .unknown && pattern.confidence >= 0.8
        let isSteady = fit >= 0.8 || shapeIsClear || family.forecast.confidence >= 0.68
        if !isCurrent || observed < 15 || family.trend.sampleCount < 4 {
            confidence = .low
        } else if observed >= 60, isSteady {
            confidence = .high
        } else {
            confidence = .medium
        }
        let shape = shapeIsClear ? "\(pattern.pattern.label.lowercased()) shape"
            : fit >= 0.8 ? "steady trend" : fit >= 0.4 ? "mixed trend" : "noisy trend"
        confidenceText = Self.confidenceText(confidence, isCurrent: isCurrent, observed: observed, shape: shape, hasTrend: family.trend.sampleCount >= 4)

        let hasOwnedTargets = !family.ownedIdentities.isEmpty
        let wantsStop = verdict.level >= .hot ||
            (family.forecast.state == .stale && family.forecastIsCredibleEarlyWarning)
        if mute != .none {
            recommendation = .leaveAlone
            recommendationText = mute == .snoozed
                ? "Snoozed: alerts are paused. Unsnooze to hear about it again."
                : "Ignored: it will not raise alerts. Stop ignoring to watch it again."
        } else if !isCurrent {
            recommendation = .waitForReading
            recommendationText = assessment.recommendation
        } else if wantsStop, hasOwnedTargets {
            recommendation = .stop
            recommendationText = assessment.recommendation
        } else if wantsStop {
            recommendation = .watch
            recommendationText = "It belongs to another user or the system, so it cannot be stopped from here."
        } else if verdict.level >= .watch {
            recommendation = .watch
            recommendationText = assessment.recommendation
        } else {
            recommendation = .leaveAlone
            recommendationText = assessment.recommendation
        }

        var evidence = family.score.components
            .sorted { $0.impact > $1.impact }
            .prefix(3)
            .map { "\($0.title): \($0.detail)" }
        for item in culprit.evidence where !evidence.contains(item) {
            evidence.append(item)
        }
        self.evidence = evidence

        var reclaim = ["Frees \(RadarFormat.bytes(family.totalPhysicalFootprintBytes))"]
        if family.totalCPUPercent >= 1 {
            reclaim.append("\(RadarFormat.percent(family.totalCPUPercent)) CPU")
        }
        reclaimText = reclaim.joined(separator: " and ")
        if let baseline = family.baseline, baseline.isMeasurementTrusted {
            baselineText = String(format: "%.1fx usual", baseline.memoryMultiple(for: family.totalPhysicalFootprintBytes))
        } else {
            baselineText = "Learning"
        }
    }

    private static func confidenceText(
        _ confidence: Confidence,
        isCurrent: Bool,
        observed: TimeInterval,
        shape: String,
        hasTrend: Bool
    ) -> String {
        guard isCurrent else {
            return "\(confidence.label) confidence: waiting for a complete reading"
        }
        guard hasTrend, observed >= 15 else {
            return "\(confidence.label) confidence: still building history"
        }
        let watched = observed >= 120 ? "\(Int((observed / 60).rounded())) min" : "\(Int(observed.rounded())) s"
        return "\(confidence.label) confidence: watched \(watched), \(shape)"
    }
}
