import Foundation

public enum ConsoleSidebarSectionKind: String, Codable, Sendable {
    case attention
    case watched
    case quiet
    case tools
}

public struct ConsoleSidebarSection: Identifiable, Equatable, Sendable {
    public var id: ConsoleSidebarSectionKind { kind }

    public let kind: ConsoleSidebarSectionKind
    public let title: String
    public let count: Int
    public let families: [FamilyTriageViewModel]

    public init(kind: ConsoleSidebarSectionKind, title: String, count: Int, families: [FamilyTriageViewModel]) {
        self.kind = kind
        self.title = title
        self.count = count
        self.families = families
    }
}

public struct FamilyMetricCard: Identifiable, Equatable, Sendable {
    public var id: String { title }

    public let title: String
    public let value: String
    public let systemImage: String
    public let level: GhostLevel

    public init(title: String, value: String, systemImage: String, level: GhostLevel = .quiet) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.level = level
    }
}

public struct FamilyChangeSummary: Equatable, Sendable {
    public let memoryDeltaBytes: Int64
    public let cpuDelta: Double
    public let childDelta: Int
    public let summary: String
    public let level: GhostLevel

    public static let warming = FamilyChangeSummary(
        memoryDeltaBytes: 0,
        cpuDelta: 0,
        childDelta: 0,
        summary: "Learning this family",
        level: .quiet
    )

    public init(memoryDeltaBytes: Int64, cpuDelta: Double, childDelta: Int, summary: String, level: GhostLevel) {
        self.memoryDeltaBytes = memoryDeltaBytes
        self.cpuDelta = cpuDelta
        self.childDelta = childDelta
        self.summary = summary
        self.level = level
    }
}

public struct FamilyDetailPanelModel: Identifiable, Equatable, Sendable {
    public var id: String { familyKey }

    public let familyKey: String
    public let title: String
    public let kind: DevProcessKind
    public let kindReason: String
    public let commandLine: String
    public let rootPID: Int32
    public let level: GhostLevel
    public let scoreText: String
    public let statusText: String
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let gpuPercent: Double
    public let childCount: Int
    public let summaryCards: [FamilyMetricCard]
    public let baselineCards: [FamilyMetricCard]
    public let forecastState: ForecastState
    public let forecastStateText: String
    public let forecastETA: String
    public let forecastConfidenceText: String
    public let forecastWhyNow: String
    public let forecastRecommendationTitle: String
    public let forecastRecommendationDetail: String
    public let forecastCards: [FamilyMetricCard]
    public let change: FamilyChangeSummary
    public let scoreComponents: [GhostScoreComponent]
    public let culprit: CulpritAnalysis
    public let suggestions: [RadarActionSuggestion]
    public let forensics: FamilyForensicsSummary
    public let members: [ProcessMetrics]
    public let trendPoints: [Double]
    public let trendSamples: [TrendSample]
    public let trendFitQuality: Double
    public let trendVelocityMegabytesPerMinute: Double
    public let memoryPattern: MemoryPatternAnalysis
    public let verdict: FamilyVerdict
    public let forecastETASeconds: TimeInterval?
    public let scoreValue: Double
    public let isKillable: Bool
    public let hasOwnedTargets: Bool
    public let protectedPIDs: [Int32]
    public let lastScoredText: String

