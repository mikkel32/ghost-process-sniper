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
/// did work.
public struct FamilyCPUActivity: Equatable, Sendable {
    /// Oldest first; the last bucket is the minute in progress.
    public let buckets: [CPUMinuteBucket]
    public let lastActiveAt: Date?
    /// When the ledger first saw any member; idleness is only claimed for
    /// time actually watched.
    public let firstSeen: Date?

    public static let empty = FamilyCPUActivity(buckets: [], lastActiveAt: nil, firstSeen: nil)

    public init(buckets: [CPUMinuteBucket], lastActiveAt: Date?, firstSeen: Date?) {
        self.buckets = buckets
        self.lastActiveAt = lastActiveAt
        self.firstSeen = firstSeen
    }

    /// Seconds since any member last used more than 1% of a core.
    public func idleSeconds(at now: Date) -> TimeInterval? {
        guard let firstSeen else { return nil }
        return max(0, now.timeIntervalSince(lastActiveAt ?? firstSeen))
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

    private struct ProcessEntry {
        var cpuSeconds: TimeInterval
        var measuredAt: Date?
        let firstSeen: Date
        var lastActiveAt: Date?
        var lastSeen: Date
        var tickDelta: Double
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

    public init() {}

    public mutating func recordProcesses(_ current: [ProcessMetrics], now: Date) {
        tick += 1
        for process in current {
            let freshAt: Date? = process.cpuMeasurementStatus == .fresh ? process.sampledAt : nil
            guard var entry = processes[process.identity] else {
                processes[process.identity] = ProcessEntry(
                    cpuSeconds: process.totalProcessorSeconds, measuredAt: freshAt, firstSeen: now,
                    lastActiveAt: nil, lastSeen: now, tickDelta: 0, deltaTick: 0
                )
                continue
            }
            entry.lastSeen = now
            if let freshAt {
                if let previous = entry.measuredAt, freshAt > previous {
                    let delta = max(0, process.totalProcessorSeconds - entry.cpuSeconds)
                    entry.tickDelta = delta
                    entry.deltaTick = tick
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
            lastPrune = now
        }
    }

    public mutating func recordFamily(key: String, members: [ProcessMetrics], now: Date) -> FamilyCPUActivity {
        var cpuSeconds = 0.0
        var dominant = 0.0
        var lastActiveAt: Date?
        var firstSeen: Date?
        for member in members {
            guard let entry = processes[member.identity] else { continue }
            if entry.deltaTick == tick {
                cpuSeconds += entry.tickDelta
                dominant = max(dominant, entry.tickDelta)
            }
            if let active = entry.lastActiveAt {
                lastActiveAt = max(lastActiveAt ?? active, active)
            }
            firstSeen = min(firstSeen ?? entry.firstSeen, entry.firstSeen)
        }

        let identities = Set(members.map(\.identity))
        var family = families[key] ?? FamilyEntry(buckets: [], members: identities, lastRecordedAt: now)
        let gap = min(30, max(0, now.timeIntervalSince(family.lastRecordedAt)))
        let changes = family.members.symmetricDifference(identities).count
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / Self.bucketLength).rounded(.down) * Self.bucketLength)
        if let last = family.buckets.last, last.start == start {
            family.buckets[family.buckets.count - 1].cpuSeconds += cpuSeconds
            family.buckets[family.buckets.count - 1].wallSeconds += gap
            family.buckets[family.buckets.count - 1].dominantCPUSeconds += dominant
            family.buckets[family.buckets.count - 1].memberChanges += changes
        } else {
            family.buckets.append(CPUMinuteBucket(start: start, cpuSeconds: cpuSeconds, wallSeconds: gap,
                                                  dominantCPUSeconds: dominant, memberChanges: changes))
            if family.buckets.count > Self.bucketCount {
                family.buckets.removeFirst(family.buckets.count - Self.bucketCount)
            }
        }
        family.members = identities
        family.lastRecordedAt = now
        families[key] = family
        return FamilyCPUActivity(buckets: family.buckets, lastActiveAt: lastActiveAt, firstSeen: firstSeen)
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
