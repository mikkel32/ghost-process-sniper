import Foundation

/// Identities whose coarse metrics changed since the previous tick, or that are new.
public struct RadarSnapshotDiff: Equatable, Sendable {
    public let changedOrAdded: Set<ProcessIdentity>

    public static let empty = RadarSnapshotDiff(changedOrAdded: [])
}

public struct RadarSnapshotDiffer: Sendable {
    private var previousFingerprints: [ProcessIdentity: UInt64] = [:]

    public init() {}

    public mutating func update(with processes: [ProcessMetrics]) -> RadarSnapshotDiff {
        var current: [ProcessIdentity: UInt64] = [:]
        var changedOrAdded = Set<ProcessIdentity>()
        current.reserveCapacity(processes.count)
        changedOrAdded.reserveCapacity(processes.count / 4)

        for process in processes {
            let identity = process.identity
            let currentFingerprint = fingerprint(process)
            current[identity] = currentFingerprint
            if previousFingerprints[identity] != currentFingerprint {
                changedOrAdded.insert(identity)
            }
        }

        previousFingerprints = current
        return RadarSnapshotDiff(changedOrAdded: changedOrAdded)
    }

    private func fingerprint(_ process: ProcessMetrics) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(process.parentPID)
        hasher.combine(process.userID)
        hasher.combine(process.residentMemoryBytes / 4_194_304)
        hasher.combine(process.physicalFootprintBytes / 4_194_304)
        hasher.combine(Int(process.cpuPercent.rounded()))
        hasher.combine(process.threadCount)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

public struct RadarPipelineOutput: Sendable {
    public let families: [ProcessFamily]
    public let duplicateClusters: [DuplicateProcessCluster]
    public let summary: RadarSummary
    public let diff: RadarSnapshotDiff
    public let buildMilliseconds: Double
    public let scoreMilliseconds: Double
    public let duplicateDetectorMilliseconds: Double
    public let promotedDuplicateCandidateCount: Int
    public let hardwareOffenderCount: Int
    public let hardwareDetectorMilliseconds: Double
}

public struct RadarPipelineBuildOutput: Sendable {
    public let families: [ProcessFamily]
    public let duplicateClusters: [DuplicateProcessCluster]
    public let diff: RadarSnapshotDiff
    public let buildMilliseconds: Double
    public let duplicateDetectorMilliseconds: Double
    public let promotedDuplicateCandidateCount: Int
    public let hardwareOffenderCount: Int
    public let hardwareDetectorMilliseconds: Double
}

public struct RadarPipeline: Sendable {
    private let builder: ProcessFamilyBuilder
    private let intelligence: RadarIntelligence
    private var trendWindow = TrendWindow()
    private var differ = RadarSnapshotDiffer()
    private var hysteresis = RadarHysteresis()
    private var metricsVersions: [String: UInt64] = [:]
    private var signatureVersions: [String: UInt64] = [:]
    private var scoringCache = FamilyScoringCache()

    public init(
        builder: ProcessFamilyBuilder = ProcessFamilyBuilder(),
        intelligence: RadarIntelligence = RadarIntelligence()
    ) {
        self.builder = builder
        self.intelligence = intelligence
    }

    public mutating func run(
        processes: [ProcessMetrics],
        settings: ThresholdSettings,
        context: RadarContext,
        now: Date
    ) -> RadarPipelineOutput {
        let build = buildCandidates(processes: processes, settings: settings, now: now)
        let scored = score(families: build.families, diff: build.diff, context: context, settings: settings, now: now)
        return RadarPipelineOutput(
            families: scored.families,
            duplicateClusters: build.duplicateClusters,
            summary: builder.summary(for: scored.families),
            diff: build.diff,
            buildMilliseconds: build.buildMilliseconds,
            scoreMilliseconds: scored.scoreMilliseconds,
            duplicateDetectorMilliseconds: build.duplicateDetectorMilliseconds,
            promotedDuplicateCandidateCount: build.promotedDuplicateCandidateCount,
            hardwareOffenderCount: build.hardwareOffenderCount,
            hardwareDetectorMilliseconds: build.hardwareDetectorMilliseconds
        )
    }

    public func summary(for families: [ProcessFamily]) -> RadarSummary {
        builder.summary(for: families)
    }

