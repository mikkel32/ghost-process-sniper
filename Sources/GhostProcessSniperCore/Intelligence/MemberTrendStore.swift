import Foundation

/// A family's growth over the last ninety minutes: robust slopes over
/// one-minute buckets of each current member, summed.
public struct LongTermTrend: Equatable, Sendable {
    /// Theil-Sen slope over minute means.
    public let slopeMegabytesPerMinute: Double
    /// Theil-Sen slope over minute minimums: what survives reclaim cycles.
    public let floorSlopeMegabytesPerMinute: Double
    /// R² of the minute means, weighted by each member's growth.
    public let rSquared: Double
    public let spanMinutes: Double

    public static let none = LongTermTrend(slopeMegabytesPerMinute: 0, floorSlopeMegabytesPerMinute: 0, rSquared: 0, spanMinutes: 0)

    /// A slow leak: twenty minutes of steady growth of at least 5 MB/min (or
    /// 0.5% of RAM an hour), with the floor rising too and a clean fit.
    public func isSlowLeak(physicalMemoryBytes: UInt64) -> Bool {
        let ramFloor = Double(physicalMemoryBytes) / 1_048_576 * 0.005 / 60
        let minimum = max(5, ramFloor)
        return spanMinutes >= 20 && slopeMegabytesPerMinute >= minimum &&
            floorSlopeMegabytesPerMinute >= 0.5 * slopeMegabytesPerMinute && rSquared >= 0.6
    }
}

/// How much of a family's growth one member accounts for.
public struct MemberGrowth: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let name: String
    public let slopeMegabytesPerMinute: Double
    public let rSquared: Double
    /// Share of the family's positive growth.
    public let share: Double

    /// Named as the culprit: most of the growth, on a clean trend of its own.
    public var isCulprit: Bool { share >= 0.6 && rSquared >= 0.6 }
}

/// What one tick of a family's members adds to its trend.
struct FamilyTrendStep {
    /// Memory of the members, each at its last known reading.
    let total: UInt64
    /// Bytes to add to the family's stored history so members that joined,
    /// left or are still settling in do not read as growth or release.
    let historyShift: Int64
    /// The newest reading that advanced this tick; nil adds no sample.
    let newestMeasurement: Date?
    let longTerm: LongTermTrend
}

/// Per-member memory history at two resolutions, for members of built
/// families only: a fine ring (60 samples / 120 s) and ninety one-minute
/// buckets. A family's series becomes the sum of its members, so a child
/// spawning or exiting no longer resets it or reads as a leak.
public struct MemberTrendStore: Sendable {
    static let seriesCap = 1_200
    static let fineCapacity = 60
    static let fineRetention: TimeInterval = 120
    static let coarseCapacity = 90
    static let retention: TimeInterval = 120
    /// Members join a family's slope once they have this much history.
    static let maturitySamples = 4
    static let maturitySeconds: TimeInterval = 15
    /// Long-term slopes come from members watched at least this long.
    static let longTermMinutes: Double = 10

    struct FineSample {
        /// Seconds since the series origin.
        let time: Float
        let megabytes: Float
    }

    struct MinuteBucket {
        let minute: Int32
        var minimum: Float
        var maximum: Float
        var mean: Float
        var count: UInt16
    }

    struct Series {
        let origin: Date
        var name: String
        var fine: [FineSample]
        var coarse: [MinuteBucket]
        var lastMeasured: Date
        var heldBytes: UInt64
        var lastSeen: Date
        /// The fit of the closed minutes, and which minute was open then.
        var longTerm: (trend: LongTermTrend, buckets: Int, lastMinute: Int32?)?

        var fineSpan: TimeInterval {
            guard let first = fine.first, let last = fine.last else { return 0 }
            return TimeInterval(last.time - first.time)
        }

        var isMature: Bool {
            fine.count >= MemberTrendStore.maturitySamples && fineSpan >= MemberTrendStore.maturitySeconds
        }
    }

    private struct Chain {
        var members: [ProcessIdentity: (held: UInt64, mature: Bool)]
        var lastSeen: Date
    }

    private var series: [ProcessIdentity: Series] = [:]
    private var chains: [String: Chain] = [:]
    private var lastPrune: Date?

    public init() {}

    var seriesCount: Int { series.count }

    /// An upper bound on the bytes the store holds.
    var estimatedBytes: Int {
        let perSeries = MemoryLayout<Series>.stride + MemoryLayout<ProcessIdentity>.stride + 64
        return series.values.reduce(0) { total, entry in
            total + perSeries + entry.fine.capacity * MemoryLayout<FineSample>.stride +
                entry.coarse.capacity * MemoryLayout<MinuteBucket>.stride + entry.name.utf8.count
        } + chains.values.reduce(0) { $0 + 96 + $1.members.capacity * 48 }
    }

