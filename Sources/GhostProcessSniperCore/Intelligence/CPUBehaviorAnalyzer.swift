import Foundation

/// What a family's CPU minutes say about it.
public enum CPUBehaviorKind: String, Codable, Sendable {
    case none
    /// Build or test work, or a tree churning through short-lived children:
    /// heavy CPU that ends by itself.
    case expectedBurst
    /// One process pinned at one core, steadily, with no churn: a busy loop.
    case spin
    /// A service that is normally idle, burning CPU for minutes.
    case idleServiceBurning
    /// Most of every core on the Mac, for minutes.
    case machineSaturation
}

public struct CPUBehavior: Codable, Equatable, Sendable {
    public let kind: CPUBehaviorKind
    /// Minutes the behavior has held.
    public let minutes: Int
    /// Average cores busy over those minutes (1.0 = one core).
    public let averageCores: Double
    /// Average share of the whole Mac's CPU over those minutes.
    public let machineShare: Double
    /// Persistence proven by the ledger: counts as a sustained CPU signal.
    public let isSustained: Bool
    /// Bad enough, for long enough, to call the family runaway.
    public let isRunaway: Bool
    public let reason: String

    public static let none = CPUBehavior(kind: .none, minutes: 0, averageCores: 0, machineShare: 0,
                                         isSustained: false, isRunaway: false, reason: "")
}

/// Reads CPU behavior from the activity ledger's one-minute buckets, which
/// cover twenty minutes whatever the refresh cadence, and normalizes by the
/// Mac's core count.
public enum CPUBehaviorAnalyzer {
    /// A build becomes a runaway only after this long near its own level.
    static let burstRunawayMinutes = 15
    static let spinMinutes = 2
    static let idleServiceMinutes = 5
    static let saturationMinutes = 3
    static let sustainedMinutes = 2
    static let runawayMinutes = 5

    /// The limit a family's total CPU is judged against. The automatic
    /// profiles' limit is a share of one core per two cores, so a busy app
    /// using a few cores of a big Mac is not held to a small Mac's limit; a
    /// custom limit is exact. A single pegged core is the spin rule's job.
    public static func familyCPULimit(settings: ThresholdSettings, processorCount: Int) -> Double {
        let limit = max(settings.cpuPercent, 1)
        guard settings.detectionMode == .automatic else { return limit }
        return limit * max(1, Double(processorCount) / 2)
    }

    public static func analyze(
        activity: FamilyCPUActivity,
        classification: DevClassification?,
        memberCount: Int,
        baseline: FamilyBaseline?,
        processorCount: Int,
        cpuThreshold: Double
    ) -> CPUBehavior {
        let minutes = activity.recentMinutes
        let cores = Double(max(1, processorCount))
        let kind = classification?.kind
        let traits = classification?.traits ?? []

        if kind == .localModelRunner {
            return idleServiceBurning(minutes, baseline: baseline, cores: cores) ?? .none
        }
        let isService = kind.map { [.languageServer, .buildWatcher, .dataStore].contains($0) } ?? false ||
            traits.contains(.devServer)
        if isService, let burning = idleServiceBurning(minutes, baseline: baseline, cores: cores) {
            return burning
        }
        let isBuild = traits.contains(.buildOrTest) ||
            kind.map { [.swiftBuild, .testRunner, .buildWatcher].contains($0) } ?? false
        let churn = minutes.isEmpty ? 0 : Double(minutes.reduce(0) { $0 + $1.memberChanges }) / Double(minutes.count)
        if isBuild || churn >= 3 {
            return expectedBurst(minutes, cores: cores, cpuThreshold: cpuThreshold)
        }
        if let saturation = trailing(minutes, where: { $0.cores >= 0.6 * cores }), saturation.count >= saturationMinutes {
            let average = mean(saturation.map(\.cores))
            return CPUBehavior(kind: .machineSaturation, minutes: saturation.count, averageCores: average,
                               machineShare: average / cores, isSustained: true, isRunaway: false,
                               reason: "using \(Int((average / cores * 100).rounded()))% of this Mac's CPU for \(saturation.count) min")
        }
        if let spin = spin(minutes, memberCount: memberCount, cores: cores) {
            return spin
        }
        if let hot = trailing(minutes, where: { $0.cores * 100 >= cpuThreshold }), hot.count >= sustainedMinutes {
            let average = mean(hot.map(\.cores))
            return CPUBehavior(kind: .none, minutes: hot.count, averageCores: average, machineShare: average / cores,
                               isSustained: true, isRunaway: hot.count >= runawayMinutes,
                               reason: "CPU above its \(Int(cpuThreshold.rounded()))% limit for \(hot.count) min")
        }
        return .none
    }

