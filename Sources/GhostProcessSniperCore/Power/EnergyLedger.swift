import Foundation

/// One minute of an app's or job's energy, idle wake-ups, disk writes and CPU.
public struct EnergyMinute: Equatable, Sendable {
    public let start: Date
    public internal(set) var joules: Double = 0
    public internal(set) var idleWakeups: Double = 0
    public internal(set) var diskBytesWritten: Double = 0
    public internal(set) var cpuSeconds: Double = 0
    /// Wall time inside the minute the group was observed.
    public internal(set) var observedSeconds: Double = 0

    public var watts: Double { observedSeconds > 0 ? joules / observedSeconds : 0 }
}

/// Sums over the trailing minutes of one group, with rates over the time observed.
public struct EnergyWindow: Equatable, Sendable {
    public var joules = 0.0
    public var idleWakeups = 0.0
    public var diskBytesWritten = 0.0
    public var cpuSeconds = 0.0
    public var observedSeconds = 0.0

    init(_ minutes: ArraySlice<EnergyMinute>) {
        for minute in minutes {
            joules += minute.joules
            idleWakeups += minute.idleWakeups
            diskBytesWritten += minute.diskBytesWritten
            cpuSeconds += minute.cpuSeconds
            observedSeconds += minute.observedSeconds
        }
    }

    public var watts: Double { observedSeconds > 0 ? joules / observedSeconds : 0 }
    public var idleWakeupsPerSecond: Double { observedSeconds > 0 ? idleWakeups / observedSeconds : 0 }
    public var diskWriteBytesPerSecond: Double { observedSeconds > 0 ? diskBytesWritten / observedSeconds : 0 }
    /// Average cores busy: 1.0 is one core fully used.
    public var cores: Double { observedSeconds > 0 ? cpuSeconds / observedSeconds : 0 }
}

/// Where a group of processes belongs, for grouping and for navigation.
struct EnergyGroupAssignment: Equatable, Sendable {
    let key: String
    let displayName: String
    let kind: ThermalWorkloadKind
    let applicationPath: String?
    let hostAppName: String?
}

/// An hour of energy per app, job and known source, exact at any cadence: each
/// minute adds the growth of every member's lifetime counters since its last
/// fresh read, so nothing is inferred from instantaneous rates. A process seen
/// for the first time contributes from its second read on; time the Mac slept
/// is neither observed nor charged.
struct EnergyLedger: Sendable {
    static let bucketLength: TimeInterval = 60
    static let bucketCount = 60
    /// The longest tick gap counted as observed time; longer gaps are sleep or a stall.
    static let maximumGap: TimeInterval = 30

    struct Group: Sendable {
        var assignment: EnergyGroupAssignment
        var minutes: [EnergyMinute] = []
        var lastSeen: Date
        var processCount = 0
        var currentWatts = 0.0
        var currentMeasuredCount = 0
        var isSystem = true
        var familyKey: String?
        var familyWeight = -1.0
        /// Every pid currently in the group, for attributing sleep assertions.
        var pids: [Int32] = []
    }

    private struct Counters: Sendable {
        var energy: UInt64
        var wakeups: UInt64
        var diskWrites: UInt64
        var cpuSeconds: TimeInterval
        var lastSeen: Date
    }

    private(set) var groups: [String: Group] = [:]
    private(set) var host: [EnergyMinute] = []
    private(set) var lastTick: Date?
    /// Processes whose energy counter ever moved; zero everywhere means the
    /// kernel does not account energy per process on this Mac.
    private(set) var energyAccounted = false
    private var counters: [ProcessIdentity: Counters] = [:]
    private var lastPrune: Date?

