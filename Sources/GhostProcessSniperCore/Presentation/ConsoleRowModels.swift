import Foundation

public struct IncidentRowViewModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let familyName: String
    public let stateText: String
    public let level: GhostLevel
    public let scoreText: String
    public let memoryText: String
    public let cpuText: String
    public let leakText: String
    public let occurrenceText: String
    public let timeRangeText: String
    public let durationText: String
    public let reasons: [String]
    public let isActive: Bool
    /// Sort keys for table columns.
    public let score: Double
    public let memoryBytes: UInt64
    public let occurrenceCount: Int
    /// The concrete family key of a running family with this incident's
    /// signature; nil once it has exited.
    public let liveFamilyKey: String?

    /// The episode's peak growth. "none" below 1 MB/min, which also covers the
    /// raw, possibly negative slope that rows written before peaks were
    /// tracked still hold.
    public static func growthText(_ megabytesPerMinute: Double) -> String {
        megabytesPerMinute >= 0.5 ? RadarFormat.leak(megabytesPerMinute) : "none"
    }

    public init(incident: RadarIncident) {
        self.init(incident: incident, liveFamilyKey: nil)
    }

    public init(incident: RadarIncident, liveFamilyKey: String?) {
        id = incident.id
        familyName = incident.familyName
        isActive = incident.resolvedAt == nil
        stateText = isActive ? "Active" : "Resolved"
        level = incident.level
        score = incident.maxScore
        memoryBytes = incident.memoryBytes
        occurrenceCount = incident.occurrenceCount
        self.liveFamilyKey = liveFamilyKey
        scoreText = "\(Int(incident.maxScore.rounded()))"
        memoryText = RadarFormat.bytes(incident.memoryBytes)
        cpuText = RadarFormat.percent(incident.cpuPercent)
        leakText = Self.growthText(incident.leakVelocityMegabytesPerMinute)
        occurrenceText = "\(incident.occurrenceCount)"
        timeRangeText = "\(incident.startedAt.formatted(date: .abbreviated, time: .shortened)) - \(incident.lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
        durationText = Self.durationText(of: incident)
        reasons = incident.reasons
    }

    /// Whole units only ("27 h", not "26.9h"), so no decimal separator can
    /// disagree with the reader's locale.
    private static func durationText(of incident: RadarIncident) -> String {
        EnergyFormat.duration((incident.resolvedAt ?? incident.lastSeenAt).timeIntervalSince(incident.startedAt))
    }
}

public struct RuleRowViewModel: Identifiable, Equatable, Sendable {
    /// Which Rules section a rule belongs to: the user's own snoozes and
    /// ignores come first so undoing one is easy to find.
    public enum Kind: Equatable, Sendable {
        case snooze
        case ignore
        case custom
        case builtIn
    }

    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let isBuiltIn: Bool
    public let kind: Kind
    public let expiresAt: Date?
    public let actionText: String
    public let matchText: String
    public let matchCount: Int

    public init(rule: RadarRule, matchCount: Int = 0) {
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        isBuiltIn = rule.isBuiltIn
        // Only a family's own snooze or ignore can be undone by deleting it;
        // a composed rule that snoozes by command stays a toggleable custom rule.
        kind = if rule.isBuiltIn {
            .builtIn
        } else if rule.match.signatureID == nil {
            .custom
        } else {
            switch rule.action {
            case .snooze: .snooze
            case .ignore: .ignore
            default: .custom
            }
        }
        expiresAt = rule.expiresAt
        actionText = rule.isBuiltIn ? "Built-in" : rule.action.label
        self.matchCount = matchCount

        var parts: [String] = []
        if let command = rule.match.commandContains {
            parts.append("command contains \(command)")
        }
        if let path = rule.match.pathContains {
            parts.append("path contains \(path)")
        }
        if rule.match.minimumLevel > .quiet {
            parts.append("level \(rule.match.minimumLevel.label)+")
        }
        if let leak = rule.match.minimumLeakVelocity {
            parts.append("leak \(Int(leak)) MB/min+")
        }
        if let expires = rule.expiresAt {
            parts.append("until \(expires.formatted(date: .omitted, time: .shortened))")
        }
        matchText = parts.isEmpty ? rule.action.label : parts.joined(separator: " - ")
    }
}

public struct EngineDiagnosticsViewModel: Equatable, Sendable {
    public let statusLine: String
    public let refreshCostText: String
    public let averageCostText: String
    public let nextRefreshText: String
    public let forensicsText: String
    public let scannerLaneText: String
    public let deadlineText: String
    public let cacheText: String
    public let scannerCostText: String
    public let smoothnessText: String
    public let expensiveCallText: String
    public let storeBacklogText: String
    public let storeCoalescingText: String
    public let pressureText: String

    public static let empty = EngineDiagnosticsViewModel(
        statusLine: "Warming up",
        refreshCostText: "0 ms",
        averageCostText: "0 ms",
        nextRefreshText: "1.0s",
        forensicsText: "0 / 0",
        scannerLaneText: "Warming",
        deadlineText: "Within budget",
        cacheText: "0 cached",
        scannerCostText: "0 cheap / 0 rich / 0 skipped",
        smoothnessText: "0 ms publish / 0 coalesced / 0 UI hits",
        expensiveCallText: "0",
        storeBacklogText: "0",
        storeCoalescingText: "0 baseline writes, 0 deferred, 0 flushes skipped",
        pressureText: "Nominal"
    )

