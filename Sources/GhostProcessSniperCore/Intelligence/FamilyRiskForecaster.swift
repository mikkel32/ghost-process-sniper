import Foundation

public struct FamilyRiskForecaster: Sendable {
    public init() {}

    public func forecast(
        family: ProcessFamily,
        settings: ThresholdSettings,
        now: Date
    ) -> RiskForecast {
        let baseline = AnomalyBaseline(family: family)
        let trustedWindow = family.trend.hasSustainedHistory && family.hasRecentMeasurements(at: now)
        let memoryVelocity = trustedWindow && family.trend.memoryFitQuality >= 0.5 ? max(0, family.trend.memoryVelocityMegabytesPerMinute) : 0
        let cpuSlope = trustedWindow ? max(0, family.trend.cpuSlopePerMinute) : 0
        let patternAnalysis = MemoryPatternAnalysis.analyze(
            points: family.trend.memoryPoints,
            fitQuality: family.trend.memoryFitQuality
        )
        let acceleration = trustedWindow && patternAnalysis.pattern.indicatesAccumulation ? leakAcceleration(samples: family.trend.samples) : 0
        let memoryETA = etaSeconds(
            current: Double(family.totalPhysicalFootprintBytes),
            threshold: Double(settings.memoryBytes),
            ratePerMinute: memoryVelocity * 1_048_576,
            accelerationPerMinute2: acceleration * 1_048_576
        )
        let cpuETA = etaSeconds(
            current: family.totalCPUPercent,
            threshold: settings.cpuPercent,
            ratePerMinute: cpuSlope
        )
        let eta = minPositive(memoryETA, cpuETA).flatMap { $0.isFinite && $0 <= 86_400 ? $0 : nil }
        let horizon = trustedHorizon(ForecastHorizon.from(etaSeconds: eta), trend: family.trend)
        let recurrenceRisk = min(1, Double(baseline.recurrenceCount) / 5)
        let staleLikelihood = staleLikelihood(family: family, now: now)
        let projectedMemory = projectedMemoryBytes(family: family, velocity: memoryVelocity, horizonMinutes: 10)
        let projectedCPU = min(999, family.totalCPUPercent + cpuSlope * 10)
        let cpuEvidence = cpuEvidence(family: family, settings: settings)
        let inStartupGrace = startupGrace(family: family, now: now)
        let state = state(
            family: family,
            horizon: horizon,
            memoryVelocity: memoryVelocity,
            acceleration: acceleration,
            recurrenceRisk: recurrenceRisk,
            staleLikelihood: staleLikelihood,
            pattern: patternAnalysis,
            cpuEvidence: cpuEvidence,
            inStartupGrace: inStartupGrace,
            settings: settings
        )
        let confidence = confidence(
            family: family,
            state: state,
            horizon: horizon,
            baseline: baseline,
            memoryVelocity: memoryVelocity,
            recurrenceRisk: recurrenceRisk,
            staleLikelihood: staleLikelihood
        )
        let whyNow = whyNow(
            family: family,
            state: state,
            horizon: horizon,
            etaText: etaText(eta),
            baseline: baseline,
            memoryVelocity: memoryVelocity,
            acceleration: acceleration,
            staleLikelihood: staleLikelihood,
            pattern: patternAnalysis,
            cpuEvidence: cpuEvidence,
            inStartupGrace: inStartupGrace
        )

        return RiskForecast(
            state: state,
            horizon: horizon,
            confidence: confidence,
            etaSeconds: eta,
            etaText: etaText(eta),
            whyNow: whyNow,
            recommendedAction: recommendation(
                family: family,
                state: state,
                horizon: horizon,
                confidence: confidence
            ),
            projectedMemoryBytes: projectedMemory,
            projectedCPUPercent: projectedCPU,
            leakAccelerationMegabytesPerMinute2: acceleration,
            recurrenceRisk: recurrenceRisk,
            staleLikelihood: staleLikelihood,
            baseline: baseline,
            generatedAt: now
        )
    }