    mutating func advance(familyKey: String, members: [ProcessMetrics], now: Date) -> FamilyTrendStep {
        var newest: Date?
        var current: [ProcessIdentity: (held: UInt64, mature: Bool)] = [:]
        current.reserveCapacity(members.count)
        let existing = chains[familyKey]
        for member in members {
            if let measured = record(member, now: now) {
                newest = max(newest ?? measured, measured)
            }
            let entry = series[member.identity]
            // The first sight of a family is its baseline: everyone counts,
            // and a member that counts keeps counting.
            let mature = existing == nil || existing?.members[member.identity]?.mature == true || (entry?.isMature ?? false)
            current[member.identity] = (entry?.heldBytes ?? member.memoryForScoringBytes, mature)
        }

        var shift: Int64 = 0
        if let previous = existing?.members {
            for (identity, latest) in current {
                guard let before = previous[identity] else {
                    shift += Int64(latest.held)
                    continue
                }
                if !latest.mature {
                    shift += Int64(latest.held) - Int64(before.held)
                }
            }
            for (identity, before) in previous where current[identity] == nil {
                shift -= Int64(before.held)
            }
        }
        chains[familyKey] = Chain(members: current, lastSeen: now)
        pruneIfNeeded(now: now)

        return FamilyTrendStep(
            total: current.values.reduce(0) { $0 + $1.held },
            historyShift: shift,
            newestMeasurement: newest,
            longTerm: longTermSum(members: members)
        )
    }

    /// Appends a reading only when its measurement date advanced; returns it.
    private mutating func record(_ member: ProcessMetrics, now: Date) -> Date? {
        let bytes = member.memoryForScoringBytes
        guard let measured = member.measurementDate else {
            series[member.identity]?.lastSeen = now
            return nil
        }
        guard let index = series.index(forKey: member.identity) else {
            guard series.count < Self.seriesCap else { return nil }
            var fine: [FineSample] = []
            fine.reserveCapacity(Self.fineCapacity)
            var coarse: [MinuteBucket] = []
            coarse.reserveCapacity(Self.coarseCapacity)
            var created = Series(origin: measured, name: member.name, fine: fine, coarse: coarse,
                                 lastMeasured: measured, heldBytes: bytes, lastSeen: now, longTerm: nil)
            Self.append(bytes, at: measured, to: &created)
            series[member.identity] = created
            return measured
        }
        // In place: a copied entry would copy both rings on every append.
        series.values[index].lastSeen = now
        guard measured > series.values[index].lastMeasured else {
            return nil
        }
        series.values[index].lastMeasured = measured
        series.values[index].heldBytes = bytes
        Self.append(bytes, at: measured, to: &series.values[index])
        return measured
    }

    private static func append(_ bytes: UInt64, at date: Date, to entry: inout Series) {
        let megabytes = Float(Double(bytes) / 1_048_576)
        let time = Float(date.timeIntervalSince(entry.origin))
        // Drop before appending: appending to a full ring would double its
        // capacity, and the store's memory with it.
        let cutoff = time - Float(fineRetention)
        let expired = entry.fine.prefix { $0.time < cutoff }.count
        let excess = max(expired, entry.fine.count + 1 - fineCapacity)
        if excess > 0 {
            entry.fine.removeFirst(min(excess, entry.fine.count))
        }
        entry.fine.append(FineSample(time: time, megabytes: megabytes))

        let minute = Int32((date.timeIntervalSince1970 / 60).rounded(.down))
        if let last = entry.coarse.last, last.minute == minute {
            var bucket = last
            bucket.minimum = min(bucket.minimum, megabytes)
            bucket.maximum = max(bucket.maximum, megabytes)
            bucket.mean += (megabytes - bucket.mean) / Float(bucket.count + 1)
            bucket.count += 1
            entry.coarse[entry.coarse.count - 1] = bucket
        } else {
            if entry.coarse.count >= coarseCapacity {
                entry.coarse.removeFirst(entry.coarse.count + 1 - coarseCapacity)
            }
            entry.coarse.append(MinuteBucket(minute: minute, minimum: megabytes, maximum: megabytes, mean: megabytes, count: 1))
        }
    }

    /// Long-term slopes are refit only when a minute closes; between closes
    /// the cached fit stands.
    private mutating func longTerm(of identity: ProcessIdentity) -> LongTermTrend? {
        guard let index = series.index(forKey: identity) else { return nil }
        let entry = series.values[index]
        let closed = max(0, entry.coarse.count - 1)
        if let cached = entry.longTerm, cached.buckets == closed, cached.lastMinute == entry.coarse.last?.minute {
            return cached.trend
        }
        let trend = Self.fit(Array(entry.coarse.prefix(closed)))
        series.values[index].longTerm = (trend, closed, entry.coarse.last?.minute)
        return trend
    }

