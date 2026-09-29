import Foundation

/// Turns each process's lifetime energy, wake-up and disk-write counters into
/// rates between two reads on the monotonic uptime clock, keyed like the CPU
/// tracker so a reused pid never borrows another process's counters.
struct PowerCounterTracker: Sendable {
    private struct Point: Sendable {
        var energy: UInt64
        var wakeups: UInt64
        var diskWrites: UInt64
        var uptimeNanoseconds: UInt64
        var startStamp: UInt64
    }

    private var previous: [ProcessIdentity: Point] = [:]

    /// Call only with a usage read the CPU tracker accepted, so a pid reused
    /// between the BSD and usage reads never reaches here.
    mutating func usage(for key: ProcessIdentity, reading: ProbeUsage, at now: Date) -> ProcessPowerUsage {
        let point = Point(energy: reading.energyNanojoules, wakeups: reading.wakeups,
                          diskWrites: reading.diskBytesWritten, uptimeNanoseconds: reading.sampledAtUptimeNanoseconds,
                          startStamp: reading.processStartAbsoluteTime)
        var usage = ProcessPowerUsage(lifetimeEnergyNanojoules: point.energy, lifetimeWakeups: point.wakeups,
                                      lifetimeDiskBytesWritten: point.diskWrites, measuredAt: now)
        defer { previous[key] = point }
        guard let old = previous[key], old.startStamp == point.startStamp,
              point.uptimeNanoseconds > old.uptimeNanoseconds else { return usage }
        let seconds = Double(point.uptimeNanoseconds - old.uptimeNanoseconds) / 1_000_000_000
        // A counter that went backwards is a different accounting epoch, not negative work.
        if point.energy >= old.energy { usage.watts = Double(point.energy - old.energy) / 1_000_000_000 / seconds }
        if point.wakeups >= old.wakeups { usage.wakeupsPerSecond = Double(point.wakeups - old.wakeups) / seconds }
        if point.diskWrites >= old.diskWrites {
            usage.diskWriteBytesPerSecond = Double(point.diskWrites - old.diskWrites) / seconds
        }
        return usage
    }

    mutating func prune(keeping keys: Set<ProcessIdentity>) {
        previous = previous.filter { keys.contains($0.key) }
    }
}