    struct CPUEvidence {
        let isRunaway: Bool
        let isSustained: Bool
    }

    // One CPU spike is a compile or an indexing burst; a runaway verdict
    // needs the window mostly hot, or an instantaneous reading at twice the
    // threshold. With too few samples, reserve "runaway" for an extreme
    // instantaneous reading; ordinary compile/index bursts stay as Heat.
    private func cpuEvidence(family: ProcessFamily, settings: ThresholdSettings) -> CPUEvidence {
        let cpuSamples = family.trend.samples.map(\.cpuPercent)
        guard cpuSamples.count >= 4, family.trend.hasSustainedHistory else {
            return CPUEvidence(
                isRunaway: family.totalCPUPercent >= settings.cpuPercent * 2,
                isSustained: false
            )
        }
        let hotFraction = Double(cpuSamples.filter { $0 >= settings.cpuPercent }.count) / Double(cpuSamples.count)
        if hotFraction >= 0.6, family.totalCPUPercent >= settings.cpuPercent {
            return CPUEvidence(isRunaway: true, isSustained: true)
        }
        return CPUEvidence(
            isRunaway: family.totalCPUPercent >= settings.cpuPercent * 2,
            isSustained: false
        )
    }

    // Freshly launched tools allocate fast while warming caches; give them a
    // short grace window before calling that behavior a leak.
    private func startupGrace(family: ProcessFamily, now: Date) -> Bool {
        let start = Date(timeIntervalSince1970: TimeInterval(family.root.identity.startTimeSeconds))
        return now.timeIntervalSince(start) < 150
    }

    private func state(
        family: ProcessFamily,
        horizon: ForecastHorizon,
        memoryVelocity: Double,
        acceleration: Double,
        recurrenceRisk: Double,
        staleLikelihood: Double,
        pattern: MemoryPatternAnalysis,
        cpuEvidence: CPUEvidence,
        inStartupGrace: Bool,
        settings: ThresholdSettings
    ) -> ForecastState {
        if family.score.level >= .critical {
            return .critical
        }
        if cpuEvidence.isRunaway || acceleration > 80 {
            return .runaway
        }
        if memoryVelocity >= settings.leakVelocityMegabytesPerMinute || horizon == .imminent || horizon == .breached {
            // Positive net velocity with a reclaiming shape (sawtooth) or a
            // single allocation step is not an accumulating leak. Startup
            // allocation bursts get the same benefit of the doubt.
            if pattern.pattern.indicatesAccumulation, !inStartupGrace {
                return .leaking
            }
            return .warming
        }
        if staleLikelihood >= 0.65 {
            return .stale
        }
        if horizon == .soon || memoryVelocity >= settings.leakVelocityMegabytesPerMinute * 0.35 || family.score.level >= .watch {
            // A family that is actively releasing memory with no threshold in
            // sight is recovering, not warming.
            if pattern.pattern == .declining, horizon == .unknown {
                return .quiet
            }
            return .warming
        }
        return .quiet
    }

    private func confidence(
        family: ProcessFamily,
        state: ForecastState,
        horizon: ForecastHorizon,
        baseline: AnomalyBaseline,
        memoryVelocity: Double,
        recurrenceRisk: Double,
        staleLikelihood: Double
    ) -> Double {
        var value = 0.18 + family.devConfidence * 0.22
        if family.trend.memoryPoints.count >= 3 { value += 0.16 }
        if baseline.sampleCount >= 6 { value += 0.14 }
        if memoryVelocity > 0 { value += 0.14 }
        if horizon == .imminent || horizon == .breached { value += 0.14 }
        value += recurrenceRisk * 0.08
        value += staleLikelihood * 0.08
        // With enough samples, a clean linear trend earns confidence and a
        // noisy one costs it; below 4 samples R² is meaningless either way.
        if family.trend.sampleCount >= 4, memoryVelocity > 0 {
            value += (family.trend.memoryFitQuality - 0.5) * 0.16
        }
        if state == .quiet { value = min(value, 0.46) }
        return min(1, max(0, value))
    }