    static func fit(_ buckets: [MinuteBucket]) -> LongTermTrend {
        guard buckets.count >= 3, let first = buckets.first, let last = buckets.last else { return .none }
        let means = buckets.map { RobustTrend.Point(minutes: Double($0.minute - first.minute), megabytes: Double($0.mean)) }
        let minimums = buckets.map { RobustTrend.Point(minutes: Double($0.minute - first.minute), megabytes: Double($0.minimum)) }
        let slope = RobustTrend.theilSen(means)?.slope ?? 0
        let floor = RobustTrend.theilSen(minimums)?.slope ?? 0
        return LongTermTrend(
            slopeMegabytesPerMinute: slope,
            floorSlopeMegabytesPerMinute: floor,
            rSquared: rSquared(means),
            spanMinutes: Double(last.minute - first.minute)
        )
    }

    private static func rSquared(_ points: [RobustTrend.Point]) -> Double {
        let n = Double(points.count)
        guard n >= 3 else { return 0 }
        let meanX = points.reduce(0) { $0 + $1.minutes } / n
        let meanY = points.reduce(0) { $0 + $1.megabytes } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for point in points {
            let dx = point.minutes - meanX
            let dy = point.megabytes - meanY
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0 else { return 0 }
        guard syy > 0 else { return 1 }
        return min(1, (sxy * sxy) / (sxx * syy))
    }

    /// The family's long-term trend: the members watched ten minutes or
    /// more, summed, with R² weighted by each one's growth.
    private mutating func longTermSum(members: [ProcessMetrics]) -> LongTermTrend {
        var slope = 0.0, floor = 0.0, span = 0.0, weightedFit = 0.0, weight = 0.0
        for member in members {
            guard let trend = longTerm(of: member.identity), trend.spanMinutes >= Self.longTermMinutes else { continue }
            slope += trend.slopeMegabytesPerMinute
            floor += trend.floorSlopeMegabytesPerMinute
            span = max(span, trend.spanMinutes)
            if trend.slopeMegabytesPerMinute > 0 {
                weightedFit += trend.rSquared * trend.slopeMegabytesPerMinute
                weight += trend.slopeMegabytesPerMinute
            }
        }
        return LongTermTrend(
            slopeMegabytesPerMinute: slope,
            floorSlopeMegabytesPerMinute: floor,
            rSquared: weight > 0 ? weightedFit / weight : 0,
            spanMinutes: span
        )
    }

    /// Each member's growth: its long-term slope once watched ten minutes,
    /// else its fine slope once mature. Shares are of positive growth.
    /// Asked for only when the family is growing.
    mutating func growth(of members: [ProcessMetrics]) -> [MemberGrowth] {
        var rows: [(identity: ProcessIdentity, name: String, slope: Double, rSquared: Double)] = []
        for member in members {
            if let trend = longTerm(of: member.identity), trend.spanMinutes >= Self.longTermMinutes {
                rows.append((member.identity, member.name, trend.slopeMegabytesPerMinute, trend.rSquared))
            } else if let entry = series[member.identity], entry.isMature, let fine = Self.fineFit(entry.fine) {
                rows.append((member.identity, member.name, fine.slope, fine.rSquared))
            }
        }
        let positive = rows.reduce(0) { $0 + max(0, $1.slope) }
        guard positive > 0 else { return [] }
        return rows
            .filter { $0.slope > 0 }
            .map { MemberGrowth(identity: $0.identity, name: $0.name, slopeMegabytesPerMinute: $0.slope,
                                rSquared: $0.rSquared, share: $0.slope / positive) }
            .sorted { $0.share > $1.share }
    }

    private static func fineFit(_ samples: [FineSample]) -> (slope: Double, rSquared: Double)? {
        guard samples.count >= maturitySamples else { return nil }
        let points = samples.map { RobustTrend.Point(minutes: Double($0.time) / 60, megabytes: Double($0.megabytes)) }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.minutes } / n
        let meanY = points.reduce(0) { $0 + $1.megabytes } / n
        var sxy = 0.0, sxx = 0.0
        for point in points {
            sxy += (point.minutes - meanX) * (point.megabytes - meanY)
            sxx += (point.minutes - meanX) * (point.minutes - meanX)
        }
        guard sxx > 0 else { return nil }
        return (sxy / sxx, rSquared(points))
    }

    private mutating func pruneIfNeeded(now: Date) {
        guard lastPrune.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        series = series.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.retention }
        chains = chains.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.retention }
        lastPrune = now
    }
}
