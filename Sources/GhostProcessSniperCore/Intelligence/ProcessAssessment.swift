import Foundation

/// How much of a family was measured recently enough to score it. One
/// unmeasured or slow-to-refresh child must not blank a whole family, but a
/// stale member holding a real share of the footprint must.
public struct FamilyMeasurementCoverage: Equatable, Sendable {
    public static let maximumAge: TimeInterval = 15
    /// Just-spawned children often have no reading yet; they are not missing.
    static let unmeasuredGrace: TimeInterval = 30

    /// Fresh footprint over fresh plus last-known stale footprint.
    public let memoryCoverage: Double
    public let freshMemberCount: Int
    /// Members that count toward coverage (young unmeasured ones do not).
    public let memberCount: Int
    public let rootIsFresh: Bool
    public let newestFreshMeasurement: Date?
    /// The clock the coverage was judged against.
    public let evaluatedAt: Date

    public init(
        memoryCoverage: Double,
        freshMemberCount: Int,
        memberCount: Int,
        rootIsFresh: Bool,
        newestFreshMeasurement: Date?,
        evaluatedAt: Date
    ) {
        self.memoryCoverage = min(1, max(0, memoryCoverage))
        self.freshMemberCount = freshMemberCount
        self.memberCount = memberCount
        self.rootIsFresh = rootIsFresh
        self.newestFreshMeasurement = newestFreshMeasurement
        self.evaluatedAt = evaluatedAt
    }

    public init(members: [ProcessMetrics], root: ProcessMetrics, at now: Date, maximumAge: TimeInterval = Self.maximumAge) {
        var freshBytes: UInt64 = 0
        var staleBytes: UInt64 = 0
        var fresh = 0
        var counted = 0
        var newest: Date?
        // A zombie holds nothing and is never measured; it is the parent's
        // problem, not a gap in the family's readings.
        for member in members where !member.isZombie {
            let measuredAt = member.measurementDate
            let isFresh = measuredAt.map { (0...maximumAge).contains(now.timeIntervalSince($0)) } ?? false
            if measuredAt == nil {
                let started = Date(timeIntervalSince1970: TimeInterval(member.identity.startTimeSeconds))
                if now.timeIntervalSince(started) < Self.unmeasuredGrace { continue }
            }
            counted += 1
            if isFresh, let measuredAt {
                fresh += 1
                freshBytes += member.memoryForScoringBytes
                newest = max(newest ?? measuredAt, measuredAt)
            } else {
                staleBytes += member.memoryForScoringBytes
            }
        }
        let total = freshBytes + staleBytes
        self.init(
            memoryCoverage: total > 0 ? Double(freshBytes) / Double(total) : (fresh == counted ? 1 : 0),
            freshMemberCount: fresh,
            memberCount: counted,
            rootIsFresh: root.measurementDate.map { (0...maximumAge).contains(now.timeIntervalSince($0)) } ?? false,
            newestFreshMeasurement: newest,
            evaluatedAt: now
        )
    }

    /// The root is current and the fresh readings cover the family: 90%, or
    /// 75% of a big tree, where some helper is always between reads.
    public var isScorable: Bool {
        rootIsFresh && memoryCoverage >= (memberCount >= 8 ? 0.75 : 0.9)
    }

    public var isComplete: Bool {
        rootIsFresh && freshMemberCount == memberCount
    }

    public var isEstimated: Bool {
        freshMemberCount < memberCount
    }
}

extension ProcessFamily {
    /// The oldest component determines the freshness of a sum. Missing members
    /// cannot be silently counted as zero or treated as new trend evidence.
    public var measurementDate: Date? {
        let dates = members.compactMap(\.measurementDate)
        guard !members.isEmpty, dates.count == members.count else { return nil }
        return dates.min()
    }

    /// The coverage at `date`; the one computed at build time when the clocks
    /// agree, as they do within a pipeline tick.
    public func measurementCoverage(at date: Date, maximumAge: TimeInterval = FamilyMeasurementCoverage.maximumAge) -> FamilyMeasurementCoverage {
        if date == coverage.evaluatedAt, maximumAge == FamilyMeasurementCoverage.maximumAge {
            return coverage
        }
        return FamilyMeasurementCoverage(members: members, root: root, at: date, maximumAge: maximumAge)
    }

