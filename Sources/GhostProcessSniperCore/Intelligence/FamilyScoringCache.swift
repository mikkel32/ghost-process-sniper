import Foundation

public struct FamilyScoringCache: Sendable {
    private struct Entry: Sendable {
        var fingerprint: UInt64
        var family: ProcessFamily
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func cachedFamily(for family: ProcessFamily, context: RadarContext, now: Date? = nil) -> ProcessFamily? {
        let fingerprint = Self.fingerprint(family: family, context: context, now: now)
        guard let entry = entries[family.familyKey], entry.fingerprint == fingerprint else {
            return nil
        }
        // Reuse derived judgments, never the old process readings or forensics.
        // A stable score must not freeze measurement timestamps and then make
        // a continuously sampled family appear stale.
        let cached = entry.family
        return family.enriched(
            score: cached.score,
            baseline: cached.baseline,
            suggestions: cached.suggestions,
            alertState: cached.alertState,
            recentIncidentCount: cached.recentIncidentCount,
            forecast: cached.forecast,
            lastScoredAt: cached.lastScoredAt == nil ? nil : family.root.sampledAt
        )
    }

    /// Pass the unscored `input` the lookup will see: enrichment changes the
    /// score, so fingerprinting the scored family would never hit again.
    public mutating func store(_ family: ProcessFamily, from input: ProcessFamily? = nil, context: RadarContext, now: Date? = nil) {
        entries[family.familyKey] = Entry(
            fingerprint: Self.fingerprint(family: input ?? family, context: context, now: now),
            family: family
        )
    }

    public mutating func prune(keeping familyKeys: Set<String>) {
        entries = entries.filter { familyKeys.contains($0.key) }
    }

    /// `now` defaults to the root's sample time.
    public static func fingerprint(family: ProcessFamily, context: RadarContext, now: Date? = nil) -> UInt64 {
        let now = now ?? family.root.sampledAt
        var hasher = Hasher()
        hasher.combine(context.systemPressure.level)
        if context.systemPressure.level >= .warning {
            let share = context.pressureShare(for: family)
            hasher.combine(Int((share.contribution * 20).rounded()))
            hasher.combine(share.corroboratesPressure)
        }
        // The host-wide ETA moves nearly every tick under pressure; only this
        // family's own time to critical pressure reaches its forecast.
        hasher.combine(context.hostOutlook != nil)
        if context.hostOutlook != nil {
            let growth = PressureAttribution.credibleGrowth(of: family, physicalMemoryBytes: context.systemPressure.totalBytes)
            hasher.combine(PressureAttribution.familyETASeconds(velocity: growth, pressure: context.systemPressure).map { Int($0 / 60) })
        }
        hasher.combine(family.signature.id)
        hasher.combine(family.members.map(\.identity))
        hasher.combine(family.coverage.isScorable)
        hasher.combine(family.trend.hasSustainedHistory)
        hasher.combine(min(4, family.trend.sampleCount))
        hasher.combine(Int((family.trend.memoryFitQuality * 10).rounded()))
        hasher.combine(family.totalPhysicalFootprintBytes / 4_194_304)
        hasher.combine(Int(family.totalCPUPercent.rounded()))
        hasher.combine(Int(family.totalGPUPercent.rounded()))
        hasher.combine(family.hardwareSignals.map(\.reason))
        hasher.combine(Int((family.forgottenAssessment.likelihood * 20).rounded()))
        hasher.combine(family.zombieChildCount)
        // CPU behavior and idleness are judged per ledger minute.
        hasher.combine(family.cpuActivity.buckets.last?.start)
        hasher.combine(family.cpuActivity.buckets.count)
        hasher.combine(Int(family.longTermTrend.slopeMegabytesPerMinute.rounded()))
        hasher.combine(family.culprit?.identity)
        if let cluster = family.duplicateCluster, cluster.countsAsIndependentCopies {
            hasher.combine(cluster.copyPlanHash)
        }
        hasher.combine(Int(family.trend.credibleMemoryVelocity.rounded()))
        hasher.combine(Int(family.root.sampledAt.timeIntervalSince1970 / 300))
        hasher.combine(family.score.value.rounded())
        if let baseline = context.baselines[family.signature.id] {
            hasher.combine(baseline.measurementVersion)
            hasher.combine(baseline.sampleCount)
            hasher.combine(Int(baseline.meanMemoryBytes.rounded()))
            hasher.combine(Int(baseline.memoryStandardDeviation / 16_777_216))
            hasher.combine(baseline.observedSeconds >= 1_200)
            hasher.combine(baseline.incidentCount)
        }
        hasher.combine(context.recentIncidentCounts[family.signature.id, default: 0])
        for rule in context.rules {
            hasher.combine(rule.id)
            hasher.combine(rule.isEnabled)
            hasher.combine(rule.action.rawValue)
            hasher.combine(rule.expiresAt?.timeIntervalSince1970 ?? 0)
            // An edited match or a snooze that just ran out must rescore now,
            // not when the five-minute bucket rolls over.
            hasher.combine(rule.match)
            hasher.combine(rule.expiresAt.map { $0 <= now })
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
