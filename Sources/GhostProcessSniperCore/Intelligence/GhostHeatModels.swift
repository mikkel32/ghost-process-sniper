import Foundation

/// Urgency is intentionally separate from the evidence score. A family can
/// accumulate a large score from several noisy signals without being in a
/// sustained, dangerous state.
public struct GhostHeat: Equatable, Sendable {
    public let value: Double
    public let level: GhostLevel
    public let confidence: Double
    public let evidence: [String]
    /// Trend-proven persistence only (sustained CPU or a sustained leak).
    /// History gates read this, so it must never count context.
    public let sustainedSignalCount: Int
    /// Context votes that corroborate urgency without proving persistence:
    /// a learned-baseline anomaly or host memory pressure.
    public let corroborationCount: Int

    public static let quiet = GhostHeat(
        value: 0,
        level: .quiet,
        confidence: 0,
        evidence: [],
        sustainedSignalCount: 0
    )

    public init(
        value: Double,
        level: GhostLevel,
        confidence: Double,
        evidence: [String],
        sustainedSignalCount: Int,
        corroborationCount: Int = 0
    ) {
        self.value = min(100, max(0, value))
        self.level = level
        self.confidence = min(1, max(0, confidence))
        self.evidence = Array(evidence.prefix(5))
        self.sustainedSignalCount = max(0, sustainedSignalCount)
        self.corroborationCount = max(0, corroborationCount)
    }

    /// A copy with presentation-level changes that keeps confidence and both
    /// vote counts, for suppression, hysteresis and visibility floors.
    public func replacing(value: Double? = nil, level: GhostLevel? = nil, evidence: [String]? = nil) -> GhostHeat {
        GhostHeat(
            value: value ?? self.value,
            level: level ?? self.level,
            confidence: confidence,
            evidence: evidence ?? self.evidence,
            sustainedSignalCount: sustainedSignalCount,
            corroborationCount: corroborationCount
        )
    }

    static let sustainedCPUEvidence = "CPU stayed elevated across the sampling window"
    static let instantCPUEvidence = "CPU is high now, but persistence is not proven yet"
    static let memoryAboveLimitEvidence = "Memory footprint is above its adaptive limit"

    public var valueText: String {
        "\(Int(value.rounded()))"
    }

    public var confidenceText: String {
        "\(Int((confidence * 100).rounded()))%"
    }

    /// Heat can react quickly, while disruptive product behavior waits for
    /// corroboration. Critical heat is always actionable; ordinary Hot heat
    /// needs reasonable confidence, a sustained signal, or two context votes.
    public var isConfirmed: Bool {
        level >= .critical || confidence >= 0.45 || sustainedSignalCount > 0 || corroborationCount >= 2
    }

    public var shouldRecordIncident: Bool {
        // Preserve extreme transient spikes in history even before their
        // persistence is proven. This is deliberately less strict than the
        // live-alert policy below.
        level >= .hot && (isConfirmed || value >= 85)
    }

    public var shouldRaiseLiveAlert: Bool {
        level >= .critical || (level >= .hot && isConfirmed)
    }

    public var shouldNotify: Bool {
        level >= .critical || (level >= .hot && confidence >= 0.55)
    }

    static func compatibility(score: Double, level: GhostLevel) -> GhostHeat {
        GhostHeat(
            value: min(100, max(score, Double(level.rawValue) * 28)),
            level: level,
            confidence: level >= .hot ? 0.6 : 0.35,
            evidence: ["Legacy severity signal"],
            sustainedSignalCount: level >= .hot ? 1 : 0
        )
    }
}

