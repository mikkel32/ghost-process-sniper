import Foundation

public struct TrendSample: Identifiable, Equatable, Sendable {
    public let date: Date
    public let memoryBytes: UInt64
    public let cpuPercent: Double

    public var id: Date { date }

    public init(date: Date, memoryBytes: UInt64, cpuPercent: Double) {
        self.date = date
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
    }
}

public struct TrendMetrics: Equatable, Sendable {
    public let memoryVelocityMegabytesPerMinute: Double
    public let cpuSlopePerMinute: Double
    public let memoryPoints: [Double]
    /// R² of the memory regression. Hand-built metrics default to 1 (trusted);
    /// TrendWindow supplies the measured value.
    public let memoryFitQuality: Double
    public let sampleCount: Int
    /// The dated samples behind memoryPoints, for time-axis charts.
    public let samples: [TrendSample]
    /// The memory shape, computed once per window update. Nil for hand-built
    /// metrics; read resolvedPattern instead.
    public let pattern: MemoryPatternAnalysis?

    public var resolvedPattern: MemoryPatternAnalysis {
        if let pattern { return pattern }
        if samples.count == memoryPoints.count, samples.count >= 4 {
            return MemoryPatternAnalysis.analyze(samples: samples, fitQuality: memoryFitQuality)
        }
        return MemoryPatternAnalysis.analyze(points: memoryPoints, fitQuality: memoryFitQuality)
    }

    /// Growth that is proven by history: enough samples over enough time, a
    /// trend that explains the data, and a shape that accumulates. Two close
    /// samples can make any jump look like thousands of MB/min; this cannot.
    /// A leak under GC counts at its floor's slope. The raw velocity stays
    /// available for charts.
    public var credibleMemoryVelocity: Double {
        guard hasSustainedHistory else { return 0 }
        let shape = resolvedPattern
        guard shape.indicatesAccumulation else { return 0 }
        if shape.pattern == .risingFloor, !samples.isEmpty {
            return max(0, shape.floorSlopeMegabytesPerMinute)
        }
        guard memoryFitQuality >= 0.5 else { return 0 }
        return max(0, memoryVelocityMegabytesPerMinute)
    }

    public var observedSeconds: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.date.timeIntervalSince(first.date))
    }

    public var hasSustainedHistory: Bool {
        sampleCount >= 4 && (samples.isEmpty || observedSeconds >= 15)
    }

    public init(
        memoryVelocityMegabytesPerMinute: Double,
        cpuSlopePerMinute: Double,
        memoryPoints: [Double],
        memoryFitQuality: Double = 1,
        sampleCount: Int? = nil,
        samples: [TrendSample] = [],
        pattern: MemoryPatternAnalysis? = nil
    ) {
        self.memoryVelocityMegabytesPerMinute = memoryVelocityMegabytesPerMinute
        self.cpuSlopePerMinute = cpuSlopePerMinute
        self.memoryPoints = memoryPoints
        self.memoryFitQuality = min(1, max(0, memoryFitQuality))
        self.sampleCount = sampleCount ?? memoryPoints.count
        self.samples = samples
        self.pattern = pattern
    }

    public static let empty = TrendMetrics(
        memoryVelocityMegabytesPerMinute: 0,
        cpuSlopePerMinute: 0,
        memoryPoints: [],
        memoryFitQuality: 0,
        sampleCount: 0,
        pattern: .unknown
    )
}

public struct FamilyBaseline: Codable, Equatable, Sendable {
    /// Version 2: a time-constant EWMA with variance and observed time.
    /// Older rows learned per refresh and are relearned.
    public static let currentMeasurementVersion = 2

    public let signature: ProcessSignature
    public var sampleCount: Int
    public var meanMemoryBytes: Double
    public var peakMemoryBytes: UInt64
    public var meanCPUPercent: Double
    public var peakCPUPercent: Double
    public var meanLeakVelocityMegabytesPerMinute: Double
    public var incidentCount: Int
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    // Absent in older saved baselines that may have learned missing readings as zero.
    public var measurementVersion: Int?
    /// Exponentially weighted variances, in bytes² and percent².
    public var memoryVariance: Double
    public var cpuVariance: Double
    /// Learning time: the sum of the gaps between learned readings.
    public var observedSeconds: TimeInterval
    /// Separate runs of the family (a new one starts after a 30-minute gap).
    public var sessionCount: Int

