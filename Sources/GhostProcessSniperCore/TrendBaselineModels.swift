import Foundation

public struct TrendSample: Equatable, Sendable {
    public let date: Date
    public let memoryBytes: UInt64
    public let cpuPercent: Double

    public init(date: Date, memoryBytes: UInt64, cpuPercent: Double) {
        self.date = date
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
    }
}

public enum TrendMath {
    /// Ordinary least-squares fit. Returns slope in y-units per x-unit and R²
    /// (1 = clean linear trend, 0 = uncorrelated noise). A perfectly flat
    /// series counts as a perfect fit with zero slope.
    public static func linearFit(x: [Double], y: [Double]) -> (slope: Double, rSquared: Double) {
        guard x.count >= 2, x.count == y.count else {
            return (0, 0)
        }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var sxx = 0.0
        var sxy = 0.0
        var syy = 0.0
        for index in x.indices {
            let dx = x[index] - meanX
            let dy = y[index] - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else {
            return (0, 0)
        }
        let slope = sxy / sxx
        guard syy > 0 else {
            return (slope, 1)
        }
        let rSquared = (sxy * sxy) / (sxx * syy)
        return (slope, min(1, max(0, rSquared)))
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
        lastSeenAt: Date
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
    }

    public func memoryMultiple(for bytes: UInt64) -> Double {
        guard meanMemoryBytes > 1 else { return 1 }
        return Double(bytes) / meanMemoryBytes
    }

    public func cpuMultiple(for percent: Double) -> Double {
        guard meanCPUPercent > 1 else { return percent > 25 ? 2 : 1 }
        return percent / meanCPUPercent
    }
}

public struct TrendWindow: Sendable {
    private var samples: [ProcessIdentity: [TrendSample]] = [:]
    private var signatureSamples: [String: [TrendSample]] = [:]
    private let retention: TimeInterval
    private let maxSamples: Int

    public init(retention: TimeInterval = 180, maxSamples: Int = 90) {
        self.retention = retention
        self.maxSamples = maxSamples
    }

    public mutating func update(
        identity: ProcessIdentity,
        memoryBytes: UInt64,
        cpuPercent: Double,
        at date: Date
    ) -> TrendMetrics {
        var values = samples[identity, default: []]
        values.append(TrendSample(date: date, memoryBytes: memoryBytes, cpuPercent: cpuPercent))
        values = values
            .filter { date.timeIntervalSince($0.date) <= retention }
            .suffix(maxSamples)
            .map { $0 }
        samples[identity] = values
        cleanup(keeping: date)
        return metrics(for: values)
    }

    public mutating func update(
        signatureID: String,
        memoryBytes: UInt64,
        cpuPercent: Double,
        at date: Date
    ) -> TrendMetrics {
        var values = signatureSamples[signatureID, default: []]
        values.append(TrendSample(date: date, memoryBytes: memoryBytes, cpuPercent: cpuPercent))
        values = values
            .filter { date.timeIntervalSince($0.date) <= retention }
            .suffix(maxSamples)
            .map { $0 }
        signatureSamples[signatureID] = values
        cleanup(keeping: date)
        return metrics(for: values)
    }

    private mutating func cleanup(keeping date: Date) {
        samples = samples.filter { _, values in
            values.contains { date.timeIntervalSince($0.date) <= retention }
        }
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

        let minutes = values.map { $0.date.timeIntervalSince(first.date) / 60 }
        let memoryMegabytes = values.map { Double($0.memoryBytes) / 1_048_576 }
        let cpu = values.map(\.cpuPercent)
        let memoryFit = TrendMath.linearFit(x: minutes, y: memoryMegabytes)
        let cpuFit = TrendMath.linearFit(x: minutes, y: cpu)

        return TrendMetrics(
            memoryVelocityMegabytesPerMinute: memoryFit.slope,
            cpuSlopePerMinute: cpuFit.slope,
            memoryPoints: points,
            memoryFitQuality: memoryFit.rSquared,
            sampleCount: values.count,
            samples: values
        )
    }
}
