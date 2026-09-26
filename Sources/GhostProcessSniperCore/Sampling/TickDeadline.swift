import Foundation

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
