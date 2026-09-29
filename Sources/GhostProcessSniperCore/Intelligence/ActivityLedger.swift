import Foundation

/// One minute of a family's CPU, from cumulative CPU-seconds deltas: exact
/// between any two rich reads whatever the refresh cadence.
public struct CPUMinuteBucket: Equatable, Sendable {
    public let start: Date
    public internal(set) var cpuSeconds: Double
    /// Observed time inside the minute.
    public internal(set) var wallSeconds: Double
    /// CPU-seconds of the busiest member, summed tick by tick.
    public internal(set) var dominantCPUSeconds: Double
    /// Members that joined or left during the minute.
    public internal(set) var memberChanges: Int

    /// Average cores busy: 1.0 is one core fully used (100%).
    public var cores: Double { wallSeconds > 0 ? cpuSeconds / wallSeconds : 0 }
    /// The busiest member's share of the family's CPU.
    public var dominantShare: Double { cpuSeconds > 0 ? dominantCPUSeconds / cpuSeconds : 1 }
}

/// A family's CPU over the last twenty minutes, plus when any member last
/// did work. Both moments are moved forward past time nobody observed (the
/// Mac asleep), so idleness counts observed time only.
public struct FamilyCPUActivity: Equatable, Sendable {
    /// Oldest first; the last bucket is the minute in progress.
    public let buckets: [CPUMinuteBucket]
    public let lastActiveAt: Date?
    /// Since when the ledger has measured any member's CPU, from its first
    /// of two usage reads; idleness is only claimed for time measured, never
    /// for a member outside the rich-read budget.
    public let measuredSince: Date?

    public static let empty = FamilyCPUActivity(buckets: [], lastActiveAt: nil, measuredSince: nil)

    public init(buckets: [CPUMinuteBucket], lastActiveAt: Date?, measuredSince: Date?) {
        self.buckets = buckets
        self.lastActiveAt = lastActiveAt
        self.measuredSince = measuredSince
    }

    /// Seconds since any member last used more than 1% of a core.
    public func idleSeconds(at now: Date) -> TimeInterval? {
        guard let measuredSince else { return nil }
        return max(0, now.timeIntervalSince(lastActiveAt ?? measuredSince))
    }

    /// The trailing run of finished, well-observed minutes, oldest first.
    public var recentMinutes: [CPUMinuteBucket] {
        var run: [CPUMinuteBucket] = []
        for bucket in buckets.dropLast().reversed() {
            guard bucket.wallSeconds >= 30 else { break }
            if let newer = run.last, newer.start.timeIntervalSince(bucket.start) > ActivityLedger.bucketLength + 1 {
                break
            }
            run.append(bucket)
        }
        return run.reversed()
    }
}

/// Per-process and per-family CPU history over a long horizon. Fed each tick
/// from totalProcessorSeconds; members without a fresh read contribute
/// nothing that tick. Owned by the pipeline next to the trend window.
public struct ActivityLedger: Sendable {
    static let bucketLength: TimeInterval = 60
    static let bucketCount = 20
    static let retention = TrendWindow.defaultRetention
    /// A process is active when it used more than 1% of one core.
    static let activeCores = 0.01
    /// Jitter between a read's span and the tick's wall time before the read
    /// counts as spanning time the tick never saw.
    static let spanSlack: TimeInterval = 5
    /// Scans are at most 8 s apart while Ghost runs, so a longer gap than
    /// this is time nobody observed: the Mac slept or Ghost was suspended.
    static let unobservedGap: TimeInterval = 300

    private struct ProcessEntry {
        var cpuSeconds: TimeInterval
        var measuredAt: Date?
        let firstSeen: Date
        var measuredSince: Date?
        var lastActiveAt: Date?
        var lastSeen: Date
        var tickDelta: Double
        var tickSpan: TimeInterval
        var deltaTick: UInt64
    }

    private struct FamilyEntry {
        var buckets: [CPUMinuteBucket]
        var members: Set<ProcessIdentity>
        var lastRecordedAt: Date
    }

    private var processes: [ProcessIdentity: ProcessEntry] = [:]
    private var families: [String: FamilyEntry] = [:]
    private var tick: UInt64 = 0
    private var lastPrune: Date?
    private var lastScan: Date?
    /// Stretches between scans nobody observed, oldest first. Idleness is
    /// measured in observed time: waking from a night's sleep must not make
    /// every quiet process "idle for 8 h".
    private var unobserved: [(start: Date, end: Date)] = []

    public init() {}