    // An "imminent" call extrapolated from a noisy fit is a false alarm
    // waiting to happen — demote it until the trend earns trust.
    private func trustedHorizon(_ horizon: ForecastHorizon, trend: TrendMetrics) -> ForecastHorizon {
        guard horizon == .imminent, trend.sampleCount >= 4, trend.memoryFitQuality < 0.25 else {
            return horizon
        }
        return .soon
    }

    private func etaSeconds(
        current: Double,
        threshold: Double,
        ratePerMinute: Double,
        accelerationPerMinute2: Double = 0
    ) -> TimeInterval? {
        if current >= threshold {
            return 0
        }
        let gap = threshold - current
        if accelerationPerMinute2 > 0 {
            // gap = v·t + a·t²/2 — an accelerating leak crosses the threshold
            // sooner than its current velocity alone suggests.
            let discriminant = ratePerMinute * ratePerMinute + 2 * accelerationPerMinute2 * gap
            let minutes = (-ratePerMinute + discriminant.squareRoot()) / accelerationPerMinute2
            return minutes * 60
        }
        guard ratePerMinute > 0 else {
            return nil
        }
        return gap / ratePerMinute * 60
    }

    private func minPositive(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }

    // Compare time-aware regression slopes of the window halves. Refresh
    // cadence is adaptive, so sample-index slopes would make the exact same
    // process look more/less accelerated purely because sampling slowed down.
    private func leakAcceleration(samples: [TrendSample]) -> Double {
        guard samples.count >= 4 else {
            return 0
        }
        let midpoint = samples.count / 2
        let firstRange = 0..<midpoint
        let secondRange = midpoint..<samples.count
        guard firstRange.count >= 2, secondRange.count >= 2 else {
            return 0
        }

        let firstSlope = memorySlope(samples: samples, range: firstRange)
        let secondSlope = memorySlope(samples: samples, range: secondRange)
        let firstCenter = centerTime(samples: samples, range: firstRange)
        let secondCenter = centerTime(samples: samples, range: secondRange)
        let centerDeltaMinutes = secondCenter.timeIntervalSince(firstCenter) / 60
        guard centerDeltaMinutes > 0 else {
            return 0
        }
        return max(0, (secondSlope - firstSlope) / centerDeltaMinutes)
    }

    private func memorySlope(samples: [TrendSample], range: Range<Int>) -> Double {
        guard let firstIndex = range.first else { return 0 }
        let origin = samples[firstIndex].date
        let n = Double(range.count)
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumXY = 0.0
        for index in range {
            let x = samples[index].date.timeIntervalSince(origin) / 60
            let y = Double(samples[index].memoryBytes) / 1_048_576
            sumX += x
            sumY += y
            sumXX += x * x
            sumXY += x * y
        }
        let denominator = sumXX - (sumX * sumX / n)
        guard denominator > 0 else { return 0 }
        return (sumXY - (sumX * sumY / n)) / denominator
    }

