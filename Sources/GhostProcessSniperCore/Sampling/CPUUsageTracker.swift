import Foundation

public struct CPUUsageTracker<Key: Hashable & Sendable>: Sendable {
    private struct Point: Sendable {
        var totalProcessorSeconds: TimeInterval
        var clockSeconds: Double
        /// The first process start stamp seen for the key; 0 when the caller has none.
        var startStamp: UInt64
    }

    enum Reading: Equatable, Sendable {
        /// 100 means one core.
        case percent(Double)
        /// First reading for the key, or counters or clock that did not advance.
        case baseline
        /// The start stamp differs from the one first seen for this key: the pid
        /// was reused between reads, so the reading belongs to another process.
        case startMismatch
        case invalid
    }

    private var previous: [Key: Point] = [:]

    public init() {}

    public mutating func percent(
        key: Key,
        totalProcessorSeconds: TimeInterval,
        wallClock: Date
    ) -> Double? {
        let reading = record(key: key, processorSeconds: totalProcessorSeconds,
                             clockSeconds: wallClock.timeIntervalSinceReferenceDate, startStamp: 0)
        if case .percent(let value) = reading { return value }
        return nil
    }

    /// Feeds a reading taken on the monotonic uptime clock, so wall-clock jumps
    /// cannot distort or blank the rate.
    mutating func reading(
        key: Key,
        processorSeconds: TimeInterval,
        uptimeNanoseconds: UInt64,
        startStamp: UInt64
    ) -> Reading {
        record(key: key, processorSeconds: processorSeconds,
               clockSeconds: Double(uptimeNanoseconds) / 1_000_000_000, startStamp: startStamp)
    }

    public mutating func prune(keeping keys: Set<Key>) {
        previous = previous.filter { keys.contains($0.key) }
    }

    private mutating func record(key: Key, processorSeconds: TimeInterval,
                                 clockSeconds: Double, startStamp: UInt64) -> Reading {
        guard processorSeconds.isFinite, processorSeconds >= 0, clockSeconds.isFinite else { return .invalid }
        guard let old = previous[key] else {
            previous[key] = Point(totalProcessorSeconds: processorSeconds, clockSeconds: clockSeconds,
                                  startStamp: startStamp)
            return .baseline
        }
        if old.startStamp != 0, startStamp != 0, old.startStamp != startStamp {
            return .startMismatch
        }
        previous[key] = Point(totalProcessorSeconds: processorSeconds, clockSeconds: clockSeconds,
                              startStamp: old.startStamp != 0 ? old.startStamp : startStamp)

        let processorDelta = processorSeconds - old.totalProcessorSeconds
        let clockDelta = clockSeconds - old.clockSeconds
        guard processorDelta >= 0, clockDelta > 0 else {
            return .baseline
        }
        return .percent(processorDelta / clockDelta * 100)
    }
}
