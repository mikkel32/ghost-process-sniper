import Foundation

public struct SnapshotContentRevision: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public static let zero = SnapshotContentRevision(rawValue: 0)

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func compute(
        families: [ProcessFamily],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        duplicateClusters: [DuplicateProcessCluster] = []
    ) -> SnapshotContentRevision {
        var hasher = Hasher()
        hasher.combine(summary.statusText)
        hasher.combine(summary.level)
        hasher.combine(summary.familyCount)
        hasher.combine(summary.hotCount)
        hasher.combine(summary.leakingCount)
        hasher.combine(summary.suggestionCount)
        for family in families {
            hasher.combine(family.familyKey)
            hasher.combine(family.signatureVersion)
            hasher.combine(family.childCount)
            hasher.combine(family.isKillable)
            hasher.combine(metricBucket(for: family.totalPhysicalFootprintBytes, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(percentBucket(for: family.totalCPUPercent, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(percentBucket(for: family.totalGPUPercent, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(leakBucket(for: family.trend.memoryVelocityMegabytesPerMinute, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(family.score.level)
            hasher.combine(Int((family.score.heat.value / 2).rounded()))
            hasher.combine(family.hasRecentMeasurements(at: family.lastScoredAt ?? family.root.sampledAt))
            hasher.combine(family.trend.hasSustainedHistory)
            hasher.combine(Int(family.score.value.rounded()))
            hasher.combine(family.hardwareSignals.map(\.reason))
            hasher.combine(family.forecast.state)
            hasher.combine(Int((family.forecast.confidence * 100).rounded()))
            hasher.combine(family.alertState.kind)
            hasher.combine(family.suggestions.count)
            hasher.combine(family.protectedPIDs)
        }
        for incident in incidents {
            hasher.combine(incident.id)
            hasher.combine(incident.level)
            hasher.combine(incident.resolvedAt)
            hasher.combine(incident.occurrenceCount)
            hasher.combine(Int(incident.maxScore.rounded()))
        }
        for rule in rules {
            hasher.combine(rule.id)
            hasher.combine(rule.isEnabled)
            hasher.combine(rule.action.rawValue)
            hasher.combine(rule.expiresAt)
        }
        for cluster in duplicateClusters where !cluster.isInternalToSingleFamily {
            hasher.combine(cluster.id)
            hasher.combine(cluster.memberCount)
            hasher.combine(cluster.independentRootCount)
            hasher.combine(metricBucket(for: cluster.totalPhysicalFootprintBytes, level: .watch, forecast: .quiet))
            hasher.combine(percentBucket(for: cluster.totalCPUPercent, level: .watch, forecast: .quiet))
            hasher.combine(cluster.representativePIDs)
            hasher.combine(cluster.relatedFamilyKeys)
        }
        return SnapshotContentRevision(rawValue: UInt64(bitPattern: Int64(hasher.finalize())))
    }

    private static func metricBucket(for bytes: UInt64, level: GhostLevel, forecast: ForecastState) -> UInt64 {
        let hot = level >= .hot || forecast >= .leaking
        let bucketSize: UInt64 = hot ? 4 * 1_048_576 : 32 * 1_048_576
        return bytes / bucketSize
    }

    private static func percentBucket(for percent: Double, level: GhostLevel, forecast: ForecastState) -> Int {
        let hot = level >= .hot || forecast >= .leaking
        let bucketSize = hot ? 1.0 : 5.0
        return Int((percent / bucketSize).rounded(.down))
    }

    private static func leakBucket(for megabytesPerMinute: Double, level: GhostLevel, forecast: ForecastState) -> Int {
        let hot = level >= .hot || forecast >= .leaking
        let bucketSize = hot ? 5.0 : 20.0
        return Int((megabytesPerMinute / bucketSize).rounded(.down))
    }
}