    /// Records one tick. `assign` names each process's group; `familyKey`
    /// names the radar family that owns it, when one does.
    mutating func record(
        processes: [ProcessMetrics], now: Date,
        assign: (ProcessMetrics) -> EnergyGroupAssignment,
        familyKey: (ProcessMetrics) -> String?
    ) {
        let gap = lastTick.map { min(Self.maximumGap, max(0, now.timeIntervalSince($0))) } ?? 0
        lastTick = now
        let start = Self.minuteStart(now)
        var seen: Set<String> = []
        var hostMinute = EnergyMinute(start: start)

        for process in processes where !process.isZombie {
            let assignment = assign(process)
            if groups[assignment.key] == nil { groups[assignment.key] = Group(assignment: assignment, lastSeen: now) }
            let firstThisTick = seen.insert(assignment.key).inserted
            let previous = counters[process.identity]
            let owner = familyKey(process)
            // Mutated in place: a copy per process would copy the group's minutes each time.
            Self.update(&groups[assignment.key]!) { group in
                if firstThisTick {
                    group.assignment = assignment
                    group.processCount = 0
                    group.currentWatts = 0
                    group.currentMeasuredCount = 0
                    group.isSystem = true
                    group.familyKey = nil
                    group.familyWeight = -1
                    group.pids.removeAll(keepingCapacity: true)
                    group.lastSeen = now
                    Self.open(&group.minutes, at: start)
                    group.minutes[group.minutes.count - 1].observedSeconds += gap
                }
                group.processCount += 1
                group.pids.append(process.pid)
                group.isSystem = group.isSystem && process.isSystemProcess
                let power = process.power
                if power.measuredAt == process.sampledAt {
                    if let watts = power.watts, watts.isFinite, watts >= 0 {
                        group.currentWatts += watts
                        group.currentMeasuredCount += 1
                    }
                    if let previous {
                        Self.charge(&group.minutes[group.minutes.count - 1], host: &hostMinute, process: process,
                                    since: previous)
                    }
                }
                if let owner {
                    // The busiest owned member names the family, like the heat panel.
                    let weight = process.cpuPercent
                    if weight > group.familyWeight || (weight == group.familyWeight && owner < (group.familyKey ?? owner)) {
                        group.familyKey = owner
                        group.familyWeight = weight
                    }
                }
            }
            if process.power.measuredAt == process.sampledAt {
                if process.power.lifetimeEnergyNanojoules > 0 { energyAccounted = true }
                counters[process.identity] = Counters(
                    energy: process.power.lifetimeEnergyNanojoules, wakeups: process.power.lifetimeIdleWakeups,
                    diskWrites: process.power.lifetimeDiskBytesWritten, cpuSeconds: process.totalProcessorSeconds,
                    lastSeen: now)
            } else if previous != nil {
                counters[process.identity]?.lastSeen = now
            }
        }

        Self.open(&host, at: start)
        host[host.count - 1].observedSeconds += gap
        host[host.count - 1].joules += hostMinute.joules
        host[host.count - 1].idleWakeups += hostMinute.idleWakeups
        host[host.count - 1].diskBytesWritten += hostMinute.diskBytesWritten
        host[host.count - 1].cpuSeconds += hostMinute.cpuSeconds

        // Groups not seen this tick keep their history but no longer run.
        for key in groups.keys where !seen.contains(key) {
            groups[key]?.processCount = 0
            groups[key]?.currentWatts = 0
            groups[key]?.currentMeasuredCount = 0
            groups[key]?.pids = []
        }
        prune(now: now)
    }

    private static func update(_ group: inout Group, _ body: (inout Group) -> Void) { body(&group) }

    /// Adds the growth of one process's lifetime counters since its last read.
    private static func charge(_ minute: inout EnergyMinute, host: inout EnergyMinute, process: ProcessMetrics,
                               since previous: Counters) {
        let power = process.power
        if power.lifetimeEnergyNanojoules >= previous.energy {
            let joules = Double(power.lifetimeEnergyNanojoules - previous.energy) / 1_000_000_000
            minute.joules += joules
            host.joules += joules
        }
        if power.lifetimeIdleWakeups >= previous.wakeups {
            let wakeups = Double(power.lifetimeIdleWakeups - previous.wakeups)
            minute.idleWakeups += wakeups
            host.idleWakeups += wakeups
        }
        if power.lifetimeDiskBytesWritten >= previous.diskWrites {
            let bytes = Double(power.lifetimeDiskBytesWritten - previous.diskWrites)
            minute.diskBytesWritten += bytes
            host.diskBytesWritten += bytes
        }
        let cpu = process.totalProcessorSeconds - previous.cpuSeconds
        if cpu.isFinite, cpu > 0 {
            minute.cpuSeconds += cpu
            host.cpuSeconds += cpu
        }
    }

    /// The trailing `minutes` of a group, the one in progress included.
    func window(_ key: String, minutes: Int) -> EnergyWindow {
        guard let group = groups[key] else { return EnergyWindow([]) }
        return Self.window(group.minutes, minutes: minutes, now: lastTick ?? .distantPast)
    }

    func hostWindow(minutes: Int) -> EnergyWindow {
        Self.window(host, minutes: minutes, now: lastTick ?? .distantPast)
    }

    static func window(_ buckets: [EnergyMinute], minutes: Int, now: Date) -> EnergyWindow {
        let earliest = minuteStart(now).addingTimeInterval(-Double(max(0, minutes - 1)) * bucketLength)
        let first = buckets.firstIndex { $0.start >= earliest } ?? buckets.endIndex
        return EnergyWindow(buckets[first...])
    }

    static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucketLength).rounded(.down) * bucketLength)
    }

    private static func open(_ minutes: inout [EnergyMinute], at start: Date) {
        if let last = minutes.last, last.start >= start { return }
        minutes.append(EnergyMinute(start: start))
        if minutes.count > bucketCount { minutes.removeFirst(minutes.count - bucketCount) }
    }

    private mutating func prune(now: Date) {
        guard lastPrune.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastPrune = now
        let horizon = Double(Self.bucketCount) * Self.bucketLength
        groups = groups.filter { now.timeIntervalSince($0.value.lastSeen) <= horizon }
        counters = counters.filter { now.timeIntervalSince($0.value.lastSeen) <= 120 }
        let earliest = now.addingTimeInterval(-horizon)
        host.removeAll { $0.start < earliest }
    }
}
