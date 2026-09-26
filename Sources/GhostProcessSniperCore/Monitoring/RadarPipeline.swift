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
    private var history = RadarHistory()
    private var differ = RadarSnapshotDiffer()
    private var hysteresis = RadarHysteresis()
    private var continuity = RadarContinuity()
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
            history: &history,
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
        let enriched = FamilyPriorityOrder.sorted(families.map { family in
            if let cached = scoringCache.cachedFamily(for: family, context: context, now: now) {
                return cached
            }
            let scored = intelligence.enrich(family: family, context: context, settings: settings, now: now)
            scoringCache.store(scored, from: family, context: context, now: now)
            return scored
        })
        let versioned = enriched.map { versionedFamily($0, diff: diff, now: now) }
        let stable = continuity.apply(to: hysteresis.apply(to: versioned, now: now))
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

/// Holds a Hot or Critical level until the family has read lower for
/// `holdDuration`, then steps down one level at a time, each step held too,
/// so a family oscillating around a threshold does not flap.
struct RadarHysteresis: Sendable {
    private struct Held: Sendable {
        var level: GhostLevel
        /// When the current step started; nil when the level is not held.
        var stepStartedAt: Date?
    }

    private var held: [String: Held] = [:]
    private let holdDuration: TimeInterval = 20

    mutating func apply(to families: [ProcessFamily], now: Date) -> [ProcessFamily] {
        if held.count > families.count + 64 {
            let activeKeys = Set(families.map(\.familyKey))
            held = held.filter { activeKeys.contains($0.key) }
        }
        return families.map { family in
            let key = family.familyKey
            let incoming = family.score.level
            // A muted or unmeasurable family drops at once: the hold is for
            // measured flicker, not for overriding the user or stale data.
            let suppressed = family.alertState.kind == .ignored || family.alertState.kind == .snoozed ||
                !family.coverage.isScorable
            guard let previous = held[key], !suppressed, incoming < previous.level,
                  previous.level >= .hot || previous.stepStartedAt != nil
            else {
                held[key] = Held(level: incoming, stepStartedAt: nil)
                return family
            }

            var step = previous
            let startedAt = previous.stepStartedAt ?? now
            step.stepStartedAt = startedAt
            if now.timeIntervalSince(startedAt) >= holdDuration {
                let lower = GhostLevel(rawValue: previous.level.rawValue - 1) ?? incoming
                step = Held(level: max(incoming, lower), stepStartedAt: now)
            }
            if step.level <= incoming {
                held[key] = Held(level: incoming, stepStartedAt: nil)
                return family
            }
            held[key] = step

            let score = GhostScore(
                value: family.score.value,
                level: step.level,
                reasons: family.score.reasons + ["held briefly to avoid flicker"],
                components: family.score.components,
                heat: family.score.heat.replacing(level: step.level)
            )
            return family.enriched(score: score)
        }
    }
}
