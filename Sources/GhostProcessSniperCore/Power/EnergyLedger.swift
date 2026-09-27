import Foundation

/// One minute of an app's or job's energy, wake-ups, disk writes and CPU.
public struct EnergyMinute: Equatable, Sendable {
    public let start: Date
    public internal(set) var joules: Double = 0
    public internal(set) var wakeups: Double = 0
    public internal(set) var diskBytesWritten: Double = 0
    public internal(set) var cpuSeconds: Double = 0
    /// Wall time inside the minute the group was observed.
    public internal(set) var observedSeconds: Double = 0

    public var watts: Double { observedSeconds > 0 ? joules / observedSeconds : 0 }
}

/// Sums over the trailing minutes of one group, with rates over the time observed.
public struct EnergyWindow: Equatable, Sendable {
    public var joules = 0.0
    public var wakeups = 0.0
    public var diskBytesWritten = 0.0
    public var cpuSeconds = 0.0
    public var observedSeconds = 0.0

    init(_ minutes: ArraySlice<EnergyMinute>) {
        for minute in minutes {
            joules += minute.joules
            wakeups += minute.wakeups
            diskBytesWritten += minute.diskBytesWritten
            cpuSeconds += minute.cpuSeconds
            observedSeconds += minute.observedSeconds
        }
    }

