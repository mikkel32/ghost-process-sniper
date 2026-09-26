import Foundation

public struct FamilyRiskForecaster: Sendable {
    private let processorCount: Int
    private let physicalMemoryBytes: UInt64

    /// Tests pass a fixed core count and RAM; the Mac's own are the default.
    public init(
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.processorCount = max(1, processorCount)
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public func forecast(
        family: ProcessFamily,
        settings: ThresholdSettings,
        now: Date,
        pressure: SystemMemoryPressure = .unknown,
        hostOutlook: HostMemoryOutlook? = nil
    ) -> RiskForecast {
        let baseline = AnomalyBaseline(family: family)
        let trustedWindow = family.trend.hasSustainedHistory && family.hasRecentMeasurements(at: now)
        let patternAnalysis = family.trend.resolvedPattern
        // The long horizon catches the 5-40 MB/min creep the short window's
        // noise hides; it is proven over twenty minutes, not a minute.
        let slowLeak = family.longTermTrend.isSlowLeak(physicalMemoryBytes: physicalMemoryBytes)
        let shortVelocity = forecastVelocity(trend: family.trend, pattern: patternAnalysis, trusted: trustedWindow)
        let memoryVelocity = slowLeak ? max(shortVelocity, family.longTermTrend.slopeMegabytesPerMinute) : shortVelocity
        let cpuSlope = trustedWindow ? max(0, family.trend.cpuSlopePerMinute) : 0
        let acceleration = trustedWindow && patternAnalysis.indicatesAccumulation ? leakAcceleration(samples: family.trend.samples) : 0
        // Only memory has a meaningful time-to-limit. A linear CPU% ETA is an
        // extrapolation of noise; CPU above its limit feeds CPU evidence instead.
        let memoryETA = memoryETASeconds(
            family: family,
            settings: settings,
            velocity: memoryVelocity,
            acceleration: acceleration
        ).flatMap { $0.isFinite && $0 <= 86_400 ? $0 : nil }
        // While the Mac's headroom is shrinking, this family's growth may
        // make pressure critical before it reaches its own limit.
        let hostETA = hostOutlook == nil ? nil :
            PressureAttribution.familyETASeconds(velocity: memoryVelocity, pressure: pressure).flatMap { $0 <= 86_400 ? $0 : nil }
        let eta: TimeInterval?
        let etaKind: ForecastETAKind
        if let hostETA, hostETA < (memoryETA ?? .infinity) {
            eta = hostETA
            etaKind = .hostMemory
        } else {
            eta = memoryETA
            etaKind = memoryETA == nil ? .none : .memoryLimit
        }
        // Breached means above the family's own limit; running out of host
        // headroom is at most imminent.
        let rawHorizon = ForecastHorizon.from(etaSeconds: eta)
        let horizon = trustedHorizon(etaKind == .hostMemory && rawHorizon == .breached ? .imminent : rawHorizon, trend: family.trend)
        let recurrenceRisk = min(1, Double(baseline.recurrenceCount) / 5)
        let staleLikelihood = family.forgottenAssessment.likelihood
        let projectedMemory = projectedMemoryBytes(family: family, velocity: memoryVelocity, horizonMinutes: 10)
        let projectedCPU = min(999, family.totalCPUPercent + cpuSlope * 10)
        let cpuEvidence = cpuEvidence(family: family, settings: settings)
        let inStartupGrace = startupGrace(family: family, now: now)
        let state = state(
            family: family,
            horizon: horizon,
            memoryVelocity: memoryVelocity,
            recurrenceRisk: recurrenceRisk,
            staleLikelihood: staleLikelihood,
            pattern: patternAnalysis,
            cpuEvidence: cpuEvidence,
            inStartupGrace: inStartupGrace,
            slowLeak: slowLeak,
            settings: settings
        )
        let confidence = confidence(
            family: family,
            state: state,
            horizon: horizon,
            baseline: baseline,
            memoryVelocity: memoryVelocity,
            recurrenceRisk: recurrenceRisk,
            staleLikelihood: staleLikelihood,
            acceleration: acceleration,
            slowLeak: slowLeak
        )
        let whyNow = whyNow(
            family: family,
            state: state,
            horizon: horizon,
            etaText: etaText(eta),
            etaKind: etaKind,
            baseline: baseline,
            memoryVelocity: memoryVelocity,
            acceleration: acceleration,
            staleLikelihood: staleLikelihood,
            pattern: patternAnalysis,
            cpuEvidence: cpuEvidence,
            inStartupGrace: inStartupGrace,
            slowLeak: slowLeak,
            settings: settings
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
                etaKind: etaKind,
                confidence: confidence,
                cpu: cpuEvidence.behavior
            ),
            projectedMemoryBytes: projectedMemory,
            projectedCPUPercent: projectedCPU,
            leakAccelerationMegabytesPerMinute2: acceleration,
            recurrenceRisk: recurrenceRisk,
            staleLikelihood: staleLikelihood,
            baseline: baseline,
            generatedAt: now,
            etaKind: etaKind,
            cpuBehavior: cpuEvidence.behavior.kind == .none && !cpuEvidence.behavior.isSustained ? nil : cpuEvidence.behavior
        )
    }