    public init(
        family: ProcessFamily,
        previous: FamilyDetailPanelModel?,
        classifier: DevProcessClassifier = DevProcessClassifier(),
        classification providedClassification: DevClassification? = nil,
        culprit providedCulprit: CulpritAnalysis? = nil
    ) {
        let classification = providedClassification ?? family.classification ?? classifier.classification(for: family)
        familyKey = family.familyKey
        title = family.displayName
        kind = classification.kind
        kindReason = classification.reason
        commandLine = family.root.commandLine
        rootPID = family.root.pid
        level = family.score.level
        scoreText = "\(Int(family.score.value.rounded()))"
        statusText = family.alertState.kind == .normal ? family.score.level.label : family.alertState.message
        memoryBytes = family.totalPhysicalFootprintBytes
        cpuPercent = family.totalCPUPercent
        gpuPercent = family.totalGPUPercent
        childCount = family.childCount
        var cards = [
            FamilyMetricCard(title: "Footprint", value: RadarFormat.bytes(family.totalPhysicalFootprintBytes), systemImage: "memorychip", level: family.score.level >= .hot ? family.score.level : .watch),
            FamilyMetricCard(title: "RSS", value: RadarFormat.bytes(family.totalResidentMemoryBytes), systemImage: "square.stack.3d.up"),
            FamilyMetricCard(title: "CPU", value: RadarFormat.percent(family.totalCPUPercent), systemImage: "cpu", level: family.totalCPUPercent >= 80 ? .hot : .quiet),
            FamilyMetricCard(title: "Leak", value: RadarFormat.leak(family.trend.memoryVelocityMegabytesPerMinute), systemImage: "chart.line.uptrend.xyaxis", level: family.trend.memoryVelocityMegabytesPerMinute > 0 ? .watch : .quiet),
            FamilyMetricCard(title: "Tree", value: "\(family.members.count)", systemImage: "point.3.connected.trianglepath.dotted")
        ]
        if family.totalGPUPercent > 0 {
            cards.insert(
                FamilyMetricCard(title: "GPU", value: RadarFormat.percent(family.totalGPUPercent), systemImage: "display", level: family.totalGPUPercent >= 45 ? .hot : .watch),
                at: 3
            )
        }
        summaryCards = cards
        baselineCards = Self.baselineCards(for: family)
        forecastState = family.forecast.state
        forecastStateText = family.forecast.state.label
        forecastETA = family.forecast.etaText
        forecastConfidenceText = "\(Int((family.forecast.confidence * 100).rounded()))%"
        forecastWhyNow = family.forecast.whyNow
        forecastRecommendationTitle = family.forecast.recommendedAction.title
        forecastRecommendationDetail = family.forecast.recommendedAction.detail
        forecastCards = Self.forecastCards(for: family)
        change = Self.change(current: family, previous: previous)
        scoreComponents = family.score.components.sorted { $0.impact > $1.impact }
        culprit = providedCulprit ?? CulpritAnalysis(family: family, classifier: classifier, classification: classification)
        suggestions = family.suggestions
        forensics = FamilyForensicsSummary(family: family)
        members = family.members
        trendPoints = family.trend.memoryPoints
        trendSamples = family.trend.samples
        trendFitQuality = family.trend.memoryFitQuality
        trendVelocityMegabytesPerMinute = family.trend.memoryVelocityMegabytesPerMinute
        let patternAnalysis = MemoryPatternAnalysis.analyze(
            points: family.trend.memoryPoints,
            fitQuality: family.trend.memoryFitQuality
        )
        memoryPattern = patternAnalysis
        verdict = FamilyVerdict.synthesize(family: family, pattern: patternAnalysis)
        forecastETASeconds = family.forecast.etaSeconds
        scoreValue = family.score.value
        isKillable = family.isKillable
        hasOwnedTargets = !family.ownedIdentities.isEmpty
        protectedPIDs = family.protectedPIDs
        lastScoredText = family.lastScoredAt?.formatted(date: .omitted, time: .standard) ?? "warming"
    }

    private static func baselineCards(for family: ProcessFamily) -> [FamilyMetricCard] {
        guard let baseline = family.baseline else {
            return [
                FamilyMetricCard(title: "Baseline", value: "Learning", systemImage: "ruler")
            ]
        }
        let memoryMultiple = baseline.memoryMultiple(for: family.totalPhysicalFootprintBytes)
        let cpuMultiple = baseline.cpuMultiple(for: family.totalCPUPercent)
        return [
            FamilyMetricCard(title: "Memory x", value: String(format: "%.1fx", memoryMultiple), systemImage: "ruler", level: memoryMultiple >= 2 ? .hot : .quiet),
            FamilyMetricCard(title: "CPU x", value: String(format: "%.1fx", cpuMultiple), systemImage: "cpu", level: cpuMultiple >= 2 ? .watch : .quiet),
            FamilyMetricCard(title: "Peak", value: RadarFormat.bytes(baseline.peakMemoryBytes), systemImage: "arrow.up.forward"),
            FamilyMetricCard(title: "Incidents", value: "\(baseline.incidentCount)", systemImage: "waveform.path.ecg", level: baseline.incidentCount > 0 ? .watch : .quiet)
        ]
    }

    private static func forecastCards(for family: ProcessFamily) -> [FamilyMetricCard] {
        let forecast = family.forecast
        return [
            FamilyMetricCard(title: "State", value: forecast.state.label, systemImage: "radar", level: forecast.state.level),
            FamilyMetricCard(title: "ETA", value: forecast.etaText, systemImage: "clock.badge.exclamationmark", level: forecast.horizon == .imminent || forecast.horizon == .breached ? .hot : forecast.state.level),
            FamilyMetricCard(title: "Confidence", value: "\(Int((forecast.confidence * 100).rounded()))%", systemImage: "dial.low", level: forecast.confidence >= 0.68 ? forecast.state.level : .quiet),
            FamilyMetricCard(title: "10m Memory", value: RadarFormat.bytes(forecast.projectedMemoryBytes), systemImage: "chart.line.uptrend.xyaxis", level: forecast.projectedMemoryBytes > family.totalPhysicalFootprintBytes ? .watch : .quiet),
            FamilyMetricCard(title: "10m CPU", value: RadarFormat.percent(forecast.projectedCPUPercent), systemImage: "cpu", level: forecast.projectedCPUPercent >= 80 ? .hot : .quiet),
            FamilyMetricCard(title: "Recurrence", value: "\(Int((forecast.recurrenceRisk * 100).rounded()))%", systemImage: "repeat", level: forecast.recurrenceRisk >= 0.5 ? .watch : .quiet)
        ]
    }