    private static func expectedBurst(_ minutes: [CPUMinuteBucket], cores: Double, cpuThreshold: Double) -> CPUBehavior {
        guard let hot = trailing(minutes, where: { $0.cores * 100 >= cpuThreshold }) else {
            return CPUBehavior(kind: .expectedBurst, minutes: 0, averageCores: 0, machineShare: 0,
                               isSustained: false, isRunaway: false, reason: "build or test work")
        }
        let level = mean(hot.map(\.cores))
        // Runaway only once it has held near its own level for a long time,
        // not while a compile ramps up and down.
        let steady = trailing(hot, where: { $0.cores >= 0.8 * level })?.count ?? 0
        let runaway = steady >= burstRunawayMinutes
        return CPUBehavior(kind: .expectedBurst, minutes: hot.count, averageCores: level, machineShare: level / cores,
                           isSustained: runaway, isRunaway: runaway,
                           reason: runaway ? "build or test work has held \(Int((level * 100).rounded()))% CPU for \(steady) min"
                               : "build or test work at \(Int((level * 100).rounded()))% CPU")
    }

    private static func spin(_ minutes: [CPUMinuteBucket], memberCount: Int, cores: Double) -> CPUBehavior? {
        guard let run = trailing(minutes, where: { bucket in
            (0.85...1.05).contains(bucket.cores) && bucket.memberChanges == 0 &&
                (memberCount == 1 || bucket.dominantShare >= 0.9)
        }), run.count >= spinMinutes else {
            return nil
        }
        let values = run.map(\.cores)
        let average = mean(values)
        let deviation = (values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)).squareRoot()
        guard average > 0, deviation / average < 0.1 else { return nil }
        return CPUBehavior(kind: .spin, minutes: run.count, averageCores: average, machineShare: average / cores,
                           isSustained: true, isRunaway: true, reason: "busy-looping on one core for \(run.count) min")
    }

    private static func idleServiceBurning(_ minutes: [CPUMinuteBucket], baseline: FamilyBaseline?, cores: Double) -> CPUBehavior? {
        guard let baseline, baseline.isMeasurementTrusted, baseline.meanCPUPercent < 5,
              let run = trailing(minutes, where: { $0.cores >= 0.15 }), run.count >= idleServiceMinutes
        else {
            return nil
        }
        let average = mean(run.map(\.cores))
        guard average >= 0.25 else { return nil }
        return CPUBehavior(kind: .idleServiceBurning, minutes: run.count, averageCores: average, machineShare: average / cores,
                           isSustained: true, isRunaway: false,
                           reason: "burning \(Int((average * 100).rounded()))% CPU for \(run.count) min; it normally idles near " +
                               "\(RadarFormat.fixed1(baseline.meanCPUPercent))%")
    }

    /// The newest unbroken run of minutes matching `predicate`, oldest first.
    private static func trailing(_ minutes: [CPUMinuteBucket], where predicate: (CPUMinuteBucket) -> Bool) -> [CPUMinuteBucket]? {
        let run = Array(minutes.reversed().prefix { predicate($0) }.reversed())
        return run.isEmpty ? nil : run
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