    // The ETA follows the net slope whenever the fit is trustworthy; the
    // shape gate later decides whether that growth is a leak or churn. A leak
    // under GC grows at the rate of its floor, not its saw teeth.
    private func forecastVelocity(trend: TrendMetrics, pattern: MemoryPatternAnalysis, trusted: Bool) -> Double {
        guard trusted else { return 0 }
        if pattern.pattern == .risingFloor, !trend.samples.isEmpty {
            return max(0, pattern.floorSlopeMegabytesPerMinute)
        }
        return trend.memoryFitQuality >= 0.5 ? max(0, trend.memoryVelocityMegabytesPerMinute) : 0
    }

    struct CPUEvidence {
        let isRunaway: Bool
        let isSustained: Bool
        let isBreached: Bool
        let behavior: CPUBehavior
    }

    // An instantaneous extreme is Hot at most; runaway needs persistence.
    // Builds and tests never run away on CPU until the ledger has watched
    // them hold their level for fifteen minutes. Otherwise a busy loop, a
    // saturated Mac, a normally idle service burning CPU, or a limit held
    // for minutes (or across a 90 s window) is the evidence.
    private func cpuEvidence(family: ProcessFamily, settings: ThresholdSettings) -> CPUEvidence {
        let limit = CPUBehaviorAnalyzer.familyCPULimit(settings: settings, processorCount: processorCount)
        let behavior = CPUBehaviorAnalyzer.analyze(
            activity: family.cpuActivity,
            classification: family.classification,
            memberCount: family.members.count,
            baseline: family.baseline,
            processorCount: processorCount,
            cpuThreshold: limit
        )
        let isBreached = family.totalCPUPercent >= limit
        if behavior.kind == .expectedBurst {
            return CPUEvidence(isRunaway: behavior.isRunaway, isSustained: behavior.isSustained, isBreached: isBreached, behavior: behavior)
        }
        let cpuSamples = family.trend.samples.map(\.cpuPercent)
        var windowSustained = false
        if cpuSamples.count >= 4, family.trend.hasSustainedHistory, isBreached {
            let hotFraction = Double(cpuSamples.filter { $0 >= limit }.count) / Double(cpuSamples.count)
            windowSustained = hotFraction >= 0.6
        }
        return CPUEvidence(
            isRunaway: behavior.isRunaway || (windowSustained && family.trend.observedSeconds >= 90),
            isSustained: behavior.isSustained || windowSustained,
            isBreached: isBreached,
            behavior: behavior
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
        recurrenceRisk: Double,
        staleLikelihood: Double,
        pattern: MemoryPatternAnalysis,
        cpuEvidence: CPUEvidence,
        inStartupGrace: Bool,
        slowLeak: Bool,
        settings: ThresholdSettings
    ) -> ForecastState {
        if family.score.level >= .critical {
            return .critical
        }
        if cpuEvidence.isRunaway {
            return .runaway
        }
        // Being above the memory limit is not a leak; growth is. Near the
        // limit a slower but real, sustained climb is enough.
        let nearLimit = horizon == .imminent || horizon == .breached
        let leakEntry = memoryVelocity >= settings.leakVelocityMegabytesPerMinute ||
            (nearLimit && family.trend.hasSustainedHistory &&
                memoryVelocity >= max(5, settings.leakVelocityMegabytesPerMinute * 0.1))
        if leakEntry {
            // Positive net velocity with a reclaiming shape (sawtooth) or a
            // single allocation step is not an accumulating leak. Startup
            // allocation bursts get the same benefit of the doubt.
            if pattern.indicatesAccumulation, !inStartupGrace {
                return .leaking
            }
            return .warming
        }
        if slowLeak, !inStartupGrace {
            return .leaking
        }
        if staleLikelihood >= 0.65, family.isIdleAcrossWindow {
            return .stale
        }
        if horizon == .soon || horizon == .breached || cpuEvidence.isBreached || cpuEvidence.isSustained ||
            memoryVelocity >= settings.leakVelocityMegabytesPerMinute * 0.35 || family.score.level >= .watch {
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
        staleLikelihood: Double,
        acceleration: Double,
        slowLeak: Bool
    ) -> Double {
        var value = 0.18 + family.devConfidence * 0.22
        if family.trend.memoryPoints.count >= 3 { value += 0.16 }
        if baseline.sampleCount >= 6 { value += 0.14 }
        if memoryVelocity > 0 { value += 0.14 }
        if horizon == .imminent || horizon == .breached { value += 0.14 }
        if acceleration > 0 { value += 0.06 }
        value += recurrenceRisk * 0.08
        value += staleLikelihood * 0.08
        // With enough samples, a clean linear trend earns confidence and a
        // noisy one costs it; below 4 samples R² is meaningless either way.
        if slowLeak {
            value += (family.longTermTrend.rSquared - 0.5) * 0.16
        } else if family.trend.sampleCount >= 4, memoryVelocity > 0 {
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

    private func memoryETASeconds(
        family: ProcessFamily,
        settings: ThresholdSettings,
        velocity: Double,
        acceleration: Double
    ) -> TimeInterval? {
        let current = Double(family.totalPhysicalFootprintBytes)
        let threshold = Double(settings.memoryBytes)
        let linear = etaSeconds(current: current, threshold: threshold, ratePerMinute: velocity * 1_048_576)
        guard acceleration > 0 else { return linear }
        let quadratic = etaSeconds(
            current: current,
            threshold: threshold,
            ratePerMinute: velocity * 1_048_576,
            accelerationPerMinute2: acceleration * 1_048_576
        )
        // A quadratic fit from two half-window slopes says nothing about the
        // far future; trust it only out to twice the window it was fitted on.
        if let quadratic, quadratic <= family.trend.observedSeconds * 2 {
            return quadratic
        }
        return linear
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

    // Compare time-aware regression slopes of the window halves. Refresh
    // cadence is adaptive, so sample-index slopes would make the exact same
    // process look more/less accelerated purely because sampling slowed down.
    // The change only counts when it is larger than the slopes' own noise.
    private func leakAcceleration(samples: [TrendSample]) -> Double {
        let midpoint = samples.count / 2
        let firstRange = 0..<midpoint
        let secondRange = midpoint..<samples.count
        guard firstRange.count >= 4, secondRange.count >= 4,
              let first = memorySlope(samples: samples, range: firstRange),
              let second = memorySlope(samples: samples, range: secondRange)
        else {
            return 0
        }
        let noise = (first.standardError * first.standardError + second.standardError * second.standardError).squareRoot()
        guard abs(second.slope - first.slope) > 2 * noise else {
            return 0
        }
        let centerDeltaMinutes = centerTime(samples: samples, range: secondRange)
            .timeIntervalSince(centerTime(samples: samples, range: firstRange)) / 60
        guard centerDeltaMinutes > 0 else {
            return 0
        }
        return max(0, (second.slope - first.slope) / centerDeltaMinutes)
    }

    private func memorySlope(samples: [TrendSample], range: Range<Int>) -> (slope: Double, standardError: Double)? {
        guard let firstIndex = range.first, range.count >= 3 else { return nil }
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
        let sxx = sumXX - (sumX * sumX / n)
        guard sxx > 0 else { return nil }
        let slope = (sumXY - (sumX * sumY / n)) / sxx
        let intercept = (sumY - slope * sumX) / n
        var residualSquares = 0.0
        for index in range {
            let x = samples[index].date.timeIntervalSince(origin) / 60
            let residual = Double(samples[index].memoryBytes) / 1_048_576 - (intercept + slope * x)
            residualSquares += residual * residual
        }
        let standardError = (residualSquares / (n - 2) / sxx).squareRoot()
        return (slope, standardError)
    }

    private func centerTime(samples: [TrendSample], range: Range<Int>) -> Date {
        let first = samples[range.lowerBound].date.timeIntervalSince1970
        let last = samples[range.upperBound - 1].date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (first + last) / 2)
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
        return "\(RadarFormat.fixed1(eta / 3600)) hr"
    }

    private func whyNow(
        family: ProcessFamily,
        state: ForecastState,
        horizon: ForecastHorizon,
        etaText: String,
        etaKind: ForecastETAKind,
        baseline: AnomalyBaseline,
        memoryVelocity: Double,
        acceleration: Double,
        staleLikelihood: Double,
        pattern: MemoryPatternAnalysis,
        cpuEvidence: CPUEvidence,
        inStartupGrace: Bool,
        slowLeak: Bool,
        settings: ThresholdSettings
    ) -> String {
        var parts: [String] = []
        let behavior = cpuEvidence.behavior
        if behavior.kind != .none, !behavior.reason.isEmpty,
           behavior.kind != .expectedBurst || cpuEvidence.isBreached || behavior.minutes > 0 {
            parts.append(cpuEvidence.behavior.reason)
        } else if cpuEvidence.isSustained {
            parts.append(cpuEvidence.behavior.isSustained ? cpuEvidence.behavior.reason : "CPU held above threshold for most of the window")
        } else if cpuEvidence.isBreached {
            let limit = CPUBehaviorAnalyzer.familyCPULimit(settings: settings, processorCount: processorCount)
            parts.append("CPU above its \(Int(limit.rounded()))% limit now")
        }
        if horizon == .breached, etaKind == .memoryLimit {
            parts.append("above its memory limit")
        }
        if slowLeak {
            let minutes = Int(family.longTermTrend.spanMinutes)
            parts.append("memory has crept up \(Int(memoryVelocity.rounded())) MB/min for \(minutes) min")
            if let culprit = family.culprit, family.members.count > 1 {
                parts.append("mostly \(culprit.name) (\(Int((culprit.share * 100).rounded()))% of the growth)")
            }
        } else if memoryVelocity > 0 {
            parts.append("memory is rising \(Int(memoryVelocity.rounded())) MB/min")
        }
        if inStartupGrace, memoryVelocity > 0 {
            parts.append("inside startup grace window")
        }
        if pattern.pattern == .sawtooth {
            parts.append("churns in reclaim cycles (likely GC), not accumulating")
        }
        if pattern.pattern == .risingFloor {
            parts.append("reclaims in cycles but its floor keeps rising")
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
        if etaKind == .hostMemory, horizon == .soon || horizon == .imminent {
            parts.append("at this rate memory pressure turns critical in ~\(etaText)")
        } else if horizon == .soon || horizon == .imminent {
            parts.append("memory limit in \(etaText)")
        }
        if baseline.memoryMultiple >= 1.5 {
            parts.append("\(RadarFormat.fixed1(baseline.memoryMultiple))x normal memory")
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
        etaKind: ForecastETAKind,
        confidence: Double,
        cpu: CPUBehavior
    ) -> TriageRecommendation {
        if cpu.kind == .expectedBurst, !cpu.isRunaway, state != .critical, state != .leaking {
            return TriageRecommendation(
                title: "Let it finish",
                detail: "Build and test work uses a lot of CPU for a while and ends by itself.",
                action: .highlight,
                confidence: confidence
            )
        }
        switch state {
        case .critical, .runaway:
            return TriageRecommendation(
                title: family.isKillable ? "Preview Stop Tree" : "Inspect owner",
                detail: family.isKillable ? "This family is already beyond safe forecast bounds." : "Protected or foreign processes are present.",
                action: family.isKillable ? .suggestKill : .inspect,
                confidence: confidence
            )
        case .leaking:
            return TriageRecommendation(
                title: "Inspect leak",
                detail: horizon != .imminent ? "Memory trend is rising faster than normal."
                    : etaKind == .hostMemory ? "Likely to push memory pressure to critical soon." : "Likely to cross its memory limit soon.",
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