    private static func change(current: ProcessFamily, previous: FamilyDetailPanelModel?) -> FamilyChangeSummary {
        guard let previous else {
            return .warming
        }
        let memoryDelta = Int64(clamping: current.totalPhysicalFootprintBytes) - Int64(clamping: previous.memoryBytes)
        let cpuDelta = current.totalCPUPercent - previous.cpuPercent
        let childDelta = current.childCount - previous.childCount
        let level: GhostLevel
        if memoryDelta > 256 * 1_048_576 || cpuDelta > 25 || childDelta >= 4 {
            level = .hot
        } else if memoryDelta > 64 * 1_048_576 || cpuDelta > 8 || childDelta > 0 {
            level = .watch
        } else {
            level = .quiet
        }

        var parts: [String] = []
        if memoryDelta != 0 {
            parts.append("memory \(RadarFormat.signedBytes(memoryDelta))")
        }
        if abs(cpuDelta) >= 1 {
            parts.append("CPU \(RadarFormat.signedPercent(cpuDelta))")
        }
        if childDelta != 0 {
            parts.append("children \(childDelta > 0 ? "+" : "")\(childDelta)")
        }
        let summary = parts.isEmpty ? "No material change since last refresh" : parts.joined(separator: ", ")
        return FamilyChangeSummary(
            memoryDeltaBytes: memoryDelta,
            cpuDelta: cpuDelta,
            childDelta: childDelta,
            summary: summary,
            level: level
        )
    }
}

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

    public init(rule: RadarRule, families: [ProcessFamily]) {
        id = rule.id
        ruleName = rule.name
        let matched = families.filter { RadarRuleMatcher.matches(rule: rule, family: $0) }
        matchCount = matched.count
        matchedFamilyKeys = matched.map(\.familyKey)
        matchedFamilyNames = matched.map(\.displayName)
    }
}

public enum ConsoleLayoutMode: String, Codable, CaseIterable, Sendable {
    case compact
}

public struct EngineStatusSnapshot: Equatable, Sendable {
    public let statusLine: String
    public let refreshText: String
    public let nextRefreshText: String
    public let processText: String
    public let scannerText: String
    public let backlogText: String
    public let updatedText: String
    public let level: GhostLevel

    public static let empty = EngineStatusSnapshot(
        statusLine: "Warming up",
        refreshText: "0 ms",
        nextRefreshText: "1.0s",
        processText: "0",
        scannerText: "warming",
        backlogText: "0",
        updatedText: "warming",
        level: .quiet
    )

    public init(
        statusLine: String,
        refreshText: String,
        nextRefreshText: String,
        processText: String,
        scannerText: String,
        backlogText: String,
        updatedText: String,
        level: GhostLevel
    ) {
        self.statusLine = statusLine
        self.refreshText = refreshText
        self.nextRefreshText = nextRefreshText
        self.processText = processText
        self.scannerText = scannerText
        self.backlogText = backlogText
        self.updatedText = updatedText
        self.level = level
    }

    public init(
        engine: EngineDiagnosticsViewModel,
        summary: RadarSummary,
        processText: String,
        generatedAt: Date
    ) {
        self.init(
            statusLine: engine.statusLine,
            refreshText: engine.refreshCostText,
            nextRefreshText: engine.nextRefreshText,
            processText: processText,
            scannerText: engine.deadlineText == "Within budget" ? "within budget" : "deferred",
            backlogText: engine.storeBacklogText,
            // Minute precision: a seconds clock re-invalidates the console
            // layout every single second for no information gain.
            updatedText: generatedAt.formatted(date: .omitted, time: .shortened),
            level: summary.level
        )
    }

    public init(
        engine: EngineDiagnosticsViewModel,
        summary: RadarSummary,
        health: SamplerHealth,
        generatedAt: Date
    ) {
        self.init(
            engine: engine,
            summary: summary,
            processText: "\(health.processCount)",
            generatedAt: generatedAt
        )
    }
}

public struct CompactSidebarRowModel: Identifiable, Equatable, Sendable {
    public var id: String { familyKey }

    public let familyKey: String
    public let signature: ProcessSignature
    public let title: String
    public let subtitle: String
    public let metricText: String
    public let scoreText: String
    public let scoreValue: Double
    public let systemImage: String
    public let level: GhostLevel
    public let forecastState: ForecastState
    public let helpText: String

    public init(item: FamilyTriageViewModel) {
        familyKey = item.familyKey
        signature = item.signature
        title = item.displayName
        subtitle = "\(item.kindText) - \(item.alertMessage)"
        metricText = item.gpuPercent > 0.5 ? "\(item.memoryText) / \(item.cpuText) / GPU \(item.gpuText)" : "\(item.memoryText) / \(item.cpuText)"
        scoreText = item.scoreText
        scoreValue = item.score
        systemImage = Self.icon(for: item.level)
        level = item.level
        forecastState = item.forecastState
        let gpuHelp = item.gpuPercent > 0.5 ? ", GPU \(item.gpuText)" : ""
        helpText = "\(item.classificationReason)\n\(item.memoryText), \(item.cpuText)\(gpuHelp), \(item.leakText)"
    }

