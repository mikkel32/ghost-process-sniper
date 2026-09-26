import Foundation

public struct SamplerDeadline: Equatable, Sendable {
    public let startedAt: Date
    public let budgetMilliseconds: Double

    public init(startedAt: Date, budgetMilliseconds: Double) {
        self.startedAt = startedAt
        self.budgetMilliseconds = budgetMilliseconds
    }

    public func elapsedMilliseconds(now: Date = Date()) -> Double {
        now.timeIntervalSince(startedAt) * 1_000
    }

    public func isExpired(now: Date = Date()) -> Bool {
        elapsedMilliseconds(now: now) >= budgetMilliseconds
    }
}

/// The sampler's own deadline, on the probe source's monotonic clock so a
/// test can script time and a wall-clock change cannot stretch a tick.
struct TickDeadline: Sendable {
    let startedAt: UInt64
    var budgetMilliseconds: Double

    func elapsedMilliseconds(at now: UInt64) -> Double {
        Double(now > startedAt ? now - startedAt : 0) / 1_000_000
    }

    func isExpired(at now: UInt64) -> Bool {
        elapsedMilliseconds(at: now) >= budgetMilliseconds
    }
}
