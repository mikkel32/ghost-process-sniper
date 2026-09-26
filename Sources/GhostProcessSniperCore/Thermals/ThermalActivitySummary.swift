import Foundation

public struct ThermalContributor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let familyKey: String
    public let cpuPercent: Double
    public let gpuPercent: Double
    public let processCount: Int
    public let measuredAt: Date
    public let applicationPath: String?
    public let canInspectFamily: Bool
    public let isSystemProcess: Bool
    public let cpuCapacityPercent: Double
    public let cpuMeasuredAt: Date?
    public let gpuMeasuredAt: Date?
    public let cpuMeasuredProcessCount: Int
    public let gpuMeasuredProcessCount: Int
    public let processes: [ThermalProcessEvidence]
}

/// A small value snapshot for the UI. Activity is evidence, not per-app heat.
public struct ThermalActivitySummary: Equatable, Sendable {
    public static let maximumAge: TimeInterval = 12
    public static let empty = ThermalActivitySummary(
        sampledAt: .distantPast, contributors: [], observedProcessCount: 0, unavailableProcessCount: 0
    )

    public let sampledAt: Date
    public let contributors: [ThermalContributor]
    public let observedProcessCount: Int
    public let unavailableProcessCount: Int
    public let cpuObservedProcessCount: Int
    public let gpuObservedProcessCount: Int
    public let coverage: ThermalActivityCoverage
    public let recentContributors: [ThermalRecentContributor]
    public let historySampleCount: Int
    public let historySpanSeconds: TimeInterval
    private let measuredContributors: [ThermalContributor]
    private let cpuContributors: [ThermalContributor]
    private let gpuContributors: [ThermalContributor]

    public init(sampledAt: Date, contributors: [ThermalContributor], observedProcessCount: Int,
                unavailableProcessCount: Int, coverage: ThermalActivityCoverage = .processInventory,
                cpuObservedProcessCount: Int = 0, gpuObservedProcessCount: Int = 0,
                recentContributors: [ThermalRecentContributor] = [], historySampleCount: Int = 0,
                historySpanSeconds: TimeInterval = 0,
                measuredContributors: [ThermalContributor]? = nil) {
        self.sampledAt = sampledAt
        self.contributors = contributors
        self.observedProcessCount = observedProcessCount
        self.unavailableProcessCount = unavailableProcessCount
        self.cpuObservedProcessCount = cpuObservedProcessCount
        self.gpuObservedProcessCount = gpuObservedProcessCount
        self.coverage = coverage
        self.recentContributors = recentContributors
        self.historySampleCount = historySampleCount
        self.historySpanSeconds = historySpanSeconds
        self.measuredContributors = measuredContributors ?? contributors
        // Prepare alternate orderings on the worker, never inside a SwiftUI row.
        cpuContributors = contributors.sorted {
            $0.cpuPercent == $1.cpuPercent ? $0.id < $1.id : $0.cpuPercent > $1.cpuPercent
        }
        gpuContributors = contributors.sorted {
            $0.gpuPercent == $1.gpuPercent ? $0.id < $1.id : $0.gpuPercent > $1.gpuPercent
        }
    }