    /// A normal range means at least twenty minutes of learned readings, not
    /// a few refreshes.
    public var isMeasurementTrusted: Bool {
        measurementVersion == Self.currentMeasurementVersion && sampleCount >= 30 && observedSeconds >= 1_200 &&
            meanMemoryBytes.isFinite && meanMemoryBytes >= 1_048_576
    }

    public var memoryStandardDeviation: Double { max(0, memoryVariance).squareRoot() }
    public var cpuStandardDeviation: Double { max(0, cpuVariance).squareRoot() }

    /// The top of the usual range, for display.
    public var memoryP95Bytes: Double { meanMemoryBytes + 1.65 * memoryStandardDeviation }

    public init(
        signature: ProcessSignature,
        sampleCount: Int,
        meanMemoryBytes: Double,
        peakMemoryBytes: UInt64,
        meanCPUPercent: Double,
        peakCPUPercent: Double,
        meanLeakVelocityMegabytesPerMinute: Double,
        incidentCount: Int,
        firstSeenAt: Date,
        lastSeenAt: Date,
        measurementVersion: Int? = FamilyBaseline.currentMeasurementVersion,
        memoryVariance: Double = 0,
        cpuVariance: Double = 0,
        observedSeconds: TimeInterval = 3_600,
        sessionCount: Int = 1
    ) {
        self.signature = signature
        self.sampleCount = sampleCount
        self.meanMemoryBytes = meanMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.meanCPUPercent = meanCPUPercent
        self.peakCPUPercent = peakCPUPercent
        self.meanLeakVelocityMegabytesPerMinute = meanLeakVelocityMegabytesPerMinute
        self.incidentCount = incidentCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.measurementVersion = measurementVersion
        self.memoryVariance = memoryVariance
        self.cpuVariance = cpuVariance
        self.observedSeconds = observedSeconds
        self.sessionCount = sessionCount
    }

    public func memoryMultiple(for bytes: UInt64) -> Double {
        guard isMeasurementTrusted else { return 1 }
        return Double(bytes) / meanMemoryBytes
    }

    /// How unusual this footprint is for the family, in learned standard
    /// deviations. The floor keeps a family that never varied from turning
    /// a few megabytes into a huge score.
    public func memoryZScore(for bytes: UInt64) -> Double {
        guard isMeasurementTrusted else { return 0 }
        let scale = max(memoryStandardDeviation, meanMemoryBytes * 0.05, 32 * 1_048_576)
        return (Double(bytes) - meanMemoryBytes) / scale
    }

    /// A normally idle family's ratio is as meaningful as a busy one's; the
    /// 2-point floor keeps idle noise from dividing by nearly zero.
    public func cpuMultiple(for percent: Double) -> Double {
        guard isMeasurementTrusted else { return 1 }
        return percent / max(meanCPUPercent, 2)
    }

    public func cpuZScore(for percent: Double) -> Double {
        guard isMeasurementTrusted else { return 0 }
        return (percent - meanCPUPercent) / max(cpuStandardDeviation, 5)
    }

    /// CPU points above the top of the usual range (mean + 2 sd).
    public func cpuExcess(for percent: Double) -> Double {
        guard isMeasurementTrusted else { return 0 }
        return percent - (meanCPUPercent + 2 * cpuStandardDeviation)
    }
}

/// Learns a family's normal operating range without letting an active incident
/// redefine "normal". Hot/leaking samples remain visible in incident history,
/// but they do not pull the baseline averages or peaks upward.
public struct FamilyBaselineLearner: Sendable {
    /// Two hours: "normal" is the afternoon, not the last minute.
    static let timeConstant: TimeInterval = 7_200
    static let maximumStep: TimeInterval = 300
    static let sessionGap: TimeInterval = 1_800

    public init() {}

