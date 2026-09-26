import Darwin
import Foundation

/// What the radar itself costs. A process monitor that burns CPU is part of
/// the problem it claims to solve, so the app meters itself and throttles its
/// own cadence when it crosses budget.
public struct SelfResourceUsage: Equatable, Sendable {
    /// CPU consumed between the last two samples, as a percent of one core.
    public let cpuPercent: Double
    /// Exponentially weighted average of cpuPercent.
    public let averageCPUPercent: Double
    public let footprintBytes: UInt64
    /// True while the average is above budget; the refresh loop stretches
    /// its cadence until this clears.
    public let isThrottling: Bool

    public static let unknown = SelfResourceUsage(
        cpuPercent: 0,
        averageCPUPercent: 0,
        footprintBytes: 0,
        isThrottling: false
    )

    public init(cpuPercent: Double, averageCPUPercent: Double, footprintBytes: UInt64, isThrottling: Bool) {
        self.cpuPercent = max(0, cpuPercent)
        self.averageCPUPercent = max(0, averageCPUPercent)
        self.footprintBytes = footprintBytes
        self.isThrottling = isThrottling
    }
}

public struct SelfUsageMonitor: Sendable {
    private var lastCPUSeconds: Double?
    private var lastSampleDate: Date?
    private var averageCPUPercent = 0.0
    private let throttleThresholdPercent: Double

    public init(throttleThresholdPercent: Double = 6) {
        self.throttleThresholdPercent = throttleThresholdPercent
    }

    public mutating func sample(now: Date = Date()) -> SelfResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

        var cpuPercent = 0.0
        if let lastCPUSeconds, let lastSampleDate {
            let wallSeconds = now.timeIntervalSince(lastSampleDate)
            if wallSeconds > 0.05 {
                cpuPercent = max(0, (cpuSeconds - lastCPUSeconds) / wallSeconds * 100)
            }
        }
        lastCPUSeconds = cpuSeconds
        lastSampleDate = now

        let alpha = averageCPUPercent == 0 ? 1.0 : 0.25
        averageCPUPercent = averageCPUPercent * (1 - alpha) + cpuPercent * alpha

        var info = rusage_info_v4()
        let footprintResult = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        let footprint = footprintResult == 0 ? info.ri_phys_footprint : 0

        return SelfResourceUsage(
            cpuPercent: cpuPercent,
            averageCPUPercent: averageCPUPercent,
            footprintBytes: footprint,
            isThrottling: averageCPUPercent > throttleThresholdPercent
        )
    }
}
