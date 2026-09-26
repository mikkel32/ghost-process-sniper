import Foundation

/// Presentation-only policy. Disabling motion never disables monitoring.
public enum RadarMotionPolicy {
    public static func runsContinuousMotion(
        reduceMotion: Bool, lowPower: Bool, inViewport: Bool,
        windowVisible: Bool, applicationActive: Bool
    ) -> Bool {
        !reduceMotion && !lowPower && inViewport && windowVisible && applicationActive
    }
}

public enum RadarScopeGeometry {
    public static func angle(for key: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Double(hash % 3600) / 3600 * 2 * .pi
    }

    public static func position(key: String, urgency: Double, width: Double, height: Double) -> CGPoint {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let radius = max(0, min(width, height) / 2 - 16)
        let fraction = urgency.isFinite ? min(1, max(0, urgency / 100)) : 0
        let distance = radius * (0.16 + (1 - fraction) * 0.74)
        let bearing = angle(for: key)
        return CGPoint(x: width / 2 + cos(bearing) * distance, y: height / 2 + sin(bearing) * distance)
    }
}

public enum ThermalComponent: Sendable { case cpu, gpu }

public struct ThermalTracePoint: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let celsius: Double
}

public struct ThermalTraceSegment: Identifiable, Equatable, Sendable {
    public var id: Date { points[0].date }
    public let points: [ThermalTracePoint]
}

/// Bounded, real sensor history. Missing readings and long gaps break the line;
/// the presentation never synthesizes samples or bridges a sensor outage.
public struct ThermalTraceHistory: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let date: Date
        let cpu: Double?
        let gpu: Double?
    }
    private var samples: [Sample] = []
    public let capacity: Int
    public let retention: TimeInterval
    public var count: Int { samples.count }

    public init(capacity: Int = 60, retention: TimeInterval = 180) {
        self.capacity = max(2, capacity)
        self.retention = retention.isFinite ? max(15, retention) : 180
    }

    @discardableResult
    public mutating func append(_ snapshot: ThermalSnapshot, at now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.sampledAt)
        guard age.isFinite, (0...15).contains(age),
              samples.last.map({ snapshot.sampledAt > $0.date }) ?? true else { return false }
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, (5...125).contains(value) else { return nil }
            return value
        }
        samples.append(Sample(date: snapshot.sampledAt, cpu: valid(snapshot.cpuCelsius), gpu: valid(snapshot.gpuCelsius)))
        samples.removeAll { now.timeIntervalSince($0.date) > retention }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return true
    }

    public func segments(for component: ThermalComponent, at now: Date) -> [ThermalTraceSegment] {
        var result: [ThermalTraceSegment] = []
        var current: [ThermalTracePoint] = []
        func flush() {
            if !current.isEmpty { result.append(ThermalTraceSegment(points: current)); current = [] }
        }
        for sample in samples where (0...retention).contains(now.timeIntervalSince(sample.date)) {
            let value = component == .cpu ? sample.cpu : sample.gpu
            guard let value else { flush(); continue }
            if let previous = current.last, sample.date.timeIntervalSince(previous.date) > 15 { flush() }
            current.append(ThermalTracePoint(date: sample.date, celsius: value))
        }
        flush()
        return result
    }
}
