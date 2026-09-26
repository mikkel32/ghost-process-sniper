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
        samples: [TrendSample] = []
    ) {
        self.memoryVelocityMegabytesPerMinute = memoryVelocityMegabytesPerMinute
        self.cpuSlopePerMinute = cpuSlopePerMinute
        self.memoryPoints = memoryPoints
        self.memoryFitQuality = min(1, max(0, memoryFitQuality))
        self.sampleCount = sampleCount ?? memoryPoints.count
        self.samples = samples
    }

    public static let empty = TrendMetrics(
        memoryVelocityMegabytesPerMinute: 0,
        cpuSlopePerMinute: 0,
        memoryPoints: [],
        memoryFitQuality: 0,
        sampleCount: 0
    )
}

public struct FamilyBaseline: Codable, Equatable, Sendable {
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

    public var isMeasurementTrusted: Bool {
        measurementVersion == 1 && sampleCount >= 4 && meanMemoryBytes.isFinite && meanMemoryBytes >= 1_048_576
    }

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
        measurementVersion: Int? = 1
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
    }

    public func memoryMultiple(for bytes: UInt64) -> Double {
        guard isMeasurementTrusted else { return 1 }
        return Double(bytes) / meanMemoryBytes
    }

    public func cpuMultiple(for percent: Double) -> Double {
        guard isMeasurementTrusted else { return 1 }
        guard meanCPUPercent > 1 else { return percent > 25 ? 2 : 1 }
        return percent / meanCPUPercent
    }
}

/// Learns a family's normal operating range without letting an active incident
/// redefine "normal". Hot/leaking samples remain visible in incident history,
/// but they do not pull the baseline averages or peaks upward.
public struct FamilyBaselineLearner: Sendable {
    public init() {}

    public func updated(
        existing: FamilyBaseline?,
        family: ProcessFamily,
        now: Date
    ) -> FamilyBaseline {
        let existing = existing?.measurementVersion == 1 ? existing : nil
        let trustedForecastIncident = family.forecast.state >= .leaking &&
            family.forecast.confidence >= 0.55 &&
            family.trend.sampleCount >= 4
        let isIncidentSample = family.score.heat.shouldRecordIncident || trustedForecastIncident || !family.hasRecentMeasurements(at: now)
        let currentLeak = max(0, family.trend.memoryVelocityMegabytesPerMinute)

        guard var baseline = existing else {
            return FamilyBaseline(
                signature: family.signature,
                sampleCount: isIncidentSample ? 0 : 1,
                meanMemoryBytes: isIncidentSample ? 0 : Double(family.totalPhysicalFootprintBytes),
                peakMemoryBytes: isIncidentSample ? 0 : family.totalPhysicalFootprintBytes,
                meanCPUPercent: isIncidentSample ? 0 : family.totalCPUPercent,
                peakCPUPercent: isIncidentSample ? 0 : family.totalCPUPercent,
                meanLeakVelocityMegabytesPerMinute: isIncidentSample ? 0 : currentLeak,
                // `recentIncidentCount` comes from distinct persisted incident
                // rows. Never derive recurrence from refresh/sample frequency.
                incidentCount: family.recentIncidentCount,
                firstSeenAt: now,
                lastSeenAt: now
            )
        }

        // Incident bookkeeping is independent of measurement freshness.
        baseline.incidentCount = family.recentIncidentCount
        guard let measuredAt = family.measurementDate, measuredAt > baseline.lastSeenAt else { return baseline }
        baseline.lastSeenAt = measuredAt
        if isIncidentSample {
            return baseline
        }

        let alpha = baseline.sampleCount < 12
            ? 1 / Double(baseline.sampleCount + 1)
            : 0.08
        baseline.sampleCount += 1
        baseline.meanMemoryBytes = baseline.meanMemoryBytes * (1 - alpha) + Double(family.totalPhysicalFootprintBytes) * alpha
        baseline.peakMemoryBytes = max(baseline.peakMemoryBytes, family.totalPhysicalFootprintBytes)
        baseline.meanCPUPercent = baseline.meanCPUPercent * (1 - alpha) + family.totalCPUPercent * alpha
        baseline.peakCPUPercent = max(baseline.peakCPUPercent, family.totalCPUPercent)
        baseline.meanLeakVelocityMegabytesPerMinute = baseline.meanLeakVelocityMegabytesPerMinute * (1 - alpha) + currentLeak * alpha
        return baseline
    }
}

public struct TrendWindow: Sendable {
    private var signatureSamples: [String: [TrendSample]] = [:]
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
        if let last = values.last, date <= last.date { return metrics(for: values) }
        values.append(TrendSample(date: date, memoryBytes: memoryBytes, cpuPercent: cpuPercent))
        prune(&values, keeping: date)
        signatureSamples[signatureID] = values
        cleanupIfNeeded(keeping: date)
        return metrics(for: values)
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
                samples: values
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

        return TrendMetrics(
            memoryVelocityMegabytesPerMinute: memorySlope,
            cpuSlopePerMinute: cpuSlope,
            memoryPoints: points,
            memoryFitQuality: memoryFitQuality,
            sampleCount: values.count,
            samples: values
        )
    }
}