    public mutating func buildCandidates(
        processes: [ProcessMetrics],
        settings: ThresholdSettings,
        now: Date
    ) -> RadarPipelineBuildOutput {
        let buildStart = Date()
        let diff = differ.update(with: processes)
        let familyBuild = builder.buildFamiliesWithDuplicates(
            from: processes,
            settings: settings,
            trendWindow: &trendWindow,
            now: now
        )
        return RadarPipelineBuildOutput(
            families: familyBuild.families,
            duplicateClusters: familyBuild.duplicateClusters,
            diff: diff,
            buildMilliseconds: Date().timeIntervalSince(buildStart) * 1_000,
            duplicateDetectorMilliseconds: familyBuild.duplicateDetectorMilliseconds,
            promotedDuplicateCandidateCount: familyBuild.promotedDuplicateCandidateCount,
            hardwareOffenderCount: familyBuild.hardwareOffenderCount,
            hardwareDetectorMilliseconds: familyBuild.hardwareDetectorMilliseconds
        )
    }

    public mutating func score(
        families: [ProcessFamily],
        diff: RadarSnapshotDiff,
        context: RadarContext,
        settings: ThresholdSettings,
        now: Date
    ) -> (families: [ProcessFamily], scoreMilliseconds: Double) {
        let scoreStart = Date()
        let familyKeys = Set(families.map(\.familyKey))
        scoringCache.prune(keeping: familyKeys)
        if metricsVersions.count > familyKeys.count + 64 {
            metricsVersions = metricsVersions.filter { familyKeys.contains($0.key) }
        }
        let enriched = families.map { family in
            if let cached = scoringCache.cachedFamily(for: family, context: context, now: now) {
                return cached
            }
            let scored = intelligence.enrich(family: family, context: context, settings: settings, now: now)
            scoringCache.store(scored, from: family, context: context, now: now)
            return scored
        }
        .sorted(by: FamilyPriorityOrder.areInIncreasingOrder)
        let versioned = enriched.map { versionedFamily($0, diff: diff, now: now) }
        let stable = hysteresis.apply(to: versioned, now: now)
        return (stable, Date().timeIntervalSince(scoreStart) * 1_000)
    }

    private mutating func versionedFamily(_ family: ProcessFamily, diff: RadarSnapshotDiff, now: Date) -> ProcessFamily {
        let signatureID = family.signature.id
        let familyKey = family.familyKey
        let hasMetricChange = family.members.contains { diff.changedOrAdded.contains($0.identity) }
        if hasMetricChange {
            metricsVersions[familyKey, default: 0] += 1
        }
        if signatureVersions[signatureID] == nil {
            signatureVersions[signatureID] = 1
        }

        let freshness = family.members
            .compactMap { member -> Date? in
                member.forensics.isPartial ? nil : member.sampledAt
            }
            .max()

        return family.enriched(
            signatureVersion: signatureVersions[signatureID, default: 1],
            metricsVersion: metricsVersions[familyKey, default: 0],
            forensicsFreshness: freshness,
            lastScoredAt: now
        )
    }
}

struct RadarHysteresis: Sendable {
    private var levels: [String: (level: GhostLevel, updatedAt: Date)] = [:]
    private let holdDuration: TimeInterval = 20

    mutating func apply(to families: [ProcessFamily], now: Date) -> [ProcessFamily] {
        if levels.count > families.count + 64 {
            let activeKeys = Set(families.map(\.familyKey))
            levels = levels.filter { activeKeys.contains($0.key) }
        }
        return families.map { family in
            let key = family.familyKey
            guard let previous = levels[key] else {
                levels[key] = (family.score.level, now)
                return family
            }

            var level = family.score.level
            if previous.level >= .hot,
               family.score.level < .hot,
               now.timeIntervalSince(previous.updatedAt) < holdDuration {
                level = max(family.score.level, .watch)
            }

            if level != previous.level || now.timeIntervalSince(previous.updatedAt) >= holdDuration {
                levels[key] = (level, now)
            }

            guard level != family.score.level else {
                return family
            }

            let score = GhostScore(
                value: family.score.value,
                level: level,
                reasons: family.score.reasons + ["held briefly to avoid flicker"],
                components: family.score.components,
                heat: family.score.heat.replacing(level: level)
            )
            return family.enriched(score: score)
        }
    }
}