public enum GhostHeatModel {
    public static func initial(
        memoryRatio: Double,
        cpuRatio: Double,
        cpuThreshold: Double,
        gpuRatio: Double,
        leakRatio: Double,
        trend: TrendMetrics,
        hardwareLevel: GhostLevel,
        cpuBehavior: CPUBehavior = .none
    ) -> GhostHeat {
        // The real limit, never one inferred from the last trend sample: that
        // sample is stale whenever a cached reading skipped the append.
        let cpuSamples = trend.samples.map(\.cpuPercent)
        let sustainedCPUFraction: Double
        if cpuSamples.count >= 4, cpuThreshold > 0 {
            sustainedCPUFraction = Double(cpuSamples.filter { $0 >= cpuThreshold }.count) / Double(cpuSamples.count)
        } else {
            sustainedCPUFraction = 0
        }

        let trendTrust = trend.hasSustainedHistory
            ? min(1, max(0.25, trend.memoryFitQuality))
            : min(0.45, Double(trend.sampleCount) / 8)
        let cpuPersistence = cpuSamples.count >= 4 ? (0.45 + sustainedCPUFraction * 0.55) : 0.42

        let memoryHeat = min(100, memoryRatio * 62)
        let cpuHeat = min(100, cpuRatio * 72) * cpuPersistence
        let gpuHeat = min(100, gpuRatio * 70) * 0.68
        let leakHeat = min(100, leakRatio * 78) * trendTrust
        let axes = [memoryHeat, cpuHeat, gpuHeat, leakHeat].sorted(by: >)

        var heat = axes.first ?? 0
        if axes.count > 1 { heat += axes[1] * 0.22 }
        if axes.count > 2 { heat += axes[2] * 0.08 }
        // Hardware-offender detection is derived from these same process
        // metrics. Use it as a visibility/severity floor, not as an extra vote;
        // otherwise one high memory/CPU reading gets counted twice.
        if hardwareLevel == .hot { heat = max(58, heat) }
        if hardwareLevel == .critical { heat = max(68, heat) }
        heat = min(100, heat)

        // Builds and tests are expected to peg the CPU: only the ledger's
        // fifteen-minute rule makes their CPU sustained. Anything else needs
        // the ledger or 90 s of window, as the forecaster's runaway rule
        // does; four samples over 15 s prove nothing about minutes.
        let isBurst = cpuBehavior.kind == .expectedBurst
        let windowSustained = trend.hasSustainedHistory && sustainedCPUFraction >= 0.6 && cpuRatio >= 1 &&
            trend.observedSeconds >= 90
        let sustainedCPU = isBurst ? cpuBehavior.isSustained : (windowSustained || cpuBehavior.isSustained)
        let pattern = trend.resolvedPattern
        let sustainedLeak = trend.hasSustainedHistory && leakRatio >= 1 && pattern.indicatesAccumulation &&
            (trend.memoryFitQuality >= 0.5 || pattern.pattern == .risingFloor)
        let corroboratingAxes = axes.filter { $0 >= 55 }.count
        let instantCorroboration = [memoryRatio >= 1, cpuRatio >= 0.8, gpuRatio >= 0.55, leakRatio >= 0.8]
            .filter { $0 }
            .count >= 2
        // A single signal can be immediately important without being
        // "Critical". Treat truly extreme instantaneous resource use as Hot,
        // then let persistence/corroboration decide whether it ever becomes
        // Critical. This keeps a 2.4x memory breach visible without reviving
        // the old score==severity behavior.
        let extremeInstantSignal = memoryRatio >= 1.5 || (cpuRatio >= 2.5 && !isBurst) || gpuRatio >= 1.25
        let sustainedCount = (sustainedCPU ? 1 : 0) + (sustainedLeak ? 1 : 0)
        // Hardware detection reads the same numbers; it only qualifies Hot
        // when those numbers are themselves near the family's limits. Its
        // CPU thresholds are one process's, so CPU must reach the family's.
        let hardwareCorroborates = hardwareLevel >= .hot && (memoryRatio >= 0.85 || cpuRatio >= 1)

        var evidence: [String] = []
        if sustainedCPU {
            evidence.append(GhostHeat.sustainedCPUEvidence)
            if cpuBehavior.isSustained, let first = cpuBehavior.reason.first {
                evidence.append(String(first).uppercased() + cpuBehavior.reason.dropFirst())
            }
        }
        else if cpuRatio >= 1 { evidence.append(isBurst ? "Build or test work is using CPU as expected" : GhostHeat.instantCPUEvidence) }
        if sustainedLeak { evidence.append("Memory growth is sustained with a trusted trend") }
        else if leakRatio >= 1 { evidence.append("Memory is rising, but the trend still needs confirmation") }
        if memoryRatio >= 1 { evidence.append(GhostHeat.memoryAboveLimitEvidence) }
        if gpuRatio >= 0.55 { evidence.append("GPU load is materially elevated") }
        if hardwareLevel >= .hot { evidence.append("Hardware-offender detection also flags this process") }

        let confidence = min(
            1,
            0.24 +
                min(0.28, Double(trend.sampleCount) * 0.035) +
                // R² of two or three points is trivially high; it is no evidence.
                (trend.sampleCount >= 4 ? trend.memoryFitQuality * 0.2 : 0) +
                (corroboratingAxes >= 2 ? 0.18 : 0) +
                (sustainedCount > 0 ? 0.14 : 0)
        )

        let criticalEvidence =
            (sustainedCPU && cpuRatio >= 2) ||
            (sustainedLeak && leakRatio >= 1.65) ||
            (sustainedCount >= 1 && corroboratingAxes >= 2)
        // Most of every core for minutes slows the whole Mac: at least Hot.
        if cpuBehavior.kind == .machineSaturation {
            heat = max(heat, 58)
        }
        let level: GhostLevel
        if heat >= 80, criticalEvidence, confidence >= 0.58 {
            level = .critical
        } else if heat >= 58, (extremeInstantSignal || corroboratingAxes >= 2 || instantCorroboration || sustainedCount > 0 ||
                                hardwareCorroborates || cpuBehavior.kind == .machineSaturation) {
            level = .hot
        } else if heat >= 30 || hardwareLevel >= .watch || memoryRatio >= 0.8 || cpuRatio >= 0.8 || leakRatio >= 0.6 || gpuRatio >= 0.4 {
            level = .watch
        } else {
            level = .quiet
        }

        return GhostHeat(
            value: heat,
            level: level,
            confidence: confidence,
            evidence: evidence,
            sustainedSignalCount: sustainedCount
        )
    }

