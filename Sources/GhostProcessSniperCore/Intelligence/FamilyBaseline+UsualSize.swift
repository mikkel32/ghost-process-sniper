import Foundation

extension FamilyBaseline {
    /// What "usual" is measured against: the learned spread, never tighter
    /// than 5% of the mean or 32 MiB, so a family that never varied does not
    /// turn a few megabytes into a huge score.
    var memoryScale: Double {
        max(memoryStandardDeviation, meanMemoryBytes * 0.05, 32 * 1_048_576)
    }

    /// The top of the size this family calls usual: under two spreads above
    /// its mean and under 1.3x it. This is exactly the region usualSize
    /// accepts, so growth can be judged against the same line.
    var usualMemoryCeilingBytes: Double {
        min(meanMemoryBytes + 2 * memoryScale, meanMemoryBytes * 1.3)
    }

    /// Whether climbing at this rate only takes the family back to a size that
    /// is usual for it: an app restarted, or purged of its caches, filling up
    /// again. Judged over the next `minutes`, and false unless the baseline is
    /// trusted. Below half its usual size there is nothing to refill to, so a
    /// leak that starts small in a big app is never excused.
    func staysWithinUsualSize(footprint: UInt64, growthMegabytesPerMinute: Double, minutes: Double = 10) -> Bool {
        guard isMeasurementTrusted else { return false }
        let current = Double(footprint)
        guard current >= meanMemoryBytes * 0.5 else { return false }
        return current + max(0, growthMegabytesPerMinute) * 1_048_576 * minutes < usualMemoryCeilingBytes
    }
}
