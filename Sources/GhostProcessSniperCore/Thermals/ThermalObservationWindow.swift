import Foundation

public struct ThermalTrajectory: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case measuring, rising, steady, falling }
    public let direction: Direction
    public let changeCelsius: Double?
    public let spanSeconds: TimeInterval
    public let warmSeconds: TimeInterval
    public let hotSeconds: TimeInterval
    /// Zero until at least two consecutive readings reach 90°C, whatever the cadence.
    public let veryHotSeconds: TimeInterval

    public static let empty = Self(direction: .measuring, changeCelsius: nil,
                                   spanSeconds: 0, warmSeconds: 0, hotSeconds: 0, veryHotSeconds: 0)

    public var label: String {
        switch direction {
        case .measuring: "Learning the temperature trend"
        case .rising: "Temperature rising"
        case .steady: "Temperature holding steady"
        case .falling: "Temperature falling"
        }
    }

    public var detail: String {
        guard let changeCelsius else { return "Needs 4 distinct readings across 30s" }
        let change = abs(changeCelsius).formatted(.number.precision(.fractionLength(1)))
        let sign = changeCelsius > 0 ? "+" : changeCelsius < 0 ? "−" : ""
        return "\(sign)\(change)°C between early and recent medians over \(Int(spanSeconds))s"
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

/// Bounded, sample-driven evidence. UI timer ticks do not add observations.
/// The monitor records every new sensor reading, so the trend and the trace are
/// ready the moment a thermal view opens. Missing readings and gaps longer than
/// 15 s break both; nothing is synthesized to bridge a sensor outage.
public struct ThermalObservationWindow: Equatable, Sendable {
    static let retention: TimeInterval = 180
    static let maximumGap: TimeInterval = 15
    static let capacity = 90

    struct Reading: Equatable, Sendable {
        let date: Date
        let cpu: Double?
        let gpu: Double?
        let cpuSeries: String?
        let gpuSeries: String?
    }

    private(set) var readings: [Reading] = []
    public init() {}

    public var count: Int { readings.count }

    public mutating func record(_ snapshot: ThermalSnapshot, at now: Date) {
        let age = now.timeIntervalSince(snapshot.sampledAt)
        guard age.isFinite, (0...15).contains(age) else { return }
        let next = Reading(date: snapshot.sampledAt,
                           cpu: ThermalTemperatureAssessment.valid(snapshot.cpuCelsius),
                           gpu: ThermalTemperatureAssessment.valid(snapshot.gpuCelsius),
                           cpuSeries: snapshot.cpuSeries, gpuSeries: snapshot.gpuSeries)
        if let last = readings.last {
            guard next.date >= last.date else { return }
            if next.date == last.date {
                if next != last { readings[readings.count - 1] = next }
                return
            }
        }
        readings.append(next)
        readings.removeAll { next.date.timeIntervalSince($0.date) > Self.retention }
        if readings.count > Self.capacity { readings.removeFirst(readings.count - Self.capacity) }
    }

    /// Real readings for a chart; a missing value or a long gap starts a new segment.
    public func segments(for component: ThermalComponent, at now: Date) -> [ThermalTraceSegment] {
        var result: [ThermalTraceSegment] = []
        var current: [ThermalTracePoint] = []
        func flush() {
            if !current.isEmpty { result.append(ThermalTraceSegment(points: current)); current = [] }
        }
        for reading in readings where (0...Self.retention).contains(now.timeIntervalSince(reading.date)) {
            guard let value = component == .cpu ? reading.cpu : reading.gpu else { flush(); continue }
            if let previous = current.last, reading.date.timeIntervalSince(previous.date) > Self.maximumGap { flush() }
            current.append(ThermalTracePoint(date: reading.date, celsius: value))
        }
        flush()
        return result
    }

    func trajectory(snapshot: ThermalSnapshot, cpu: Bool, at now: Date) -> ThermalTrajectory {
        // Include the current sample before the view's onChange callback runs.
        var current = self
        current.record(snapshot, at: now)
        guard current.readings.last?.date == snapshot.sampledAt else { return .empty }
        var series: [(date: Date, value: Double)] = []
        let currentSeries = cpu ? snapshot.cpuSeries : snapshot.gpuSeries
        for reading in current.readings.reversed() {
            guard (cpu ? reading.cpuSeries : reading.gpuSeries) == currentSeries, let value = cpu ? reading.cpu : reading.gpu,
                  series.last.map({ $0.date.timeIntervalSince(reading.date) <= Self.maximumGap }) ?? true else { break }
            series.append((reading.date, value))
        }
        guard let latest = series.first else { return .empty }

        func duration(above threshold: Double) -> TimeInterval {
            let warm = series.prefix { $0.value >= threshold }
            guard warm.count >= 2, let first = warm.last else { return 0 }
            return max(0, latest.date.timeIntervalSince(first.date))
        }
        let recent = Array(series.prefix { latest.date.timeIntervalSince($0.date) <= 60 }.reversed())
        let span = recent.first.map { latest.date.timeIntervalSince($0.date) } ?? 0
        let warm = duration(above: 70)
        let hot = duration(above: 80)
        let veryHot = duration(above: 90)
        guard recent.count >= 4, span >= 30 else {
            return ThermalTrajectory(direction: .measuring, changeCelsius: nil, spanSeconds: span,
                                     warmSeconds: warm, hotSeconds: hot, veryHotSeconds: veryHot)
        }
        let edgeCount = min(3, recent.count / 2)
        let first = Self.median(recent.prefix(edgeCount).map(\.value))
        let last = Self.median(recent.suffix(edgeCount).map(\.value))
        let change = last - first
        let direction: ThermalTrajectory.Direction = change >= 2 ? .rising : change <= -2 ? .falling : .steady
        return ThermalTrajectory(direction: direction, changeCelsius: change, spanSeconds: span,
                                 warmSeconds: warm, hotSeconds: hot, veryHotSeconds: veryHot)
    }

    private static func median(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
    }
}
