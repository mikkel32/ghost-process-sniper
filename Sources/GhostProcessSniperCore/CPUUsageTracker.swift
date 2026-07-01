import Foundation

public struct CPUUsageTracker<Key: Hashable & Sendable>: Sendable {
    private struct Point: Sendable {
        var totalProcessorSeconds: TimeInterval
        var wallClock: Date
    }

    private var previous: [Key: Point] = [:]

    public init() {}

    public mutating func percent(
        key: Key,
        totalProcessorSeconds: TimeInterval,
        wallClock: Date
    ) -> Double? {
        let point = Point(totalProcessorSeconds: totalProcessorSeconds, wallClock: wallClock)
        defer { previous[key] = point }

        guard let old = previous[key] else {
            return nil
        }

        let processorDelta = totalProcessorSeconds - old.totalProcessorSeconds
        let wallDelta = wallClock.timeIntervalSince(old.wallClock)
        guard processorDelta >= 0, wallDelta > 0 else {
            return nil
        }

        return processorDelta / wallDelta * 100
    }

    public mutating func prune(keeping keys: Set<Key>) {
        previous = previous.filter { keys.contains($0.key) }
    }
}