    private func centerTime(samples: [TrendSample], range: Range<Int>) -> Date {
        let first = samples[range.lowerBound].date.timeIntervalSince1970
        let last = samples[range.upperBound - 1].date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (first + last) / 2)
    }

    private func staleLikelihood(family: ProcessFamily, now: Date) -> Double {
        let start = Date(timeIntervalSince1970: TimeInterval(family.root.identity.startTimeSeconds))
        let ageMinutes = max(0, now.timeIntervalSince(start) / 60)
        var value = 0.0
        if family.root.parentPID == 1 { value += 0.35 }
        if ageMinutes >= 180 { value += 0.25 }
        if family.devConfidence >= 0.45 { value += 0.2 }
        if family.totalCPUPercent < 5, family.totalPhysicalFootprintBytes > 512 * 1_048_576 { value += 0.15 }
        if family.forensics.isPartial { value -= 0.05 }
        return min(1, max(0, value))
    }

    private func projectedMemoryBytes(family: ProcessFamily, velocity: Double, horizonMinutes: Double) -> UInt64 {
        let projected = Double(family.totalPhysicalFootprintBytes) + velocity * 1_048_576 * horizonMinutes
        return UInt64(max(0, projected))
    }

    private func etaText(_ eta: TimeInterval?) -> String {
        guard let eta else {
            return "No threshold ETA"
        }
        if eta <= 0 {
            return "Breached now"
        }
        if eta < 60 {
            return "<1 min"
        }
        if eta < 60 * 60 {
            return "\(Int((eta / 60).rounded())) min"
        }
        return String(format: "%.1f hr", eta / 3600)
    }

    private func whyNow(
        family: ProcessFamily,
        state: ForecastState,
        horizon: ForecastHorizon,
        etaText: String,
        baseline: AnomalyBaseline,
        memoryVelocity: Double,
        acceleration: Double,
        staleLikelihood: Double,
        pattern: MemoryPatternAnalysis,
        cpuEvidence: CPUEvidence,
        inStartupGrace: Bool
    ) -> String {
        var parts: [String] = []
        if cpuEvidence.isSustained {
            parts.append("CPU held above threshold for most of the window")
        }
        if memoryVelocity > 0 {
            parts.append("memory is rising \(Int(memoryVelocity.rounded())) MB/min")
        }
        if inStartupGrace, memoryVelocity > 0 {
            parts.append("inside startup grace window")
        }
        if pattern.pattern == .sawtooth {
            parts.append("churns in reclaim cycles (likely GC), not accumulating")
        }
        if pattern.pattern == .stepJump {
            parts.append("growth came from one allocation step")
        }
        if pattern.pattern == .declining {
            parts.append("memory is being released")
        }
        if acceleration > 0 {
            parts.append("leak is accelerating")
        }
        if baseline.memoryMultiple >= 1.5 {
            parts.append(String(format: "%.1fx normal memory", baseline.memoryMultiple))
        }
        if horizon == .soon || horizon == .imminent {
            parts.append("threshold ETA \(etaText)")
        }
        if staleLikelihood >= 0.65 {
            parts.append("background process looks stale")
        }
        if memoryVelocity > 0, family.trend.sampleCount >= 4, family.trend.memoryFitQuality >= 0.8 {
            parts.append("steady linear climb")
        }
        if parts.isEmpty {
            parts.append(state == .quiet ? "inside learned range" : "predictive signals are warming")
        }
        return parts.prefix(3).joined(separator: ", ")
    }

    private func recommendation(
        family: ProcessFamily,
        state: ForecastState,
        horizon: ForecastHorizon,
        confidence: Double
    ) -> TriageRecommendation {
        switch state {
        case .critical, .runaway:
            return TriageRecommendation(
                title: family.isKillable ? "Preview Kill Tree" : "Inspect owner",
                detail: family.isKillable ? "This family is already beyond safe forecast bounds." : "Protected or foreign processes are present.",
                action: family.isKillable ? .suggestKill : .inspect,
                confidence: confidence
            )
        case .leaking:
            return TriageRecommendation(
                title: "Inspect leak",
                detail: horizon == .imminent ? "Likely to cross threshold soon." : "Memory trend is rising faster than normal.",
                action: .inspect,
                confidence: confidence
            )
        case .stale:
            return TriageRecommendation(
                title: "Check stale background tree",
                detail: "Long-running dev process appears detached or forgotten.",
                action: family.isKillable ? .suggestKill : .inspect,
                confidence: confidence
            )
        case .warming:
            return TriageRecommendation(
                title: "Watch closely",
                detail: "Predictive signals are warming before a hard threshold breach.",
                action: .highlight,
                confidence: confidence
            )
        case .quiet:
            return TriageRecommendation(
                title: "Keep watching",
                detail: "No action needed unless this family changes.",
                action: .inspect,
                confidence: confidence
            )
        }
    }
}
