import Foundation

/// The Mac's draw as the power controller's own interval means.
///
/// The registry publishes `PowerTelemetryData` only every 10 to 60 seconds,
/// while the monitor reads it every two, so the snapshot fields are one sample
/// held for a long time: taken during a burst, it can dominate an average for
/// minutes. The running sums beside them give the exact mean of everything the
/// controller sampled in between. Each advance of the counter becomes one
/// interval; a mean over a window adds the intervals up by the samples they
/// took, so a one-second sliver never counts as much as a minute.
struct DrawAverager: Sendable {
    /// Longer than a scan can be stalled by sleep or a paused app: an interval
    /// this long is not a mean of one continuous stretch.
    static let maximumGap: TimeInterval = 600
    /// Kept a little longer than the longest window anyone asks for.
    static let retention: TimeInterval = 360
    /// Fewer samples than this (about that many seconds) is not yet an average.
    static let minimumSamples = 10.0

    private struct Interval: Sendable {
        let milliwattSamples: Double
        let samples: Double
        let at: Date
    }

    private var last: PowerAccumulator?
    private var lastAdvance: Date?
    private var discharging: Bool?
    private var intervals: [Interval] = []

    var intervalCount: Int { intervals.count }

    /// Call with every battery read. Reads between registry updates return
    /// at once: the counter has not moved.
    mutating func add(_ accumulator: PowerAccumulator?, at now: Date, discharging isDischarging: Bool) {
        // A new power source starts afresh, as the snapshot average does.
        if discharging != isDischarging { reset() }
        discharging = isDischarging
        guard let accumulator else { return }
        guard let previous = last, let advancedAt = lastAdvance else { begin(accumulator, at: now); return }
        guard accumulator.samples != previous.samples else { return }
        // A counter that went backwards was reset; a long gap spans sleep; either way, and for a mean
        // that is not a real draw, keep no interval and count from here.
        guard now.timeIntervalSince(advancedAt) <= Self.maximumGap,
              PowerAccumulator.averageWatts(from: previous, to: accumulator) != nil else {
            reset()
            begin(accumulator, at: now)
            return
        }
        intervals.append(Interval(milliwattSamples: accumulator.sum - previous.sum,
                                  samples: accumulator.samples - previous.samples, at: now))
        intervals.removeAll { now.timeIntervalSince($0.at) > Self.retention }
        last = accumulator
        lastAdvance = now
    }

    /// The mean draw over the intervals that ended in the last `window`
    /// seconds; nil until they hold enough samples.
    func watts(over window: TimeInterval, now: Date) -> Double? {
        var sum = 0.0, samples = 0.0
        for interval in intervals where now.timeIntervalSince(interval.at) <= window {
            sum += interval.milliwattSamples
            samples += interval.samples
        }
        guard samples >= Self.minimumSamples else { return nil }
        return sum / samples / 1_000
    }

    private mutating func begin(_ accumulator: PowerAccumulator, at now: Date) {
        last = accumulator
        lastAdvance = now
    }

    private mutating func reset() {
        last = nil
        lastAdvance = nil
        intervals.removeAll()
    }
}