    public func updated(
        existing: FamilyBaseline?,
        family: ProcessFamily,
        now: Date,
        leakVelocityLimit: Double = ThresholdSettings.smart.leakVelocityMegabytesPerMinute
    ) -> FamilyBaseline {
        let existing = existing?.measurementVersion == FamilyBaseline.currentMeasurementVersion ? existing : nil
        let trustedForecastIncident = family.forecast.state >= .leaking &&
            family.forecast.confidence >= 0.55 &&
            family.trend.sampleCount >= 4
        let isIncidentSample = family.score.heat.shouldRecordIncident || trustedForecastIncident || !family.hasRecentMeasurements(at: now)
        let currentLeak = family.trend.credibleMemoryVelocity
        let memory = Double(family.totalPhysicalFootprintBytes)
        let cpu = family.totalCPUPercent

        guard var baseline = existing else {
            return FamilyBaseline(
                signature: family.signature,
                sampleCount: isIncidentSample ? 0 : 1,
                meanMemoryBytes: isIncidentSample ? 0 : memory,
                peakMemoryBytes: isIncidentSample ? 0 : family.totalPhysicalFootprintBytes,
                meanCPUPercent: isIncidentSample ? 0 : cpu,
                peakCPUPercent: isIncidentSample ? 0 : cpu,
                meanLeakVelocityMegabytesPerMinute: isIncidentSample ? 0 : currentLeak,
                // `recentIncidentCount` comes from distinct persisted incident
                // rows. Never derive recurrence from refresh/sample frequency.
                incidentCount: family.recentIncidentCount,
                firstSeenAt: now,
                lastSeenAt: now,
                observedSeconds: 0
            )
        }

        // Incident bookkeeping is independent of measurement freshness.
        baseline.incidentCount = family.recentIncidentCount
        guard let measuredAt = family.measurementDate, measuredAt > baseline.lastSeenAt else { return baseline }
        let gap = measuredAt.timeIntervalSince(baseline.lastSeenAt)
        baseline.lastSeenAt = measuredAt
        if gap > Self.sessionGap {
            baseline.sessionCount += 1
        }
        if isIncidentSample {
            return baseline
        }

        // Weight by elapsed time, not by refresh count, so a 0.75 s and a 5 s
        // cadence learn the same normal. A long gap counts as one step.
        let step = min(max(0, gap), Self.maximumStep)
        baseline.observedSeconds += step
        guard baseline.sampleCount > 0 else {
            baseline.sampleCount = 1
            baseline.meanMemoryBytes = memory
            baseline.peakMemoryBytes = family.totalPhysicalFootprintBytes
            baseline.meanCPUPercent = cpu
            baseline.peakCPUPercent = cpu
            baseline.meanLeakVelocityMegabytesPerMinute = currentLeak
            return baseline
        }
        let alpha = 1 - exp(-step / Self.timeConstant)
        baseline.sampleCount += 1
        // Credible sustained growth is never allowed to become "normal".
        let trend = family.trend
        let isGrowing = trend.hasSustainedHistory && trend.memoryFitQuality >= 0.6 &&
            trend.memoryVelocityMegabytesPerMinute >= leakVelocityLimit * 0.35
        if !isGrowing {
            Self.learn(memory, alpha: alpha, mean: &baseline.meanMemoryBytes, variance: &baseline.memoryVariance)
            baseline.peakMemoryBytes = max(baseline.peakMemoryBytes, family.totalPhysicalFootprintBytes)
        }
        Self.learn(cpu, alpha: alpha, mean: &baseline.meanCPUPercent, variance: &baseline.cpuVariance)
        baseline.peakCPUPercent = max(baseline.peakCPUPercent, cpu)
        baseline.meanLeakVelocityMegabytesPerMinute += alpha * (currentLeak - baseline.meanLeakVelocityMegabytesPerMinute)
        return baseline
    }

    // West's incremental exponentially weighted mean and variance.
    private static func learn(_ value: Double, alpha: Double, mean: inout Double, variance: inout Double) {
        let difference = value - mean
        let increment = alpha * difference
        mean += increment
        variance = (1 - alpha) * (variance + difference * increment)
    }
}

public struct TrendWindow: Sendable {
    private var signatureSamples: [String: [TrendSample]] = [:]
    private var latestMetrics: [String: TrendMetrics] = [:]
    private let retention: TimeInterval
    private let maxSamples: Int
    private var lastCleanupDate: Date?
    private var updatesSinceCleanup = 0

    public init(retention: TimeInterval = 180, maxSamples: Int = 90) {
        self.retention = retention
        self.maxSamples = maxSamples
    }

