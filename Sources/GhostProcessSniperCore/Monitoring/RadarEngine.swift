import Foundation

public struct ProcessTelemetryCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let executablePath: String
        public let commandLine: String
        public let ownerName: String
        public let refreshedAt: Date
    }

    private var entries: [ProcessIdentity: Entry] = [:]

    public init() {}

    public func entry(for identity: ProcessIdentity) -> Entry? {
        entries[identity]
    }

    public mutating func update(_ entry: Entry, for identity: ProcessIdentity) {
        entries[identity] = entry
    }

    public mutating func prune(keeping identities: Set<ProcessIdentity>) {
        entries = entries.filter { identities.contains($0.key) }
    }
}

public struct ForensicsCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public let forensics: ProcessForensics
        public let refreshedAt: Date
    }

    private var entries: [ProcessIdentity: Entry] = [:]

    public init() {}

    public func entry(for identity: ProcessIdentity, now: Date, maxAge: TimeInterval) -> Entry? {
        guard let entry = entries[identity], now.timeIntervalSince(entry.refreshedAt) <= maxAge else {
            return nil
        }
        return entry
    }

    public func entry(for identity: ProcessIdentity) -> Entry? {
        entries[identity]
    }

    public func negativeEntry(for identity: ProcessIdentity, now: Date, maxAge: TimeInterval) -> Entry? {
        guard let entry = entries[identity],
              entry.forensics.isPartial,
              now.timeIntervalSince(entry.refreshedAt) <= maxAge
        else {
            return nil
        }
        return entry
    }

    public mutating func update(_ forensics: ProcessForensics, for identity: ProcessIdentity, at date: Date) {
        entries[identity] = Entry(forensics: forensics, refreshedAt: date)
    }

    public mutating func prune(keeping identities: Set<ProcessIdentity>) {
        entries = entries.filter { identities.contains($0.key) }
    }
}

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

public struct StoreHealth: Equatable, Sendable {
    public let backlogCount: Int
    public let pendingActionCount: Int
    public let lastFlushDate: Date?
    public let lastPruneDate: Date?
    public let lastFlushMilliseconds: Double
    public let lastContextMilliseconds: Double
    public let skippedSettingsWriteCount: Int
    public let coalescingStats: StoreCoalescingStats
    public let rulesCacheHitCount: Int
    public let errorMessage: String?
    public let lastKillOperationSummary: String?

    public static let empty = StoreHealth(
        backlogCount: 0,
        pendingActionCount: 0,
        lastFlushDate: nil,
        lastPruneDate: nil,
        lastFlushMilliseconds: 0,
        lastContextMilliseconds: 0,
        skippedSettingsWriteCount: 0,
        coalescingStats: .empty,
        rulesCacheHitCount: 0,
        errorMessage: nil,
        lastKillOperationSummary: nil
    )

    public init(
        backlogCount: Int,
        pendingActionCount: Int,
        lastFlushDate: Date?,
        lastPruneDate: Date?,
        lastFlushMilliseconds: Double = 0,
        lastContextMilliseconds: Double = 0,
        skippedSettingsWriteCount: Int = 0,
        coalescingStats: StoreCoalescingStats = .empty,
        rulesCacheHitCount: Int = 0,
        errorMessage: String?,
        lastKillOperationSummary: String? = nil
    ) {
        self.backlogCount = backlogCount
        self.pendingActionCount = pendingActionCount
        self.lastFlushDate = lastFlushDate
        self.lastPruneDate = lastPruneDate
        self.lastFlushMilliseconds = lastFlushMilliseconds
        self.lastContextMilliseconds = lastContextMilliseconds
        self.skippedSettingsWriteCount = skippedSettingsWriteCount
        self.coalescingStats = coalescingStats
        self.rulesCacheHitCount = rulesCacheHitCount
        self.errorMessage = errorMessage
        self.lastKillOperationSummary = lastKillOperationSummary
    }
}

public struct StoreCoalescingStats: Equatable, Sendable {
    public let forecastCandidates: Int
    public let forecastWrites: Int
    public let recommendationWrites: Int
    public let recommendationSkippedCount: Int

    public static let empty = StoreCoalescingStats(
        forecastCandidates: 0,
        forecastWrites: 0,
        recommendationWrites: 0,
        recommendationSkippedCount: 0
    )

    public init(
        forecastCandidates: Int,
        forecastWrites: Int,
        recommendationWrites: Int,
        recommendationSkippedCount: Int
    ) {
        self.forecastCandidates = forecastCandidates
        self.forecastWrites = forecastWrites
        self.recommendationWrites = recommendationWrites
        self.recommendationSkippedCount = recommendationSkippedCount
    }
}

public struct RadarScheduler: Sendable {
    private var lastInterval: TimeInterval = 1
    private var lastPlan: SamplingPlan = .balanced(now: Date(timeIntervalSince1970: 0))
    private var systemPressure: SystemPressureLevel = .nominal
    private var effectivePerformanceMode: RadarPerformanceMode = .balanced
    private var cadenceStep: UInt64 = 0

    public init() {}

    public mutating func updateSystemPressure() -> SystemPressureLevel {
        systemPressure = Self.currentSystemPressure()
        return systemPressure
    }