    public init(
        statusLine: String,
        refreshCostText: String,
        averageCostText: String,
        nextRefreshText: String,
        forensicsText: String,
        scannerLaneText: String,
        deadlineText: String,
        cacheText: String,
        scannerCostText: String,
        smoothnessText: String,
        expensiveCallText: String,
        storeBacklogText: String,
        storeCoalescingText: String,
        pressureText: String
    ) {
        self.statusLine = statusLine
        self.refreshCostText = refreshCostText
        self.averageCostText = averageCostText
        self.nextRefreshText = nextRefreshText
        self.forensicsText = forensicsText
        self.scannerLaneText = scannerLaneText
        self.deadlineText = deadlineText
        self.cacheText = cacheText
        self.scannerCostText = scannerCostText
        self.smoothnessText = smoothnessText
        self.expensiveCallText = expensiveCallText
        self.storeBacklogText = storeBacklogText
        self.storeCoalescingText = storeCoalescingText
        self.pressureText = pressureText
    }

    public init(
        metrics: RadarPerformanceMetrics,
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        summary: RadarSummary,
        generatedAt: Date
    ) {
        // The refresh's own store error, else the store's open or corruption
        // error, like ProcessMonitor.storeError: a failing store never reads as fine.
        statusLine = storeError ?? storeHealth.errorMessage ?? health.errorMessage
            ?? "\(summary.statusText) - \(health.processCount) processes sampled"
        // Bucketed to 5 ms: the exact per-tick jitter (9 → 12 → 8 ms) is
        // noise, and every distinct string invalidates console layout.
        refreshCostText = "\(max(5, Self.fiveMillisecondBucket(metrics.lastRefresh.totalMilliseconds))) ms"
        averageCostText = "\(max(5, Self.fiveMillisecondBucket(metrics.averageRefreshMilliseconds))) ms"
        nextRefreshText = String(format: "%.1fs", metrics.nextRefreshInterval)
        forensicsText = "\(metrics.forensicsRefreshCount) refreshed / \(metrics.forensicsDeferredCount) deferred"
        scannerLaneText = ScanLane.allCases
            .filter { metrics.scannerHealth.laneCounts[$0, default: 0] > 0 }
            .map { "\($0.label) \(metrics.scannerHealth.laneCounts[$0, default: 0])" }
            .joined(separator: " - ")
            .ifNotEmpty ?? "No lane data"
        deadlineText = metrics.scannerHealth.didHitDeadline ? "Deadline hit" : "Within budget"
        cacheText = "\(metrics.commandCacheHitCount) command, \(metrics.reusedProcessRecordCount) reused, \(metrics.scannerHealth.forensicsNegativeCacheHitCount) negative"
        let ledger = metrics.scannerHealth.costLedger
        scannerCostText = "\(ledger.cheapProbeCount) cheap / \(ledger.richMetricCount) rich / \(ledger.taskInfoReadCount) task-info / \(ledger.reusedRecordCount) reused / \(ledger.scannerTaskCount) tasks / \(ledger.skippedCount) skipped / \(metrics.hardwareOffenderCount) hardware / \(ledger.usageReadCount) measured / \(ledger.usageFailedCount) unmeasured / \(ledger.bsdDeniedCount) hidden (other users) / \(ledger.portCensusCount) port census"
        let hitchText = metrics.hitchCount > 0 ? " / \(metrics.hitchCount) hitches, worst \(Self.fiveMillisecondBucket(metrics.worstHitchMilliseconds)) ms \(metrics.latestSpikePhase)" : ""
        smoothnessText = "\(Self.fiveMillisecondBucket(metrics.mainActorPublishMilliseconds)) ms publish / \(metrics.coalescedRefreshCount) coalesced / \(metrics.diagnosticsOnlyPublishCount) diag-only / \(metrics.contentPublishSkippedCount) content skips / \(metrics.uiCacheHitCount) UI hits / \(metrics.uiPublishSkippedCount) UI skips\(hitchText)"
        expensiveCallText = "\(metrics.scannerHealth.expensiveCallCount)"
        storeBacklogText = "\(storeHealth.backlogCount + storeHealth.pendingActionCount)"
        let writes = storeHealth.writeStats
        storeCoalescingText = "\(writes.baselineWrites) baseline writes, \(writes.baselinesDeferred) deferred, \(writes.transactionsSkipped) flushes skipped, \(storeHealth.rulesCacheHitCount) rule hits"
        pressureText = metrics.pressureLevel.rawValue.capitalized
    }

    static func fiveMillisecondBucket(_ milliseconds: Double) -> Int {
        Int((milliseconds / 5).rounded() * 5)
    }
}

public struct RuleMatchPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ruleName: String
    public let matchCount: Int
    public let matchedFamilyKeys: [String]
    public let matchedFamilyNames: [String]

    public init(rule: RadarRule, families: [ProcessFamily], now: Date = Date()) {
        id = rule.id
        ruleName = rule.name
        let engine = RadarRuleEngine()
        let matched = families.filter { engine.matches(rule: rule, family: $0, now: now) }
        matchCount = matched.count
        matchedFamilyKeys = matched.map(\.familyKey)
        matchedFamilyNames = matched.map(\.displayName)
    }
}

extension RadarIncidentSort {
    /// The sort an Incidents table column header selects; anything else
    /// (a cleared header) is most recent first.
    public init(incidentColumn keyPath: PartialKeyPath<IncidentRowViewModel>?) {
        self = switch keyPath {
        case \IncidentRowViewModel.familyName: .name
        case \IncidentRowViewModel.score: .severity
        case \IncidentRowViewModel.memoryBytes: .memory
        case \IncidentRowViewModel.occurrenceCount: .recurrence
        default: .recent
        }
    }
}
