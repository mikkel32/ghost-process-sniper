import Foundation

/// A process's energy, wake-ups and disk writes: lifetime counters from the
/// same `proc_pid_rusage` read as its CPU time, and rates once two reads exist.
public struct ProcessPowerUsage: Equatable, Sendable {
    /// Energy macOS attributes to the process's CPU work since it started.
    /// Zero on Macs that do not account energy per process.
    public var lifetimeEnergyNanojoules: UInt64
    /// Times the process woke an idle CPU package since it started.
    public var lifetimeWakeups: UInt64
    public var lifetimeDiskBytesWritten: UInt64
    /// Watts over the last interval; nil until two reads of the same process.
    public var watts: Double?
    public var wakeupsPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    /// When the counters were read; nil when they never were.
    public var measuredAt: Date?

    public static let unmeasured = ProcessPowerUsage(
        lifetimeEnergyNanojoules: 0, lifetimeWakeups: 0, lifetimeDiskBytesWritten: 0, measuredAt: nil)

    public init(
        lifetimeEnergyNanojoules: UInt64, lifetimeWakeups: UInt64, lifetimeDiskBytesWritten: UInt64,
        watts: Double? = nil, wakeupsPerSecond: Double? = nil, diskWriteBytesPerSecond: Double? = nil,
        measuredAt: Date?
    ) {
        self.lifetimeEnergyNanojoules = lifetimeEnergyNanojoules
        self.lifetimeWakeups = lifetimeWakeups
        self.lifetimeDiskBytesWritten = lifetimeDiskBytesWritten
        self.watts = watts
        self.wakeupsPerSecond = wakeupsPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.measuredAt = measuredAt
    }

    /// Rates that are recent enough to show as "now".
    public func currentWatts(at now: Date, maximumAge: TimeInterval = 15) -> Double? {
        guard let measuredAt, (0...maximumAge).contains(now.timeIntervalSince(measuredAt)) else { return nil }
        return watts
    }
}