    private static func icon(for level: GhostLevel) -> String {
        switch level {
        case .quiet: "checkmark.circle"
        case .watch: "eye"
        case .hot: "flame"
        case .critical: "exclamationmark.triangle"
        }
    }
}

public struct CompactSidebarSection: Identifiable, Equatable, Sendable {
    public var id: ConsoleSidebarSectionKind { kind }

    public let kind: ConsoleSidebarSectionKind
    public let title: String
    public let count: Int
    public let rows: [CompactSidebarRowModel]

    public init(kind: ConsoleSidebarSectionKind, title: String, count: Int, rows: [CompactSidebarRowModel]) {
        self.kind = kind
        self.title = title
        self.count = count
        self.rows = rows
    }
}

public struct OverviewCommandCenterModel: Equatable, Sendable {
    public let title: String
    public let statusText: String
    public let subtitle: String
    public let updatedText: String
    public let level: GhostLevel
    public let chips: [FamilyMetricCard]

    public static let empty = OverviewCommandCenterModel(
        summary: .empty,
        engineStatus: .empty
    )

    public init(summary: RadarSummary, engineStatus: EngineStatusSnapshot, duplicateCount: Int = 0) {
        title = "Command Center"
        statusText = summary.statusText
        subtitle = engineStatus.statusLine
        updatedText = engineStatus.updatedText
        level = summary.level
        chips = [
            FamilyMetricCard(title: "Families", value: "\(summary.familyCount)", systemImage: "rectangle.stack"),
            FamilyMetricCard(title: "Hot", value: "\(summary.hotCount)", systemImage: "flame", level: summary.hotCount > 0 ? .hot : .quiet),
            FamilyMetricCard(title: "Leaks", value: "\(summary.leakingCount)", systemImage: "chart.line.uptrend.xyaxis", level: summary.leakingCount > 0 ? .watch : .quiet),
            FamilyMetricCard(title: "Duplicates", value: "\(duplicateCount)", systemImage: "doc.on.doc", level: duplicateCount > 0 ? .watch : .quiet),
            FamilyMetricCard(title: "Memory", value: RadarFormat.bytes(summary.totalMemoryBytes), systemImage: "memorychip", level: .watch),
            FamilyMetricCard(title: "Refresh", value: engineStatus.refreshText, systemImage: "timer")
        ]
    }
}

public struct CompactFamilyDetailModel: Identifiable, Equatable, Sendable {
    public var id: String { familyKey }

    public let familyKey: String
    public let title: String
    public let subtitle: String
    public let commandLine: String
    public let kindText: String
    public let statusText: String
    public let scoreText: String
    public let pidText: String
    public let forecastText: String
    public let actionText: String
    public let level: GhostLevel
    public let quickCards: [FamilyMetricCard]
    public let baselineCards: [FamilyMetricCard]
    public let scoreComponents: [GhostScoreComponent]
    public let trendPoints: [Double]

    public init(panel: FamilyDetailPanelModel) {
        familyKey = panel.familyKey
        title = panel.title
        subtitle = "\(panel.kind.label) - \(panel.statusText)"
        commandLine = panel.commandLine
        kindText = panel.kind.label
        statusText = panel.statusText
        scoreText = panel.scoreText
        pidText = "PID \(panel.rootPID)"
        forecastText = "\(panel.forecastStateText) - \(panel.forecastETA) - \(panel.forecastConfidenceText)"
        actionText = "\(panel.forecastRecommendationTitle): \(panel.forecastRecommendationDetail)"
        level = panel.level
        quickCards = Array(panel.summaryCards.prefix(5))
        baselineCards = Array(panel.baselineCards.prefix(4))
        scoreComponents = Array(panel.scoreComponents.prefix(6))
        trendPoints = panel.trendPoints
    }
}

public struct CompactConsoleSnapshot: Equatable, Sendable {
    public let layoutMode: ConsoleLayoutMode
    public let commandCenter: OverviewCommandCenterModel
    public let engineStatus: EngineStatusSnapshot
    public let allRows: [CompactSidebarRowModel]
    public let topRiskRows: [CompactSidebarRowModel]
    public let warmingRows: [CompactSidebarRowModel]
    public let detailModels: [String: CompactFamilyDetailModel]
    public let duplicateCount: Int

    public static let empty = CompactConsoleSnapshot(
        layoutMode: .compact,
        commandCenter: .empty,
        engineStatus: .empty,
        allRows: [],
        topRiskRows: [],
        warmingRows: [],
        detailModels: [:],
        duplicateCount: 0
    )

    public init(
        layoutMode: ConsoleLayoutMode,
        commandCenter: OverviewCommandCenterModel,
        engineStatus: EngineStatusSnapshot,
        allRows: [CompactSidebarRowModel],
        topRiskRows: [CompactSidebarRowModel],
        warmingRows: [CompactSidebarRowModel],
        detailModels: [String: CompactFamilyDetailModel],
        duplicateCount: Int = 0
    ) {
        self.layoutMode = layoutMode
        self.commandCenter = commandCenter
        self.engineStatus = engineStatus
        self.allRows = allRows
        self.topRiskRows = topRiskRows
        self.warmingRows = warmingRows
        self.detailModels = detailModels
        self.duplicateCount = duplicateCount
    }

