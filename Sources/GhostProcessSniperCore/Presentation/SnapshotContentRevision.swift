import Foundation

public struct SnapshotContentRevision: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public static let zero = SnapshotContentRevision(rawValue: 0)

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The revision of these inputs alone, with no displayed snapshot to
    /// hold their measured values against.
    public static func compute(
        families: [ProcessFamily],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        duplicateClusters: [DuplicateProcessCluster] = []
    ) -> SnapshotContentRevision {
        SnapshotContentBaseline.measure(
            families: families, summary: summary, incidents: incidents, rules: rules,
            duplicateClusters: duplicateClusters, previous: nil
        ).revision
    }
}

/// What a snapshot's revision was measured from. Discrete facts (keys,
/// levels, states, counts) are hashed exactly and in no particular order:
/// families arrive ranked by continuous heat, so CPU noise reorders them.
/// A measured value moves the revision only once it drifts a tolerance
/// away from the value the displayed snapshot shows, so ordinary noise
/// neither rebuilds the snapshot nor redraws its readers.
struct SnapshotContentBaseline: Equatable, Sendable {
    let revision: SnapshotContentRevision
    private let discrete: Int
    private let families: [String: FamilyGauges]
    private let clusters: [String: ClusterGauges]
    private let incidentScores: [UUID: Double]

    static func measure(
        families: [ProcessFamily],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        duplicateClusters: [DuplicateProcessCluster],
        previous: SnapshotContentBaseline?
    ) -> SnapshotContentBaseline {
        var hasher = Hasher()
        hasher.combine(summary.statusText)
        hasher.combine(summary.level)
        hasher.combine(summary.familyCount)
        hasher.combine(summary.hotCount)
        hasher.combine(summary.leakingCount)
        hasher.combine(summary.suggestionCount)

        var familyGauges: [String: FamilyGauges] = [:]
        familyGauges.reserveCapacity(families.count)
        var familySum = 0
        for family in families {
            var facts = Hasher()
            facts.combine(family.familyKey)
            facts.combine(family.signatureVersion)
            facts.combine(family.childCount)
            facts.combine(family.isKillable)
            facts.combine(family.score.level)
            facts.combine(family.hasRecentMeasurements(at: family.lastScoredAt ?? family.root.sampledAt))
            facts.combine(family.trend.hasSustainedHistory)
            // Slow growth or a new duplicate moves no gauge by a tolerance,
            // yet ends "big and nothing else", which the verdict names or not.
            facts.combine(family.isWatchedForSizeOnly)
            // Which pressures a family causes, not how many members cross
            // which step: members near a threshold flap between levels.
            facts.combine(Set(family.hardwareSignals.map(\.kind)))
            facts.combine(family.forecast.state)
            facts.combine(family.alertState.kind)
            facts.combine(family.protectedPIDs)
            familySum &+= facts.finalize()
            familyGauges[family.familyKey] = FamilyGauges(family)
        }
        hasher.combine(families.count)
        hasher.combine(familySum)

        var incidentScores: [UUID: Double] = [:]
        for incident in incidents {
            hasher.combine(incident.id)
            hasher.combine(incident.level)
            hasher.combine(incident.resolvedAt)
            hasher.combine(incident.occurrenceCount)
            incidentScores[incident.id] = incident.maxScore
        }
        for rule in rules {
            hasher.combine(rule.id)
            hasher.combine(rule.isEnabled)
            hasher.combine(rule.action.rawValue)
            hasher.combine(rule.expiresAt)
        }

        var clusterGauges: [String: ClusterGauges] = [:]
        var clusterSum = 0
        for cluster in duplicateClusters where !cluster.isInternalToSingleFamily {
            var facts = Hasher()
            facts.combine(cluster.id)
            facts.combine(cluster.memberCount)
            facts.combine(cluster.independentRootCount)
            // Crossing the listing floor adds or drops a row, however little
            // the memory or CPU behind it moved.
            facts.combine(cluster.addsUp)
            facts.combine(cluster.representativePIDs)
            facts.combine(cluster.relatedFamilyKeys)
            clusterSum &+= facts.finalize()
            clusterGauges[cluster.id] = ClusterGauges(cluster)
        }
        hasher.combine(clusterGauges.count)
        hasher.combine(clusterSum)
        let discrete = hasher.finalize()

        if let previous, previous.discrete == discrete,
           previous.holds(familyGauges, clusterGauges, incidentScores) {
            return previous
        }
        // A change re-anchors every value. Values are hashed in buckets no
        // wider than their tolerance, so one that drifted a full tolerance
        // lands in a new bucket and the revision cannot repeat the last one.
        var gaugeSum = 0
        for (key, gauges) in familyGauges {
            var bucket = Hasher()
            bucket.combine(key)
            gauges.combineBuckets(into: &bucket)
            gaugeSum &+= bucket.finalize()
        }
        for (key, gauges) in clusterGauges {
            var bucket = Hasher()
            bucket.combine(key)
            gauges.combineBuckets(into: &bucket)
            gaugeSum &+= bucket.finalize()
        }
        for (id, score) in incidentScores {
            var bucket = Hasher()
            bucket.combine(id)
            bucket.combine(Tolerance.bucket(score, width: Tolerance.incidentScore))
            gaugeSum &+= bucket.finalize()
        }
        var revision = Hasher()
        revision.combine(discrete)
        revision.combine(gaugeSum)
        return SnapshotContentBaseline(
            revision: SnapshotContentRevision(rawValue: UInt64(bitPattern: Int64(revision.finalize()))),
            discrete: discrete,
            families: familyGauges,
            clusters: clusterGauges,
            incidentScores: incidentScores
        )
    }

