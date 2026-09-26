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
    public let reasons: [String]

    public init(incident: RadarIncident) {
        id = incident.id
        familyName = incident.familyName
        stateText = incident.resolvedAt == nil ? "Active" : "Resolved"
        level = incident.level
        scoreText = "\(Int(incident.maxScore.rounded()))"
        memoryText = RadarFormat.bytes(incident.memoryBytes)
        cpuText = RadarFormat.percent(incident.cpuPercent)
        leakText = RadarFormat.leak(incident.leakVelocityMegabytesPerMinute)
        occurrenceText = "\(incident.occurrenceCount)"
        timeRangeText = "\(incident.startedAt.formatted(date: .abbreviated, time: .shortened)) - \(incident.lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
        reasons = incident.reasons
    }
}

public struct RuleRowViewModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let isBuiltIn: Bool
    public let actionText: String
    public let matchText: String
    public let matchCount: Int

    public init(rule: RadarRule, matchCount: Int = 0) {
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        isBuiltIn = rule.isBuiltIn
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
    public let diagnosticsReport: String

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
        storeCoalescingText: "0/0 forecasts, 0 rec skipped",
        pressureText: "Nominal",
        diagnosticsReport: "Ghost Process Sniper Diagnostics\nWarming up."
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
        pressureText: String,
        diagnosticsReport: String
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
        self.diagnosticsReport = diagnosticsReport
    }

    public init(
        metrics: RadarPerformanceMetrics,
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        summary: RadarSummary,
        generatedAt: Date
    ) {
        statusLine = storeError ?? health.errorMessage ?? "\(summary.statusText) - \(health.processCount) processes sampled"
        // Bucketed to 5 ms: the exact per-tick jitter (9 → 12 → 8 ms) is
        // noise, and every distinct string invalidates console layout.
        refreshCostText = "\(max(5, Int((metrics.lastRefresh.totalMilliseconds / 5).rounded() * 5))) ms"
        averageCostText = "\(Int(metrics.averageRefreshMilliseconds.rounded())) ms"
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
        scannerCostText = "\(ledger.cheapProbeCount) cheap / \(ledger.richMetricCount) rich / \(ledger.taskInfoReadCount) task-info / \(ledger.reusedRecordCount) reused / \(ledger.workerCount) workers / \(ledger.scannerTaskCount) tasks / \(ledger.pidBufferCopyCount) pid copies / \(ledger.skippedCount) skipped / \(metrics.hardwareOffenderCount) hardware"
        let hitchText = metrics.hitchCount > 0 ? " / \(metrics.hitchCount) hitches, worst \(Int(metrics.worstHitchMilliseconds.rounded())) ms \(metrics.latestSpikePhase)" : ""
        smoothnessText = "\(Int(metrics.mainActorPublishMilliseconds.rounded())) ms publish / \(metrics.coalescedRefreshCount) coalesced / \(metrics.diagnosticsOnlyPublishCount) diag-only / \(metrics.contentPublishSkippedCount) content skips / \(metrics.uiCacheHitCount) UI hits / \(metrics.uiPublishSkippedCount) UI skips\(hitchText)"
        expensiveCallText = "\(metrics.scannerHealth.expensiveCallCount)"
        storeBacklogText = "\(storeHealth.backlogCount + storeHealth.pendingActionCount)"
        storeCoalescingText = "\(storeHealth.coalescingStats.forecastWrites)/\(storeHealth.coalescingStats.forecastCandidates) forecasts, \(storeHealth.coalescingStats.recommendationSkippedCount) rec skipped, \(storeHealth.rulesCacheHitCount) rule hits"
        pressureText = metrics.pressureLevel.rawValue.capitalized
        let optimization = RadarOptimizationReport(scannerHealth: metrics.scannerHealth, metrics: metrics)
        diagnosticsReport = [
            "Ghost Process Sniper Diagnostics",
            "Generated: \(generatedAt.formatted())",
            "State: \(summary.statusText)",
            "Families: \(summary.familyCount), hot: \(summary.hotCount), leaks: \(summary.leakingCount)",
            "Duplicates: \(metrics.duplicateClusterCount) clusters, \(metrics.promotedDuplicateCandidateCount) promoted candidates, detector \(Int(metrics.duplicateDetectorMilliseconds.rounded()))ms",
            "Hardware offenders: \(metrics.hardwareOffenderCount), detector \(Int(metrics.hardwareDetectorMilliseconds.rounded()))ms",
            "Processes: \(health.processCount)",
            "Refresh: \(refreshCostText), average: \(averageCostText), next: \(nextRefreshText)",
            "Forensics: \(forensicsText)",
            "Scanner: \(deadlineText), lanes: \(scannerLaneText)",
            "Probe cost: \(scannerCostText)",
            "Smoothness: \(smoothnessText), in flight: \(metrics.refreshInFlight), skipped optional: \(metrics.skippedOptionalWorkCount), status update: \(Int(metrics.statusUpdateMilliseconds.rounded())) ms, content rev: \(metrics.contentRevision.rawValue)",
            "Scanner tasks: \(metrics.scannerTaskCount), tiny sequential queues: \(metrics.tinyQueueSequentialCount), task-info reads: \(metrics.taskInfoReadCount), reused records: \(metrics.reusedProcessRecordCount), scratch reuse: \(metrics.samplerAllocationReuseCount)",
            "Recent spikes: \(metrics.smoothnessReport.recentSpikes.isEmpty ? "none" : metrics.smoothnessReport.recentSpikes.joined(separator: " | "))",
            "Cache: \(cacheText), expensive calls: \(expensiveCallText)",
            optimization.text,
            "Store backlog: \(storeBacklogText)",
            "Store coalescing: \(storeCoalescingText)",
            "Pressure: \(pressureText)",
            "Health: \(statusLine)"
        ].joined(separator: "\n")
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