    public static func build(
        summary: RadarSummary,
        triage: [FamilyTriageViewModel],
        detailPanels: [String: FamilyDetailPanelModel],
        engineStatus: EngineStatusSnapshot,
        duplicateCount: Int = 0
    ) -> CompactConsoleSnapshot {
        let rows = triage.map(CompactSidebarRowModel.init(item:))
        let detailModels = Dictionary(
            uniqueKeysWithValues: detailPanels.map { key, panel in
                (key, CompactFamilyDetailModel(panel: panel))
            }
        )
        return CompactConsoleSnapshot(
            layoutMode: .compact,
            commandCenter: OverviewCommandCenterModel(summary: summary, engineStatus: engineStatus, duplicateCount: duplicateCount),
            engineStatus: engineStatus,
            allRows: rows,
            topRiskRows: Array(rows.prefix(8)),
            warmingRows: Array(rows.filter { $0.forecastState >= .warming && $0.forecastState < .leaking }.prefix(6)),
            detailModels: detailModels,
            duplicateCount: duplicateCount
        )
    }

    public func updatingEngineStatus(_ engineStatus: EngineStatusSnapshot, summary: RadarSummary) -> CompactConsoleSnapshot {
        CompactConsoleSnapshot(
            layoutMode: layoutMode,
            commandCenter: OverviewCommandCenterModel(summary: summary, engineStatus: engineStatus, duplicateCount: duplicateCount),
            engineStatus: engineStatus,
            allRows: allRows,
            topRiskRows: topRiskRows,
            warmingRows: warmingRows,
            detailModels: detailModels,
            duplicateCount: duplicateCount
        )
    }

    public static func sidebarSections(from rows: [CompactSidebarRowModel]) -> [CompactSidebarSection] {
        let attention = rows.filter { $0.level >= .watch || $0.forecastState >= .warming }
        let quiet = rows.filter { $0.level == .quiet && $0.forecastState == .quiet }
        return [
            CompactSidebarSection(kind: .attention, title: "Attention", count: attention.count, rows: attention),
            CompactSidebarSection(kind: .watched, title: "Watched", count: rows.count, rows: rows),
            CompactSidebarSection(kind: .quiet, title: "Quiet", count: quiet.count, rows: quiet),
            CompactSidebarSection(kind: .tools, title: "Tools", count: 4, rows: [])
        ]
    }
}

public struct RadarConsoleSnapshot: Equatable, Sendable {
    public let summary: RadarSummary
    public let families: [FamilyTriageViewModel]
    public let topRiskFamilies: [FamilyTriageViewModel]
    public let warmingFamilies: [FamilyTriageViewModel]
    public let detailPanels: [String: FamilyDetailPanelModel]
    public let incidentRows: [IncidentRowViewModel]
    public let ruleRows: [RuleRowViewModel]
    public let rulePreviews: [RuleMatchPreview]
    public let duplicateClusters: [DuplicateProcessCluster]
    public let duplicateRows: [DuplicateClusterViewModel]
    public let engine: EngineDiagnosticsViewModel
    public let compact: CompactConsoleSnapshot
    public let generatedAt: Date
    public let contentRevision: SnapshotContentRevision

    public static let empty = RadarConsoleSnapshot(
        summary: .empty,
        families: [],
        topRiskFamilies: [],
        warmingFamilies: [],
        detailPanels: [:],
        incidentRows: [],
        ruleRows: [],
        rulePreviews: [],
        duplicateClusters: [],
        duplicateRows: [],
        engine: .empty,
        compact: .empty,
        generatedAt: Date(timeIntervalSince1970: 0),
        contentRevision: .zero
    )

    public init(
        summary: RadarSummary,
        families: [FamilyTriageViewModel],
        topRiskFamilies: [FamilyTriageViewModel],
        warmingFamilies: [FamilyTriageViewModel],
        detailPanels: [String: FamilyDetailPanelModel],
        incidentRows: [IncidentRowViewModel],
        ruleRows: [RuleRowViewModel],
        rulePreviews: [RuleMatchPreview],
        duplicateClusters: [DuplicateProcessCluster] = [],
        duplicateRows: [DuplicateClusterViewModel] = [],
        engine: EngineDiagnosticsViewModel,
        compact: CompactConsoleSnapshot = .empty,
        generatedAt: Date,
        contentRevision: SnapshotContentRevision = .zero
    ) {
        self.summary = summary
        self.families = families
        self.topRiskFamilies = topRiskFamilies
        self.warmingFamilies = warmingFamilies
        self.detailPanels = detailPanels
        self.incidentRows = incidentRows
        self.ruleRows = ruleRows
        self.rulePreviews = rulePreviews
        self.duplicateClusters = duplicateClusters
        self.duplicateRows = duplicateRows
        self.engine = engine
        self.compact = compact
        self.generatedAt = generatedAt
        self.contentRevision = contentRevision
    }