    public static func refined(
        base: GhostHeat,
        family: ProcessFamily,
        baseline: FamilyBaseline?,
        recentIncidentCount: Int,
        pressure: SystemMemoryPressure,
        pressureShare: PressureShare? = nil,
        forecast: RiskForecast
    ) -> GhostHeat {
        var heat = base.value
        var evidence = base.evidence
        var contextVotes = base.corroborationCount
        var confidence = base.confidence
        var sustained = base.sustainedSignalCount

        // Only the baseline can say a service normally idles, so this
        // ledger-proven persistence is judged here, not in the builder.
        if let behavior = forecast.cpuBehavior, behavior.kind == .idleServiceBurning {
            heat += 12
            evidence.append(behavior.reason.prefix(1).uppercased() + behavior.reason.dropFirst())
            confidence += 0.08
            sustained += 1
        }

        if let baseline, baseline.isMeasurementTrusted {
            let memoryMultiple = baseline.memoryMultiple(for: family.totalPhysicalFootprintBytes)
            if baseline.memoryZScore(for: family.totalPhysicalFootprintBytes) >= 3, memoryMultiple >= 1.3 {
                heat += min(14, (memoryMultiple - 1) * 7)
                evidence.append("Memory is \(RadarFormat.fixed1(memoryMultiple))x this family's learned normal")
                confidence += 0.08
                if memoryMultiple >= 2.2 { contextVotes += 1 }
                if memoryMultiple >= 3 {
                    heat = max(60, heat)
                    confidence = max(0.5, confidence)
                }
            }
            if let cpuAnomaly = BaselineCPUAnomaly(baseline: baseline, cpuPercent: family.totalCPUPercent) {
                heat += min(10, cpuAnomaly.multiple * 2)
                evidence.append(cpuAnomaly.evidence)
                confidence += 0.05
            }
        }

        if recentIncidentCount > 0, base.level >= .watch {
            heat += min(8, Double(recentIncidentCount) * 2)
            evidence.append("This family has repeated incidents")
            confidence += min(0.08, Double(recentIncidentCount) * 0.02)
            // Old incidents are context, not independent evidence of a new problem.
        }

        // Pressure weighs by the family's share of used memory and of its
        // growth; only a family driving the growth is corroborated by it.
        let share = pressureShare ?? PressureAttribution.share(for: family, pressure: pressure)
        if pressure.isKnown, pressure.level >= .warning,
           family.totalPhysicalFootprintBytes > 512 * 1_048_576, share.boostScale > 0.05 {
            heat += (pressure.level == .critical ? 16.0 : 9.0) * share.boostScale
            if pressure.level == .critical, family.totalPhysicalFootprintBytes >= 1_073_741_824, share.boostScale >= 1 {
                heat = max(32, heat)
            }
            evidence.append("Host memory pressure is \(pressure.level.label.lowercased()); this family holds \(share.text)")
            confidence += 0.08 * share.boostScale
            if share.corroboratesPressure {
                contextVotes += 1
            }
        }

        let forecastIsHeatTrusted = forecast.confidence >= 0.55 && family.trend.hasSustainedHistory &&
            (sustained > 0 || family.trend.credibleMemoryVelocity > 0)
        if forecastIsHeatTrusted {
            switch forecast.state {
            case .quiet:
                break
            case .warming, .stale:
                heat += 4 * forecast.confidence
            case .leaking:
                heat += 10 * forecast.confidence
                // The forecast is derived from the same samples, not a second vote.
            case .runaway, .critical:
                heat += 16 * forecast.confidence
                // The forecast is derived from the same samples, not a second vote.
            }
            if forecast.state >= .leaking {
                evidence.append("Forecast confirms \(forecast.state.label.lowercased()) behavior")
                confidence += 0.08
            }
        }

        heat = min(100, heat)
        confidence = min(1, confidence)

        // Levels weigh persistence and context together; only the history
        // gates distinguish them.
        let corroboration = sustained + contextVotes
        let criticalForecast = forecastIsHeatTrusted && forecast.confidence >= 0.62 && forecast.state >= .runaway
        let refinedLevel: GhostLevel
        if heat >= 80, confidence >= 0.62, (corroboration >= 2 || criticalForecast || pressure.level == .critical) {
            refinedLevel = .critical
        } else if heat >= 58, confidence >= 0.45,
                  (corroboration >= 1 || (forecastIsHeatTrusted && forecast.state >= .leaking)) {
            refinedLevel = .hot
        } else if heat >= 30 {
            refinedLevel = .watch
        } else {
            refinedLevel = .quiet
        }
        let level = max(base.level, refinedLevel)

        return GhostHeat(
            value: heat,
            level: level,
            confidence: confidence,
            evidence: evidence,
            sustainedSignalCount: sustained,
            corroborationCount: contextVotes
        )
    }
}

/// CPU well above a family's learned normal: at least 3x the usual level, 20
/// points above the top of its usual range, and busy in absolute terms. A
/// normally idle family qualifies too; its ratio is against a 2% floor.
struct BaselineCPUAnomaly {
    let multiple: Double
    let reason: String
    let evidence: String

    init?(baseline: FamilyBaseline, cpuPercent: Double) {
        let multiple = baseline.cpuMultiple(for: cpuPercent)
        guard baseline.isMeasurementTrusted, multiple >= 3, baseline.cpuExcess(for: cpuPercent) >= 20, cpuPercent > 20 else {
            return nil
        }
        self.multiple = multiple
        // "200x usual CPU" says less than the two numbers it divides.
        if baseline.meanCPUPercent < 5 {
            let comparison = "\(RadarFormat.fixed0(cpuPercent))% CPU vs about \(RadarFormat.fixed1(baseline.meanCPUPercent))% normally"
            reason = comparison
            evidence = "CPU is at " + comparison
        } else {
            reason = "\(RadarFormat.fixed1(multiple))x usual CPU"
            evidence = "CPU is \(RadarFormat.fixed1(multiple))x this family's learned normal"
        }
    }
}