    /// True while every value sits within tolerance of the one displayed.
    /// The discrete hash already pinned the key sets.
    private func holds(
        _ families: [String: FamilyGauges],
        _ clusters: [String: ClusterGauges],
        _ incidentScores: [UUID: Double]
    ) -> Bool {
        for (key, gauges) in families {
            guard let shown = self.families[key], gauges.isNear(shown) else { return false }
        }
        for (key, gauges) in clusters {
            guard let shown = self.clusters[key], gauges.isNear(shown) else { return false }
        }
        for (id, score) in incidentScores {
            guard let shown = self.incidentScores[id],
                  abs(score - shown) < Tolerance.incidentScore else { return false }
        }
        return true
    }
}

/// Hot families (and credible leaks) are watched closely; the rest move
/// the revision only on changes a reader would notice.
private enum Tolerance {
    static let incidentScore = 5.0

    /// A tenth of a core: busy members add up their noise, so a family's
    /// CPU swings by a few points every sample even when nothing changed.
    static let percent = 10.0

    static func memory(hot: Bool) -> Double { (hot ? 4 : 32) * 1_048_576 }
    static func leak(hot: Bool) -> Double { hot ? 5 : 20 }
    static func heat(hot: Bool) -> Double { hot ? 4 : 10 }
    static func score(hot: Bool) -> Double { hot ? 4 : 10 }
    static func confidence(hot: Bool) -> Double { hot ? 0.05 : 0.1 }

    /// Or a tenth of the value, whichever is larger: 300% against 320% is
    /// not news either.
    static func percent(around shown: Double) -> Double {
        max(percent, shown * 0.1)
    }

    static func bucket(_ value: Double, width: Double) -> Int {
        Int((value / width).rounded(.down))
    }
}

private struct FamilyGauges: Equatable, Sendable {
    let isHot: Bool
    let footprintBytes: Double
    let cpuPercent: Double
    let gpuPercent: Double
    let leakRate: Double
    let heat: Double
    let score: Double
    let forecastConfidence: Double

    init(_ family: ProcessFamily) {
        isHot = family.score.level >= .hot || family.forecast.state >= .leaking
        footprintBytes = Double(family.totalPhysicalFootprintBytes)
        cpuPercent = family.totalCPUPercent
        gpuPercent = family.totalGPUPercent
        leakRate = family.trend.memoryVelocityMegabytesPerMinute
        heat = family.score.heat.value
        score = family.score.value
        forecastConfidence = family.forecast.confidence
    }

    /// Level and forecast state are discrete facts, so both sides share `isHot`.
    func isNear(_ shown: FamilyGauges) -> Bool {
        abs(footprintBytes - shown.footprintBytes) < Tolerance.memory(hot: isHot) &&
            abs(cpuPercent - shown.cpuPercent) < Tolerance.percent(around: shown.cpuPercent) &&
            abs(gpuPercent - shown.gpuPercent) < Tolerance.percent(around: shown.gpuPercent) &&
            abs(leakRate - shown.leakRate) < Tolerance.leak(hot: isHot) &&
            abs(heat - shown.heat) < Tolerance.heat(hot: isHot) &&
            abs(score - shown.score) < Tolerance.score(hot: isHot) &&
            abs(forecastConfidence - shown.forecastConfidence) < Tolerance.confidence(hot: isHot)
    }

    func combineBuckets(into hasher: inout Hasher) {
        hasher.combine(Tolerance.bucket(footprintBytes, width: Tolerance.memory(hot: isHot)))
        hasher.combine(Tolerance.bucket(cpuPercent, width: Tolerance.percent))
        hasher.combine(Tolerance.bucket(gpuPercent, width: Tolerance.percent))
        hasher.combine(Tolerance.bucket(leakRate, width: Tolerance.leak(hot: isHot)))
        hasher.combine(Tolerance.bucket(heat, width: Tolerance.heat(hot: isHot)))
        hasher.combine(Tolerance.bucket(score, width: Tolerance.score(hot: isHot)))
        hasher.combine(Tolerance.bucket(forecastConfidence, width: Tolerance.confidence(hot: isHot)))
    }
}

private struct ClusterGauges: Equatable, Sendable {
    let footprintBytes: Double
    let cpuPercent: Double

    init(_ cluster: DuplicateProcessCluster) {
        footprintBytes = Double(cluster.totalPhysicalFootprintBytes)
        cpuPercent = cluster.totalCPUPercent
    }

    func isNear(_ shown: ClusterGauges) -> Bool {
        abs(footprintBytes - shown.footprintBytes) < Tolerance.memory(hot: false) &&
            abs(cpuPercent - shown.cpuPercent) < Tolerance.percent(around: shown.cpuPercent)
    }

    func combineBuckets(into hasher: inout Hasher) {
        hasher.combine(Tolerance.bucket(footprintBytes, width: Tolerance.memory(hot: false)))
        hasher.combine(Tolerance.bucket(cpuPercent, width: Tolerance.percent))
    }
}