    public static func build(
        families: [ProcessFamily],
        duplicateClusters: [DuplicateProcessCluster] = [],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        metrics: RadarPerformanceMetrics,
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        previous: RadarConsoleSnapshot?,
        generatedAt: Date
    ) -> RadarConsoleSnapshot {
        let contentRevision = SnapshotContentRevision.compute(
            families: families,
            summary: summary,
            incidents: incidents,
            rules: rules,
            duplicateClusters: duplicateClusters
        )
        let engine = EngineDiagnosticsViewModel(
            metrics: metrics,
            health: health,
            storeHealth: storeHealth,
            storeError: storeError,
            summary: summary,
            generatedAt: generatedAt
        )
        let engineStatus = EngineStatusSnapshot(
            engine: engine,
            summary: summary,
            health: health,
            generatedAt: generatedAt
        )
        if let previous, previous.contentRevision == contentRevision {
            return previous.updatingEngine(engine, health: health, generatedAt: generatedAt)
        }

        let previousPanels = previous?.detailPanels ?? [:]
        let classifier = DevProcessClassifier()
        var detailPanels: [String: FamilyDetailPanelModel] = [:]
        detailPanels.reserveCapacity(families.count * 2)
        for family in families {
            let classification = family.classification ?? classifier.classification(for: family)
            let culprit = CulpritAnalysis(family: family, classifier: classifier, classification: classification)
            let panel = FamilyDetailPanelModel(
                family: family,
                previous: previousPanels[family.familyKey],
                classifier: classifier,
                classification: classification,
                culprit: culprit
            )
            detailPanels[family.familyKey] = panel
            if detailPanels[family.signature.id] == nil {
                detailPanels[family.signature.id] = panel
            }
        }

        let triage = families
            .map { family in
                let classification = family.classification ?? classifier.classification(for: family)
                return FamilyTriageViewModel(
                    family: family,
                    classification: classification,
                    culprit: CulpritAnalysis(family: family, classifier: classifier, classification: classification)
                )
            }
            .sorted(by: Self.smartSort)
        let previews = rules.map { RuleMatchPreview(rule: $0, families: families) }
        let matchCounts = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0.matchCount) })
        let duplicateRows = DuplicateClusterViewModel.rows(from: duplicateClusters)

        return RadarConsoleSnapshot(
            summary: summary,
            families: triage,
            topRiskFamilies: Array(triage.prefix(8)),
            warmingFamilies: Array(triage.filter { $0.forecastState >= .warming && $0.forecastState < .leaking }.prefix(6)),
            detailPanels: detailPanels,
            incidentRows: incidents.map(IncidentRowViewModel.init(incident:)),
            ruleRows: rules.map { RuleRowViewModel(rule: $0, matchCount: matchCounts[$0.id, default: 0]) },
            rulePreviews: previews,
            duplicateClusters: duplicateClusters,
            duplicateRows: duplicateRows,
            engine: engine,
            compact: CompactConsoleSnapshot.build(
                summary: summary,
                triage: triage,
                detailPanels: detailPanels,
                engineStatus: engineStatus,
                duplicateCount: duplicateRows.count
            ),
            generatedAt: generatedAt,
            contentRevision: contentRevision
        )
    }

    public func updatingEngine(
        _ engine: EngineDiagnosticsViewModel,
        health: SamplerHealth? = nil,
        generatedAt: Date
    ) -> RadarConsoleSnapshot {
        let engineStatus = EngineStatusSnapshot(
            engine: engine,
            summary: summary,
            processText: health.map { "\($0.processCount)" } ?? compact.engineStatus.processText,
            generatedAt: generatedAt
        )
        return RadarConsoleSnapshot(
            summary: summary,
            families: families,
            topRiskFamilies: topRiskFamilies,
            warmingFamilies: warmingFamilies,
            detailPanels: detailPanels,
            incidentRows: incidentRows,
            ruleRows: ruleRows,
            rulePreviews: rulePreviews,
            duplicateClusters: duplicateClusters,
            duplicateRows: duplicateRows,
            engine: engine,
            compact: compact.updatingEngineStatus(engineStatus, summary: summary),
            generatedAt: generatedAt,
            contentRevision: contentRevision
        )
    }

    public func families(query: String, filter: RadarFilter, sort: RadarSort) -> [FamilyTriageViewModel] {
        let loweredQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return families
            .filter { item in
                switch filter {
                case .all: true
                case .attention: item.level >= .watch || item.forecastState >= .warming
                case .leaking: item.leakVelocity > 0 || item.forecastState >= .leaking
                case .killable: item.isKillable
                case .quiet: item.level == .quiet && item.forecastState == .quiet
                }
            }
            .filter { item in
                loweredQuery.isEmpty ||
                    item.displayName.lowercased().contains(loweredQuery) ||
                    item.subtitle.lowercased().contains(loweredQuery) ||
                    item.signature.canonicalPath.lowercased().contains(loweredQuery) ||
                    item.kindText.lowercased().contains(loweredQuery)
            }
            .sorted { lhs, rhs in
                switch sort {
                case .smart: Self.smartSort(lhs, rhs)
                case .memory:
                    lhs.memoryBytes == rhs.memoryBytes ? lhs.score > rhs.score : lhs.memoryBytes > rhs.memoryBytes
                case .cpu:
                    lhs.cpuPercent == rhs.cpuPercent ? lhs.score > rhs.score : lhs.cpuPercent > rhs.cpuPercent
                case .leak:
                    lhs.leakVelocity == rhs.leakVelocity ? lhs.score > rhs.score : lhs.leakVelocity > rhs.leakVelocity
                case .name:
                    lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
            }
    }

    public func sidebarSections(query: String, sort: RadarSort) -> [ConsoleSidebarSection] {
        let matches = families(query: query, filter: .all, sort: sort)
        let attention = matches.filter { $0.level >= .watch || $0.forecastState >= .warming }
        let quiet = matches.filter { $0.level == .quiet && $0.forecastState == .quiet }
        return [
            ConsoleSidebarSection(kind: .attention, title: "Attention", count: attention.count, families: attention),
            ConsoleSidebarSection(kind: .watched, title: "Watched", count: matches.count, families: matches),
            ConsoleSidebarSection(kind: .quiet, title: "Quiet", count: quiet.count, families: quiet),
            ConsoleSidebarSection(kind: .tools, title: "Tools", count: 4, families: [])
        ]
    }

    public func detailPanel(for familyKey: String) -> FamilyDetailPanelModel? {
        detailPanels[familyKey]
    }

    private static func smartSort(_ lhs: FamilyTriageViewModel, _ rhs: FamilyTriageViewModel) -> Bool {
        if lhs.forecastState != rhs.forecastState { return lhs.forecastState > rhs.forecastState }
        if lhs.level != rhs.level { return lhs.level > rhs.level }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.leakVelocity != rhs.leakVelocity { return lhs.leakVelocity > rhs.leakVelocity }
        if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        return lhs.cpuPercent > rhs.cpuPercent
    }
}