    public var watts: Double { observedSeconds > 0 ? joules / observedSeconds : 0 }
    public var wakeupsPerSecond: Double { observedSeconds > 0 ? wakeups / observedSeconds : 0 }
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
    /// Each process's wake-up rate is averaged with this time constant, the
    /// window macOS's wake-ups monitor uses.
    static let wakeupTimeConstant: TimeInterval = 300

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
        /// The member with the highest averaged wake-up rate that has been
        /// averaged for long enough to judge (`wakeupTimeConstant` × 0.8).
        var busiestWakeups: WakeupLeader?
    }

    private struct Counters: Sendable {
        var energy: UInt64
        var wakeups: UInt64
        var diskWrites: UInt64
        var cpuSeconds: TimeInterval
        var lastSeen: Date
        /// When these counters were read; `lastSeen` also moves on scans without a read.
        var readAt: Date
        var wakeupRate: Double?
        var rateSince: Date?
    }

    private(set) var groups: [String: Group] = [:]
    private(set) var host: [EnergyMinute] = []
    private(set) var lastTick: Date?
    /// Processes whose energy counter ever moved; zero everywhere means the
    /// kernel does not account energy per process on this Mac.
    private(set) var energyAccounted = false
    private var counters: [ProcessIdentity: Counters] = [:]
    private var lastPrune: Date?
    /// What each group was charged in the last recorded scan, for the daily history.
    private(set) var tickCharges: [String: EnergyMinute] = [:]

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
        tickCharges.removeAll(keepingCapacity: true)
        var charges = tickCharges

        for process in processes where !process.isZombie {
            let assignment = assign(process)
            if groups[assignment.key] == nil { groups[assignment.key] = Group(assignment: assignment, lastSeen: now) }
            let firstThisTick = seen.insert(assignment.key).inserted
            let previous = counters[process.identity]
            let owner = familyKey(process)
            let fresh = process.power.measuredAt == process.sampledAt
            let rate = fresh ? previous.flatMap { Self.averagedWakeups(process, since: $0, now: now) } : nil
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
                    group.busiestWakeups = nil
                    group.lastSeen = now
                    Self.open(&group.minutes, at: start)
                    group.minutes[group.minutes.count - 1].observedSeconds += gap
                }
                group.processCount += 1
                group.pids.append(process.pid)
                group.isSystem = group.isSystem && process.isSystemProcess
                let averaged = rate ?? previous.flatMap { old in old.rateSince.map { (old.wakeupRate ?? 0, $0) } }
                if let averaged, now.timeIntervalSince(averaged.1) >= Self.wakeupTimeConstant * 0.8,
                   averaged.0 > (group.busiestWakeups?.perSecond ?? -1) {
                    group.busiestWakeups = WakeupLeader(name: process.name, perSecond: averaged.0)
                }
                let power = process.power
                if fresh {
                    if let watts = power.watts, watts.isFinite, watts >= 0 {
                        group.currentWatts += watts
                        group.currentMeasuredCount += 1
                    }
                    if let previous {
                        let charge = Self.charge(process, since: previous, start: start)
                        Self.add(charge, to: &group.minutes[group.minutes.count - 1])
                        Self.add(charge, to: &hostMinute)
                        Self.add(charge, to: &charges[assignment.key, default: EnergyMinute(start: start)])
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
            if fresh {
                if process.power.lifetimeEnergyNanojoules > 0 { energyAccounted = true }
                counters[process.identity] = Counters(
                    energy: process.power.lifetimeEnergyNanojoules, wakeups: process.power.lifetimeWakeups,
                    diskWrites: process.power.lifetimeDiskBytesWritten, cpuSeconds: process.totalProcessorSeconds,
                    lastSeen: now, readAt: now, wakeupRate: rate?.0 ?? previous?.wakeupRate,
                    rateSince: rate?.1 ?? previous?.rateSince)
            } else if previous != nil {
                counters[process.identity]?.lastSeen = now
            }
        }

        tickCharges = charges
        Self.open(&host, at: start)
        host[host.count - 1].observedSeconds += gap
        host[host.count - 1].joules += hostMinute.joules
        host[host.count - 1].wakeups += hostMinute.wakeups
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

    /// The process's wake-ups per second, time-weighted over about five
    /// minutes, and since when it has been averaged. Gaps longer than the
    /// longest tick are sleep and skipped.
    private static func averagedWakeups(_ process: ProcessMetrics, since previous: Counters,
                                        now: Date) -> (Double, Date)? {
        let seconds = now.timeIntervalSince(previous.readAt)
        guard seconds > 0, seconds <= maximumGap, process.power.lifetimeWakeups >= previous.wakeups else {
            return previous.wakeupRate.map { ($0, previous.rateSince ?? now) }
        }
        let instant = Double(process.power.lifetimeWakeups - previous.wakeups) / seconds
        guard let old = previous.wakeupRate, let since = previous.rateSince else { return (instant, previous.readAt) }
        // Cumulative until the window has filled, then exponential: unbiased from the first minutes on.
        let span = now.timeIntervalSince(since)
        let alpha = max(1 - exp(-seconds / wakeupTimeConstant), seconds / max(span, seconds))
        return (old + alpha * (instant - old), since)
    }

    /// The growth of one process's lifetime counters since its last read.
    private static func charge(_ process: ProcessMetrics, since previous: Counters, start: Date) -> EnergyMinute {
        let power = process.power
        var charge = EnergyMinute(start: start)
        if power.lifetimeEnergyNanojoules >= previous.energy {
            charge.joules = Double(power.lifetimeEnergyNanojoules - previous.energy) / 1_000_000_000
        }
        if power.lifetimeWakeups >= previous.wakeups {
            charge.wakeups = Double(power.lifetimeWakeups - previous.wakeups)
        }
        if power.lifetimeDiskBytesWritten >= previous.diskWrites {
            charge.diskBytesWritten = Double(power.lifetimeDiskBytesWritten - previous.diskWrites)
        }
        let cpu = process.totalProcessorSeconds - previous.cpuSeconds
        if cpu.isFinite, cpu > 0 { charge.cpuSeconds = cpu }
        return charge
    }

    private static func add(_ charge: EnergyMinute, to minute: inout EnergyMinute) {
        minute.joules += charge.joules
        minute.wakeups += charge.wakeups
        minute.diskBytesWritten += charge.diskBytesWritten
        minute.cpuSeconds += charge.cpuSeconds
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