    public mutating func plan(
        settings: ThresholdSettings,
        families: [ProcessFamily],
        popoverVisible: Bool,
        focusedSignatureIDs: Set<String> = [],
        now: Date
    ) -> SamplingPlan {
        let pressure = updateSystemPressure()
        let demand = FamilySamplingDemand(families: families, focusedKeys: focusedSignatureIDs)
        let mode = settings.resolvedPerformanceMode(
            summaryLevel: demand.highestLevel,
            popoverVisible: popoverVisible,
            systemPressure: pressure
        )
        effectivePerformanceMode = mode
        let budget = RadarPerformanceBudget.budget(for: mode)
        let scannerBudget = ScannerBudget.budget(for: mode, pressure: pressure)
        let maxForensics = pressure.allowsOptionalForensics ? min(budget.maxForensicsPerRefresh, scannerBudget.maxForensicsRefreshes) : 0
        let candidates = CandidateSet(
            identities: demand.candidateIdentities,
            pids: demand.candidatePIDs,
            reason: demand.reason
        )
        let probePolicy = ProcessProbePolicy(
            richMetricIdentities: candidates.identities,
            richMetricPIDs: candidates.pids,
            allowsRichMetrics: pressure != .critical
        )

        let commandInterval: TimeInterval = switch mode {
        case .batterySaver: popoverVisible ? 15 : 30
        case .balanced: popoverVisible ? 8 : 20
        case .realtime: 5
        }

        let plan = SamplingPlan(
            sampledAt: now,
            performanceMode: mode,
            commandRefreshInterval: commandInterval,
            includeForensicsFor: demand.forensicsIdentities,
            includeForensicsForPIDs: demand.forensicsPIDs,
            forceCommandRefresh: popoverVisible && now.timeIntervalSince(lastPlan.sampledAt) >= commandInterval,
            allowsOptionalForensics: pressure.allowsOptionalForensics,
            maxForensicsPerRefresh: maxForensics,
            reason: candidates.reason,
            scannerBudget: scannerBudget,
            candidateSet: candidates,
            probePolicy: probePolicy,
            metricsEnrichmentBudget: max(scannerBudget.maxTelemetryRefreshes, demand.hotFamilyCount * 4 + demand.focusedFamilyCount * 4)
        )
        lastPlan = plan
        return plan
    }

    public mutating func nextInterval(
        settings: ThresholdSettings,
        summary: RadarSummary,
        lastRefresh: RefreshStats,
        popoverVisible: Bool
    ) -> TimeInterval {
        let pressure = systemPressure
        let mode = settings.resolvedPerformanceMode(
            summaryLevel: summary.level,
            popoverVisible: popoverVisible,
            systemPressure: pressure
        )
        effectivePerformanceMode = mode
        let base: TimeInterval
        if summary.level >= .hot {
            base = 0.75
        } else if popoverVisible {
            base = mode == .realtime ? 0.75 : max(0.75, settings.refreshInterval)
        } else {
            base = switch mode {
            case .batterySaver: 5
            case .balanced: summary.level == .watch ? 2 : 3.5
            case .realtime: 1
            }
        }

        let pressureMultiplier: Double = switch pressure {
        case .nominal: 1
        case .elevated: 1.25
        case .serious: 1.75
        case .critical: 2.5
        }

        let budget = RadarPerformanceBudget.budget(for: mode)
        let overBudgetMultiplier = lastRefresh.totalMilliseconds > budget.targetRefreshMilliseconds ? 1.35 : 1
        cadenceStep &+= 1
        let jitter: TimeInterval
        if summary.level >= .hot || popoverVisible {
            jitter = 0
        } else {
            jitter = Double(cadenceStep % 5) * 0.07
        }
        let interval = min(8, max(0.5, base * pressureMultiplier * overBudgetMultiplier + jitter))
        lastInterval = interval
        return interval
    }

    public var currentPressure: SystemPressureLevel {
        systemPressure
    }

    public var currentPerformanceMode: RadarPerformanceMode {
        effectivePerformanceMode
    }

    private static func currentSystemPressure() -> SystemPressureLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .elevated
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .nominal
        }
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
            if let cached = scoringCache.cachedFamily(for: family, context: context) {
                return cached
            }
            let scored = intelligence.enrich(family: family, context: context, settings: settings, now: now)
            scoringCache.store(scored, context: context)
            return scored
        }
        .sorted(by: sortScoredFamilies)
        let versioned = enriched.map { versionedFamily($0, diff: diff, now: now) }
        let stable = hysteresis.apply(to: versioned, now: now)
        return (stable, Date().timeIntervalSince(scoreStart) * 1_000)
    }

    private func sortScoredFamilies(_ lhs: ProcessFamily, _ rhs: ProcessFamily) -> Bool {
        if lhs.forecast.state != rhs.forecast.state {
            return lhs.forecast.state > rhs.forecast.state
        }
        if lhs.score.level != rhs.score.level {
            return lhs.score.level > rhs.score.level
        }
        if lhs.alertState.kind != rhs.alertState.kind {
            return alertPriority(lhs.alertState.kind) > alertPriority(rhs.alertState.kind)
        }
        if lhs.score.heat.value != rhs.score.heat.value {
            return lhs.score.heat.value > rhs.score.heat.value
        }
        if lhs.score.value != rhs.score.value {
            return lhs.score.value > rhs.score.value
        }
        if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
            return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
        }
        return lhs.totalCPUPercent > rhs.totalCPUPercent
    }

    private func alertPriority(_ kind: AlertStateKind) -> Int {
        switch kind {
        case .new: 4
        case .recurring: 3
        case .normal: 2
        case .snoozed: 1
        case .ignored: 0
        }
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

private struct RadarHysteresis: Sendable {
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
                heat: GhostHeat(
                    value: family.score.heat.value,
                    level: level,
                    confidence: family.score.heat.confidence,
                    evidence: family.score.heat.evidence,
                    sustainedSignalCount: family.score.heat.sustainedSignalCount
                )
            )
            return family.enriched(score: score)
        }
    }
}