public struct ConsoleDerivedSnapshotKey: Hashable, Sendable {
    public let contentRevision: SnapshotContentRevision
    public let searchText: String
    public let familyFilter: RadarFilter
    public let familySort: RadarSort
    public let incidentText: String
    public let incidentFilter: RadarIncidentFilter
    public let incidentSort: RadarIncidentSort
    public let focusedSelection: RadarFocusedSelection

    public init(snapshot: RadarConsoleSnapshot, state: RadarConsoleState) {
        contentRevision = snapshot.contentRevision
        searchText = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        familyFilter = state.familyFilter
        familySort = state.familySort
        incidentText = state.incidentQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        incidentFilter = state.incidentQuery.filter
        incidentSort = state.incidentQuery.sort
        focusedSelection = state.focusedSelection
    }
}

public struct ConsoleDerivedSnapshot: Equatable, Sendable {
    public let key: ConsoleDerivedSnapshotKey
    public let familyRows: [FamilyTriageViewModel]
    public let compactFamilyRows: [CompactSidebarRowModel]
    public let incidentRows: [IncidentRowViewModel]
    public let duplicateRows: [DuplicateClusterViewModel]
    public let sidebarSections: [ConsoleSidebarSection]
    public let compactSidebarSections: [CompactSidebarSection]
    public let selectedPanel: FamilyDetailPanelModel?
    public let selectedCompactDetail: CompactFamilyDetailModel?
    public let cacheHitCount: Int

    public static let empty = ConsoleDerivedSnapshot(
        key: ConsoleDerivedSnapshotKey(snapshot: .empty, state: .default),
        familyRows: [],
        compactFamilyRows: [],
        incidentRows: [],
        duplicateRows: [],
        sidebarSections: [],
        compactSidebarSections: [],
        selectedPanel: nil,
        selectedCompactDetail: nil,
        cacheHitCount: 0
    )

    public init(
        key: ConsoleDerivedSnapshotKey,
        familyRows: [FamilyTriageViewModel],
        compactFamilyRows: [CompactSidebarRowModel],
        incidentRows: [IncidentRowViewModel],
        duplicateRows: [DuplicateClusterViewModel],
        sidebarSections: [ConsoleSidebarSection],
        compactSidebarSections: [CompactSidebarSection],
        selectedPanel: FamilyDetailPanelModel?,
        selectedCompactDetail: CompactFamilyDetailModel?,
        cacheHitCount: Int
    ) {
        self.key = key
        self.familyRows = familyRows
        self.compactFamilyRows = compactFamilyRows
        self.incidentRows = incidentRows
        self.duplicateRows = duplicateRows
        self.sidebarSections = sidebarSections
        self.compactSidebarSections = compactSidebarSections
        self.selectedPanel = selectedPanel
        self.selectedCompactDetail = selectedCompactDetail
        self.cacheHitCount = cacheHitCount
    }

