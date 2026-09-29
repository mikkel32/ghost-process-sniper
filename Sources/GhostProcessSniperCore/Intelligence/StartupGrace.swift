import Foundation

/// One definition of "only just launched", shared by the scorer and the
/// forecaster so the score and the forecast never disagree about warm-up.
/// Freshly launched tools allocate fast while they warm their caches: that
/// is a ramp, not yet a leak, however steep.
enum StartupGrace {
    static let seconds: TimeInterval = 150

    /// Judged by the family's root, which is the app the user launched.
    /// A start time in the future (a clock stepped back) or one the kernel
    /// did not report (zero) never counts, so a family cannot stay in grace.
    static func isStarting(root: ProcessMetrics, now: Date) -> Bool {
        let started = Date(timeIntervalSince1970: TimeInterval(root.identity.startTimeSeconds))
        let age = now.timeIntervalSince(started)
        return age >= 0 && age < seconds
    }
}