    public mutating func recordProcesses(_ current: [ProcessMetrics], now: Date) {
        tick += 1
        if let lastScan, now.timeIntervalSince(lastScan) > Self.unobservedGap {
            unobserved.append((lastScan, now))
        }
        lastScan = max(lastScan ?? now, now)
        for process in current {
            let freshAt: Date? = process.cpuMeasurementStatus == .fresh ? process.sampledAt : nil
            guard var entry = processes[process.identity] else {
                // The sampler's CPU tracker has nothing to compare a new
                // process with, so its first scan reads usage but reports no
                // rate. That read is still a real baseline: counting from it
                // credits the second scan's interval, as the sampler's own
                // percent does, instead of the third's. A denied read has no
                // total to count from.
                let baselineAt = freshAt ?? (process.measurementStatus == .fresh
                    && process.cpuMeasurementStatus == .unavailable ? process.sampledAt : nil)
                processes[process.identity] = ProcessEntry(
                    cpuSeconds: process.totalProcessorSeconds, measuredAt: baselineAt, firstSeen: now,
                    measuredSince: nil, lastActiveAt: nil, lastSeen: now, tickDelta: 0, tickSpan: 0, deltaTick: 0
                )
                continue
            }
            entry.lastSeen = now
            if let freshAt {
                if let previous = entry.measuredAt, freshAt > previous {
                    let delta = max(0, process.totalProcessorSeconds - entry.cpuSeconds)
                    entry.tickDelta = delta
                    entry.tickSpan = freshAt.timeIntervalSince(previous)
                    entry.deltaTick = tick
                    entry.measuredSince = entry.measuredSince ?? previous
                    if delta / freshAt.timeIntervalSince(previous) > Self.activeCores {
                        entry.lastActiveAt = freshAt
                    }
                }
                if entry.measuredAt.map({ freshAt > $0 }) ?? true {
                    entry.cpuSeconds = process.totalProcessorSeconds
                    entry.measuredAt = freshAt
                }
            }
            processes[process.identity] = entry
        }
        if lastPrune.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            processes = processes.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.retention }
            families = families.filter { now.timeIntervalSince($0.value.lastRecordedAt) <= Self.retention }
            unobserved.removeAll { now.timeIntervalSince($0.end) > Self.retention }
            lastPrune = now
        }
    }

    public mutating func recordFamily(key: String, members: [ProcessMetrics], now: Date) -> FamilyCPUActivity {
        let identities = Set(members.map(\.identity))
        var family = families[key] ?? FamilyEntry(buckets: [], members: identities, lastRecordedAt: now)
        let gap = min(30, max(0, now.timeIntervalSince(family.lastRecordedAt)))
        let changes = family.members.symmetricDifference(identities).count
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / Self.bucketLength).rounded(.down) * Self.bucketLength)
        if let last = family.buckets.last, last.start == start {
            family.buckets[family.buckets.count - 1].wallSeconds += gap
            family.buckets[family.buckets.count - 1].memberChanges += changes
        } else {
            family.buckets.append(CPUMinuteBucket(start: start, cpuSeconds: 0, wallSeconds: gap, dominantCPUSeconds: 0, memberChanges: changes))
            if family.buckets.count > Self.bucketCount {
                family.buckets.removeFirst(family.buckets.count - Self.bucketCount)
            }
        }

        var cpuSeconds = 0.0
        var dominant = 0.0
        var spread: [(cpu: Double, dominant: Double)] = []
        var lastActiveAt: Date?
        var measuredSince: Date?
        for member in members {
            guard let entry = processes[member.identity] else { continue }
            if entry.deltaTick == tick {
                if entry.tickSpan <= gap + Self.spanSlack {
                    cpuSeconds += entry.tickDelta
                    dominant = max(dominant, entry.tickDelta)
                } else if let end = entry.measuredAt {
                    // A sparse read, or the first after sleep, covers minutes
                    // this tick never saw: spread it at its average rate over
                    // the minutes it covers, and drop what fell outside them.
                    if spread.isEmpty { spread = Array(repeating: (0, 0), count: family.buckets.count) }
                    let rate = entry.tickDelta / entry.tickSpan
                    let begin = end.addingTimeInterval(-entry.tickSpan)
                    for (index, bucket) in family.buckets.enumerated() {
                        let overlap = min(end, bucket.start.addingTimeInterval(Self.bucketLength)).timeIntervalSince(max(begin, bucket.start))
                        guard overlap > 0 else { continue }
                        spread[index].cpu += rate * overlap
                        spread[index].dominant = max(spread[index].dominant, rate * overlap)
                    }
                }
            }
            if let active = entry.lastActiveAt {
                lastActiveAt = max(lastActiveAt ?? active, active)
            }
            if let since = entry.measuredSince {
                measuredSince = min(measuredSince ?? since, since)
            }
        }

        let current = family.buckets.count - 1
        if !spread.isEmpty {
            for (index, share) in spread.enumerated() where index != current {
                family.buckets[index].cpuSeconds += share.cpu
                family.buckets[index].dominantCPUSeconds += share.dominant
            }
            cpuSeconds += spread[current].cpu
            dominant = max(dominant, spread[current].dominant)
        }
        family.buckets[current].cpuSeconds += cpuSeconds
        family.buckets[current].dominantCPUSeconds += dominant
        family.members = identities
        family.lastRecordedAt = now
        families[key] = family
        return FamilyCPUActivity(buckets: family.buckets, lastActiveAt: observed(lastActiveAt),
                                 measuredSince: observed(measuredSince))
    }

    /// Moves a moment forward by the unobserved time after it, so the time
    /// since it counts only what was observed.
    private func observed(_ date: Date?) -> Date? {
        guard let date else { return nil }
        var shifted = date
        for gap in unobserved where gap.end > date {
            shifted += gap.end.timeIntervalSince(max(gap.start, date))
        }
        return shifted
    }

    /// When a process last did work, and since when it has been watched.
    public func activity(of identity: ProcessIdentity) -> (lastActiveAt: Date?, firstSeen: Date)? {
        processes[identity].map { ($0.lastActiveAt, $0.firstSeen) }
    }
}

/// What the builder remembers between ticks besides the family trends.
public struct RadarHistory: Sendable {
    public var activity = ActivityLedger()
    public var memberTrends = MemberTrendStore()

    public init() {}
}

/// History for callers of the builder that do not keep their own.
final class LockedRadarHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var history = RadarHistory()

    func withHistory<Result>(_ body: (inout RadarHistory) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&history)
    }
}
