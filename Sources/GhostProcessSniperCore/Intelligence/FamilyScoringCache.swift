import Foundation

public struct FamilyScoringCache: Sendable {
    private struct Entry: Sendable {
        var fingerprint: UInt64
        var family: ProcessFamily
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func cachedFamily(for family: ProcessFamily, context: RadarContext) -> ProcessFamily? {
        let fingerprint = Self.fingerprint(family: family, context: context)
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

    public mutating func store(_ family: ProcessFamily, context: RadarContext) {
        entries[family.familyKey] = Entry(
            fingerprint: Self.fingerprint(family: family, context: context),
            family: family
        )
    }

    public mutating func prune(keeping signatureIDs: Set<String>) {
        entries = entries.filter { signatureIDs.contains($0.key) }
    }

    public static func fingerprint(family: ProcessFamily, context: RadarContext) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(context.systemPressure.level)
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
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