    public static func build(
        snapshot: RadarConsoleSnapshot,
        incidents: [RadarIncident],
        state: RadarConsoleState,
        cacheHitCount: Int = 0
    ) -> ConsoleDerivedSnapshot {
        let key = ConsoleDerivedSnapshotKey(snapshot: snapshot, state: state)
        let familyRows = snapshot.families(
            query: state.searchText,
            filter: state.familyFilter,
            sort: state.familySort
        )
        let compactRows = familyRows.map(CompactSidebarRowModel.init(item:))
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let duplicateRows = snapshot.duplicateRows.filter { row in
            query.isEmpty ||
                row.title.lowercased().contains(query) ||
                row.subtitle.lowercased().contains(query) ||
                row.kindText.lowercased().contains(query) ||
                row.reasonText.lowercased().contains(query)
        }
        return ConsoleDerivedSnapshot(
            key: key,
            familyRows: familyRows,
            compactFamilyRows: compactRows,
            incidentRows: state.incidentQuery
                .apply(to: incidents)
                .map(IncidentRowViewModel.init(incident:)),
            duplicateRows: duplicateRows,
            sidebarSections: snapshot.sidebarSections(query: state.searchText, sort: state.familySort),
            compactSidebarSections: CompactConsoleSnapshot.sidebarSections(from: compactRows),
            selectedPanel: state.focusedSelection.familyKey.flatMap { snapshot.detailPanel(for: $0) },
            selectedCompactDetail: state.focusedSelection.familyKey.flatMap { snapshot.compact.detailModels[$0] },
            cacheHitCount: cacheHitCount
        )
    }

    public func withCacheHitCount(_ count: Int) -> ConsoleDerivedSnapshot {
        ConsoleDerivedSnapshot(
            key: key,
            familyRows: familyRows,
            compactFamilyRows: compactFamilyRows,
            incidentRows: incidentRows,
            duplicateRows: duplicateRows,
            sidebarSections: sidebarSections,
            compactSidebarSections: compactSidebarSections,
            selectedPanel: selectedPanel,
            selectedCompactDetail: selectedCompactDetail,
            cacheHitCount: count
        )
    }
}

public struct ConsoleDerivedSnapshotCache: Equatable, Sendable {
    public private(set) var snapshot: ConsoleDerivedSnapshot?
    public private(set) var hitCount: Int
    public private(set) var missCount: Int

    public init(
        snapshot: ConsoleDerivedSnapshot? = nil,
        hitCount: Int = 0,
        missCount: Int = 0
    ) {
        self.snapshot = snapshot
        self.hitCount = hitCount
        self.missCount = missCount
    }

    public mutating func update(
        snapshot source: RadarConsoleSnapshot,
        incidents: [RadarIncident],
        state: RadarConsoleState
    ) -> ConsoleDerivedSnapshot {
        let key = ConsoleDerivedSnapshotKey(snapshot: source, state: state)
        if let snapshot, snapshot.key == key {
            hitCount += 1
            return snapshot
        }
        missCount += 1
        let built = ConsoleDerivedSnapshot.build(
            snapshot: source,
            incidents: incidents,
            state: state,
            cacheHitCount: hitCount
        )
        snapshot = built
        return built
    }

    public func cached(
        snapshot source: RadarConsoleSnapshot,
        state: RadarConsoleState
    ) -> ConsoleDerivedSnapshot? {
        let key = ConsoleDerivedSnapshotKey(snapshot: source, state: state)
        guard snapshot?.key == key else {
            return nil
        }
        return snapshot
    }
}

public enum RadarFormat {
    public static func bytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
        return "\(max(1, Int(Double(bytes) / 1_048_576))) MB"
    }

    public static func signedBytes(_ bytes: Int64) -> String {
        let sign = bytes >= 0 ? "+" : "-"
        return "\(sign)\(Self.bytes(UInt64(abs(bytes))))"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    public static func signedPercent(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(Int(value.rounded()))%"
    }

    public static func leak(_ value: Double) -> String {
        "\(Int(value.rounded())) MB/min"
    }
}

private enum RadarRuleMatcher {
    static func matches(rule: RadarRule, family: ProcessFamily) -> Bool {
        guard rule.isEnabled else {
            return false
        }
        if let signatureID = rule.match.signatureID, signatureID != family.signature.id {
            return false
        }
        let command = family.root.commandLine.lowercased()
        let path = family.root.executablePath.lowercased()
        if let contains = rule.match.commandContains?.lowercased(), !command.contains(contains) {
            return false
        }
        if let contains = rule.match.pathContains?.lowercased(), !path.contains(contains) {
            return false
        }
        if family.score.level < rule.match.minimumLevel || family.score.value < rule.match.minimumScore {
            return false
        }
        if let leak = rule.match.minimumLeakVelocity, family.trend.memoryVelocityMegabytesPerMinute < leak {
            return false
        }
        if let count = rule.match.minimumIncidentCount, family.recentIncidentCount < count {
            return false
        }
        return true
    }
}