    public func visibleContributors(at now: Date, sort: ThermalActivitySort = .activity) -> [ThermalContributor] {
        let ordered = switch sort {
        case .activity: contributors
        case .cpu: cpuContributors
        case .gpu: gpuContributors
        }
        let visible = ordered.filter { $0.observedActivity(at: now) != nil }
        // Precomputed order is correct until one resource expires before another.
        // Re-rank only at that boundary so a stale CPU value cannot lead a GPU-only row.
        let hasExpiredResource = visible.contains {
            ($0.cpuMeasuredAt != nil && $0.cpuCapacityPercent(at: now) == nil) ||
                ($0.gpuMeasuredAt != nil && $0.gpuActivityPercent(at: now) == nil)
        }
        guard hasExpiredResource else { return visible }
        return visible.sorted { lhs, rhs in
            let left: Double
            let right: Double
            switch sort {
            case .activity:
                left = lhs.observedActivity(at: now) ?? 0
                right = rhs.observedActivity(at: now) ?? 0
            case .cpu:
                left = lhs.cpuCapacityPercent(at: now) ?? 0
                right = rhs.cpuCapacityPercent(at: now) ?? 0
            case .gpu:
                left = lhs.gpuActivityPercent(at: now) ?? 0
                right = rhs.gpuActivityPercent(at: now) ?? 0
            }
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    /// Includes quiet measured apps for a user-started before/after comparison.
    /// Quiet apps remain hidden from the normal contributor ranking.
    public func measuredContributor(id: String, at now: Date) -> ThermalContributor? {
        measuredContributors.first {
            $0.id == id && (0...Self.maximumAge).contains(now.timeIntervalSince($0.measuredAt))
        }
    }

    /// The most recent app that was busy before this scan and is quiet or unmeasured now.
    public func earlierContributor(at now: Date) -> ThermalRecentContributor? {
        recentContributors.first {
            $0.lastActiveAt < sampledAt &&
                (0...ThermalActivityHistory.maximumAge).contains(now.timeIntervalSince($0.lastActiveAt))
        }
    }

    func includingHistory(_ recent: [ThermalRecentContributor], sampleCount: Int,
                          spanSeconds: TimeInterval) -> Self {
        Self(sampledAt: sampledAt, contributors: contributors, observedProcessCount: observedProcessCount,
             unavailableProcessCount: unavailableProcessCount, coverage: coverage,
             cpuObservedProcessCount: cpuObservedProcessCount, gpuObservedProcessCount: gpuObservedProcessCount,
             recentContributors: recent, historySampleCount: sampleCount, historySpanSeconds: spanSeconds,
             measuredContributors: measuredContributors)
    }

    static func build(
        samples: [ThermalActivitySample],
        now: Date,
        processorCount: Int,
        coverage: ThermalActivityCoverage = .processInventory
    ) -> ThermalActivitySummary {
        var unique: [ProcessIdentity: ThermalActivitySample] = [:]
        for sample in samples {
            if let prior = unique[sample.identity] {
                let oldDate = max(prior.measuredAt ?? .distantPast, prior.gpuMeasuredAt ?? .distantPast)
                let newDate = max(sample.measuredAt ?? .distantPast, sample.gpuMeasuredAt ?? .distantPast)
                if newDate < oldDate || (newDate == oldDate && sample.familyKey >= prior.familyKey) {
                    continue
                }
            }
            unique[sample.identity] = sample
        }

        var groups: [String: Accumulator] = [:]
        var unavailable = 0
        var cpuObserved = 0
        var gpuObserved = 0
        // Identity ordering makes sums and representative-family choices stable.
        let ordered = unique.values.sorted {
            if $0.identity.pid != $1.identity.pid { return $0.identity.pid < $1.identity.pid }
            if $0.identity.startTimeSeconds != $1.identity.startTimeSeconds {
                return $0.identity.startTimeSeconds < $1.identity.startTimeSeconds
            }
            return $0.identity.startTimeMicroseconds < $1.identity.startTimeMicroseconds
        }
        for sample in ordered {
            let cpuDate = validDate(sample.measuredAt, at: now, value: sample.cpuPercent)
            let gpuDate = validDate(sample.gpuMeasuredAt, at: now, value: sample.gpuPercent)
            guard cpuDate != nil || gpuDate != nil else {
                unavailable += 1
                continue
            }
            if cpuDate != nil { cpuObserved += 1 }
            if gpuDate != nil { gpuObserved += 1 }
            let measuredAt = max(cpuDate ?? .distantPast, gpuDate ?? .distantPast)
            let appPath = applicationPath(sample.executablePath)
            let key = appPath ?? sample.familyKey
            let name = appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? sample.name
            var group = groups[key] ?? Accumulator(name: name, applicationPath: appPath,
                familyKey: sample.familyKey, canInspectFamily: sample.canInspectFamily, measuredAt: measuredAt)
            group.cpu += cpuDate == nil ? 0 : sample.cpuPercent
            group.gpu += gpuDate == nil ? 0 : sample.gpuPercent
            group.count += 1
            group.isSystemProcess = group.isSystemProcess && sample.isSystemProcess
            group.measuredAt = max(group.measuredAt, measuredAt)
            if let cpuDate {
                group.cpuMeasuredAt = min(group.cpuMeasuredAt ?? cpuDate, cpuDate)
                group.cpuMeasuredProcessCount += 1
            }
            if let gpuDate {
                group.gpuMeasuredAt = min(group.gpuMeasuredAt ?? gpuDate, gpuDate)
                group.gpuMeasuredProcessCount += 1
            }
            let activity = max((cpuDate == nil ? 0 : sample.cpuPercent) / Double(max(1, processorCount)),
                               gpuDate == nil ? 0 : sample.gpuPercent)
            if (sample.canInspectFamily && !group.canInspectFamily) ||
                (sample.canInspectFamily == group.canInspectFamily &&
                    (activity > group.representativeActivity ||
                     (activity == group.representativeActivity && sample.familyKey < group.familyKey))) {
                group.familyKey = sample.familyKey
                group.canInspectFamily = sample.canInspectFamily
                group.representativeActivity = activity
            }
            let evidence = ThermalProcessEvidence(identity: sample.identity, name: sample.name,
                cpuPercent: cpuDate == nil ? 0 : sample.cpuPercent,
                gpuPercent: gpuDate == nil ? 0 : sample.gpuPercent, measuredAt: measuredAt,
                cpuMeasuredAt: cpuDate, gpuMeasuredAt: gpuDate)
            let index = group.processes.firstIndex {
                activity > max($0.cpuPercent / Double(max(1, processorCount)), $0.gpuPercent)
            } ?? group.processes.endIndex
            if index < 6 {
                group.processes.insert(evidence, at: index)
                if group.processes.count > 6 { group.processes.removeLast() }
            }
            groups[key] = group
        }
        let allContributors = groups.compactMap { key, group -> ThermalContributor? in
            guard group.cpu.isFinite, group.gpu.isFinite else { return nil }
            return ThermalContributor(id: key, displayName: group.name, familyKey: group.familyKey,
                cpuPercent: group.cpu, gpuPercent: group.gpu, processCount: group.count, measuredAt: group.measuredAt,
                applicationPath: group.applicationPath, canInspectFamily: group.canInspectFamily,
                isSystemProcess: group.isSystemProcess, cpuCapacityPercent: group.cpu / Double(max(1, processorCount)),
                cpuMeasuredAt: group.cpuMeasuredAt, gpuMeasuredAt: group.gpuMeasuredAt,
                cpuMeasuredProcessCount: group.cpuMeasuredProcessCount,
                gpuMeasuredProcessCount: group.gpuMeasuredProcessCount,
                processes: group.processes)
        }.sorted { $0.id < $1.id }
        let contributors = allContributors.filter { $0.cpuPercent >= 5 || $0.gpuPercent >= 5 }.sorted { lhs, rhs in
            // Compare the busier resource, never fabricate a percentage of heat.
            let left = max(lhs.cpuPercent / Double(max(1, processorCount)), lhs.gpuPercent)
            let right = max(rhs.cpuPercent / Double(max(1, processorCount)), rhs.gpuPercent)
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        return ThermalActivitySummary(sampledAt: now, contributors: contributors,
            observedProcessCount: unique.count, unavailableProcessCount: unavailable, coverage: coverage,
            cpuObservedProcessCount: cpuObserved, gpuObservedProcessCount: gpuObserved,
            measuredContributors: allContributors)
    }

    private static func validDate(_ measuredAt: Date?, at now: Date, value: Double) -> Date? {
        guard let measuredAt, value.isFinite, value >= 0,
              (0...maximumAge).contains(now.timeIntervalSince(measuredAt)) else { return nil }
        return measuredAt
    }

    private static func applicationPath(_ executable: String) -> String? {
        guard let range = executable.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(executable[..<executable.index(before: range.upperBound)])
    }

    private struct Accumulator {
        let name: String
        let applicationPath: String?
        var familyKey: String
        var canInspectFamily: Bool
        var measuredAt: Date
        var cpu = 0.0
        var gpu = 0.0
        var count = 0
        var representativeActivity = -1.0
        var isSystemProcess = true
        var cpuMeasuredAt: Date?
        var gpuMeasuredAt: Date?
        var cpuMeasuredProcessCount = 0
        var gpuMeasuredProcessCount = 0
        var processes: [ThermalProcessEvidence] = []
    }
}

struct ThermalActivitySample: Sendable {
    let identity: ProcessIdentity
    let familyKey: String
    let name: String
    let executablePath: String
    let cpuPercent: Double
    let gpuPercent: Double
    let measuredAt: Date?
    var gpuMeasuredAt: Date? = nil
    var canInspectFamily: Bool = true
    var isSystemProcess: Bool = false
}