    /// Whether the family can be scored at `date`; see FamilyMeasurementCoverage.
    public func hasRecentMeasurements(at date: Date, maximumAge: TimeInterval = FamilyMeasurementCoverage.maximumAge) -> Bool {
        measurementCoverage(at: date, maximumAge: maximumAge).isScorable
    }

    /// Some members' readings are older than the scoring window; the totals
    /// carry their last-known memory but not their CPU.
    public var isEstimated: Bool { coverage.isEstimated }
}

extension GhostLevel {
    public var actionLabel: String {
        switch self {
        case .quiet: "Stable"
        case .watch: "Observe"
        case .hot: "Review"
        case .critical: "Urgent"
        }
    }
}

/// Describes observed resource use, never an invented per-process temperature.
public struct ProcessAssessment: Equatable, Sendable {
    public let cause: String
    public let evidence: String
    public let recommendation: String
    public let measurementText: String
    public let status: String
    public let systemImage: String

    public init(family: ProcessFamily) {
        let complete = family.hasRecentMeasurements(at: family.lastScoredAt ?? family.root.sampledAt)
        let memory = RadarFormat.bytes(family.totalPhysicalFootprintBytes)
        let cpu = RadarFormat.percent(family.totalCPUPercent)
        let gpu = RadarFormat.percent(family.totalGPUPercent)
        let duration = Int(family.trend.observedSeconds.rounded())
        let coverage = family.coverage
        if complete, coverage.isEstimated {
            measurementText = "Estimated from \(coverage.freshMemberCount) of \(coverage.memberCount) processes"
        } else {
            measurementText = complete ? (duration >= 15 ? "Observed for \(duration)s" : "Building history") : "Partial or stale measurements"
        }
        status = complete ? family.score.level.actionLabel : "Measuring"
        if !complete {
            cause = "Waiting for a complete reading"
            evidence = "Some process metrics are missing or older than 15 seconds. They are excluded from growth detection."
            recommendation = "Let the next scan confirm the resource use before deciding."
            systemImage = "clock"
        } else if family.hasCredibleLeak, family.trend.hasSustainedHistory {
            let velocity = max(family.trend.credibleMemoryVelocity, family.longTermTrend.slopeMegabytesPerMinute)
            cause = "Sustained memory growth"
            evidence = "\(memory) in use; growing \(RadarFormat.leak(velocity))."
            if let culprit = family.culprit, family.members.count > 1 {
                recommendation = "\(culprit.name) holds \(Int((culprit.share * 100).rounded()))% of the growth; stopping only it may be enough."
            } else {
                recommendation = "Inspect the growing member and its work before previewing a stop."
            }
            systemImage = "chart.line.uptrend.xyaxis"
        } else if family.totalCPUPercent >= 80 {
            cause = "CPU activity"
            evidence = "\(cpu) CPU across \(family.members.count) processes. 100% means one logical CPU."
            recommendation = "Check whether a build, task, or foreground app is doing expected work."
            systemImage = "cpu"
        } else if family.totalGPUPercent >= 40 {
            cause = "GPU activity"
            evidence = "\(gpu) reported GPU activity; \(memory) tracked memory."
            recommendation = "Inspect rendering or compute work. Hardware temperature is shown separately."
            systemImage = "square.stack.3d.up"
        } else if family.totalPhysicalFootprintBytes >= 512 * 1_048_576 {
            cause = "Memory footprint"
            evidence = "\(memory) tracked footprint, \(cpu) CPU. Size alone does not prove a leak."
            recommendation = "Review the largest member; stop only work you no longer need."
            systemImage = "memorychip"
        } else if family.score.level >= .watch {
            cause = "Activity to review"
            evidence = family.score.heat.evidence.first ?? "\(memory) memory and \(cpu) CPU in the current scan."
            recommendation = "Review current measurements and the process tree."
            systemImage = "waveform.path"
        } else {
            cause = "Within observed limits"
            evidence = "\(memory) memory and \(cpu) CPU. No confirmed resource problem."
            recommendation = "Keep running. No stop is suggested from these readings."
            systemImage = "checkmark.circle"
        }
    }
}