    public mutating func update(
        signatureID: String,
        memoryBytes: UInt64,
        cpuPercent: Double,
        at date: Date
    ) -> TrendMetrics {
        var values = signatureSamples[signatureID, default: []]
        // Reusing a cached reading is not another independent sample.
        if let last = values.last, date <= last.date {
            return latestMetrics[signatureID] ?? metrics(for: values)
        }
        values.append(TrendSample(date: date, memoryBytes: memoryBytes, cpuPercent: cpuPercent))
        prune(&values, keeping: date)
        signatureSamples[signatureID] = values
        let result = metrics(for: values)
        latestMetrics[signatureID] = result
        cleanupIfNeeded(keeping: date)
        return result
    }

    private func prune(_ values: inout [TrendSample], keeping date: Date) {
        values.removeAll { date.timeIntervalSince($0.date) > retention }
        if values.count > maxSamples {
            values.removeFirst(values.count - maxSamples)
        }
    }

    private mutating func cleanupIfNeeded(keeping date: Date) {
        updatesSinceCleanup += 1
        let cleanupInterval = max(10, min(30, retention / 4))
        let timeAdvancedEnough = lastCleanupDate.map {
            date.timeIntervalSince($0) >= cleanupInterval
        } ?? true
        let enoughUpdatesAccumulated = updatesSinceCleanup >= 4_096
        guard timeAdvancedEnough || enoughUpdatesAccumulated else {
            return
        }
        cleanup(keeping: date)
        lastCleanupDate = date
        updatesSinceCleanup = 0
    }

    private mutating func cleanup(keeping date: Date) {
        signatureSamples = signatureSamples.filter { _, values in
            values.contains { date.timeIntervalSince($0.date) <= retention }
        }
        latestMetrics = latestMetrics.filter { signatureSamples[$0.key] != nil }
    }

    // A least-squares fit over the whole window instead of the two endpoints:
    // a single spiky sample at either edge no longer swings the velocity, and
    // R² tells the forecaster how much to trust the slope.
    private func metrics(for values: [TrendSample]) -> TrendMetrics {
        let points = values.map { Double($0.memoryBytes) }
        guard let first = values.first, values.count >= 2 else {
            return TrendMetrics(
                memoryVelocityMegabytesPerMinute: 0,
                cpuSlopePerMinute: 0,
                memoryPoints: points,
                memoryFitQuality: 0,
                sampleCount: values.count,
                samples: values,
                pattern: .unknown
            )
        }

        let n = Double(values.count)
        var sumX = 0.0
        var sumMemory = 0.0
        var sumCPU = 0.0
        var sumXX = 0.0
        var sumXMemory = 0.0
        var sumXCPU = 0.0
        var sumMemorySquared = 0.0

        for sample in values {
            let x = sample.date.timeIntervalSince(first.date) / 60
            let memory = Double(sample.memoryBytes) / 1_048_576
            let cpu = sample.cpuPercent
            sumX += x
            sumMemory += memory
            sumCPU += cpu
            sumXX += x * x
            sumXMemory += x * memory
            sumXCPU += x * cpu
            sumMemorySquared += memory * memory
        }

        let centeredXX = sumXX - (sumX * sumX / n)
        let centeredXMemory = sumXMemory - (sumX * sumMemory / n)
        let centeredXCPU = sumXCPU - (sumX * sumCPU / n)
        let centeredMemorySquared = sumMemorySquared - (sumMemory * sumMemory / n)
        let memorySlope = centeredXX > 0 ? centeredXMemory / centeredXX : 0
        let cpuSlope = centeredXX > 0 ? centeredXCPU / centeredXX : 0
        let memoryFitQuality: Double
        if centeredXX <= 0 {
            memoryFitQuality = 0
        } else if centeredMemorySquared <= 0 {
            memoryFitQuality = 1
        } else {
            memoryFitQuality = min(
                1,
                max(0, (centeredXMemory * centeredXMemory) / (centeredXX * centeredMemorySquared))
            )
        }

        let pattern = MemoryPatternAnalysis.analyze(samples: values, fitQuality: memoryFitQuality)
        // With enough points, the Theil-Sen slope shrugs off a jittery or
        // spiky sample that would drag the least-squares slope; R² stays the
        // least-squares measure of how linear the window is.
        let velocity = values.count >= 8 ? pattern.robustSlopeMegabytesPerMinute : memorySlope
        return TrendMetrics(
            memoryVelocityMegabytesPerMinute: velocity,
            cpuSlopePerMinute: cpuSlope,
            memoryPoints: points,
            memoryFitQuality: memoryFitQuality,
            sampleCount: values.count,
            samples: values,
            pattern: pattern
        )
    }
}
