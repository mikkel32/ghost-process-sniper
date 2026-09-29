import Foundation

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
    public let statusText: String
    public let signature: ProcessSignature
    public let title: String
    public let subtitle: String
    public let metricText: String
    public let scoreText: String
    public let scoreValue: Double
    public let heatText: String
    public let heatValue: Double
    public let systemImage: String
    public let level: GhostLevel
    public let forecastState: ForecastState
    public let forecastConfidence: Double
    public let helpText: String
    public let memoryBytes: UInt64
    public let radarSector: LiveRadarSector

    public init(item: FamilyTriageViewModel) {
        familyKey = item.familyKey
        statusText = item.assessment.status
        signature = item.signature
        title = item.displayName
        subtitle = item.assessment.reason
        metricText = item.gpuPercent > 0.5 ? "\(item.memoryText) · CPU \(item.cpuText) · GPU \(item.gpuText)" : "\(item.memoryText) · CPU \(item.cpuText)"
        scoreText = item.scoreText
        scoreValue = item.score
        heatText = item.heatText
        heatValue = item.heat
        systemImage = Self.icon(for: item.level)
        level = item.level
        forecastState = item.forecastState
        forecastConfidence = item.forecastConfidence
        memoryBytes = item.memoryBytes
        radarSector = LiveRadarSector.of(kind: item.kind, path: item.signature.canonicalPath)
        let gpuHelp = item.gpuPercent > 0.5 ? ", GPU \(item.gpuText)" : ""
        helpText = "\(item.assessment.reason). \(item.assessment.evidence)\n\(item.memoryText), \(item.cpuText)\(gpuHelp), \(item.leakText)"
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
        engineStatus: .empty,
        hasSampled: false
    )

    /// Only a model built before the first sample says the scan is starting;
    /// a scan that found nothing in scope is simply quiet.
    public init(summary: RadarSummary, engineStatus: EngineStatusSnapshot, duplicateCount: Int = 0, hasSampled: Bool = true) {
        title = "Command Center"
        if !hasSampled {
            statusText = "Starting scan"
        } else if summary.hotCount > 0 {
            statusText = "\(summary.hotCount) to review"
        } else {
            statusText = summary.level >= .watch ? "Observing" : "Monitoring"
        }
        subtitle = engineStatus.statusLine
        updatedText = engineStatus.updatedText
        level = summary.level
        // Memory is informational here; host pressure tints it in the app.
        // Engine timing lives in Settings › Diagnostics, not the user dashboard.
        chips = [
            FamilyMetricCard(title: "Families", value: "\(summary.familyCount)", systemImage: "rectangle.stack",
                             destination: .families, actionTitle: "Browse all"),
            FamilyMetricCard(title: "Needs review", value: "\(summary.hotCount)", systemImage: "flame",
                             level: summary.hotCount > 0 ? .hot : .quiet,
                             destination: .attention, actionTitle: "Review activity"),
            FamilyMetricCard(title: "Leaks", value: "\(summary.leakingCount)", systemImage: "chart.line.uptrend.xyaxis",
                             level: summary.leakingCount > 0 ? .watch : .quiet,
                             destination: .leaking, actionTitle: "Inspect growth"),
            FamilyMetricCard(title: "Duplicates", value: "\(duplicateCount)", systemImage: "doc.on.doc",
                             level: duplicateCount > 0 ? .watch : .quiet,
                             destination: .duplicates, actionTitle: "Review overlaps"),
            FamilyMetricCard(title: "Memory", value: RadarFormat.bytes(summary.totalMemoryBytes), systemImage: "memorychip",
                             destination: .memory, actionTitle: "Largest first")
        ]
    }
}

public struct RadarIntelligenceBrief: Equatable, Sendable {
    public let eyebrow: String
    public let title: String
    public let detail: String
    public let recommendation: String
    public let confidenceText: String
    public let evidence: [String]
    public let familyKey: String?
    public let familyName: String?
    public let actionTitle: String
    public let systemImage: String
    public let level: GhostLevel
    /// What stopping the target would do, when it is confirmed trouble the
    /// user can stop.
    public let stopConsequence: String?

    public static let empty = RadarIntelligenceBrief(
        eyebrow: "Live guidance",
        title: "Learning what is normal",
        detail: "The radar is collecting enough history to separate ordinary bursts from persistent problems.",
        recommendation: "No action is needed while the first baseline samples settle.",
        confidenceText: "Warming up",
        evidence: [],
        familyKey: nil,
        familyName: nil,
        actionTitle: "Review",
        systemImage: "wand.and.stars",
        level: .quiet
    )

    public init(
        eyebrow: String,
        title: String,
        detail: String,
        recommendation: String,
        confidenceText: String,
        evidence: [String],
        familyKey: String?,
        familyName: String?,
        actionTitle: String,
        systemImage: String,
        level: GhostLevel,
        stopConsequence: String? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
        self.confidenceText = confidenceText
        self.evidence = evidence
        self.familyKey = familyKey
        self.familyName = familyName
        self.actionTitle = actionTitle
        self.systemImage = systemImage
        self.level = level
        self.stopConsequence = stopConsequence
    }

    public static func build(
        summary: RadarSummary,
        topRiskRows: [CompactSidebarRowModel],
        warmingRows: [CompactSidebarRowModel],
        detailPanels: [String: FamilyDetailPanelModel]
    ) -> RadarIntelligenceBrief {
        // Confirmed trouble outranks a hotter spike that may still settle.
        let confirmed = topRiskRows.first { detailPanels[$0.familyKey]?.heatConfirmed == true }
        guard let row = confirmed ?? topRiskRows.first ?? warmingRows.first,
              let panel = detailPanels[row.familyKey]
        else {
            // Built from a finished sample, so no families means nothing in
            // scope, not a scan still running (that is `.empty`).
            let hasFamilies = summary.familyCount > 0
            return RadarIntelligenceBrief(
                eyebrow: "Live guidance",
                title: hasFamilies ? "No credible problems right now" : "Nothing to watch right now",
                detail: hasFamilies
                    ? "Current readings and trends show no credible leak, runaway load, or forgotten process tree."
                    : "The last scan found nothing in the radar's scope: no developer tools, and nothing heavy or duplicated.",
                recommendation: hasFamilies
                    ? "Keep working normally. The radar will surface a clear next step if behavior changes."
                    : "Nothing to do. To watch more of your Mac, widen the scope to Heavy or All in Settings.",
                confidenceText: "Continuous",
                evidence: hasFamilies ? ["Current readings", "Trend shape", "Host pressure"] : [],
                familyKey: nil,
                familyName: nil,
                actionTitle: "Review",
                systemImage: "checkmark.seal",
                level: .quiet
            )
        }

        let evidence = panel.heatEvidence.isEmpty
            ? panel.scoreComponents.sorted { $0.impact > $1.impact }.prefix(3).map(\.title)
            : Array(panel.heatEvidence.prefix(3))
        let hasCredibleForecastEscalation = row.forecastState >= .leaking && row.forecastConfidence >= 0.55
        let isConfirmedUrgent = row.level >= .hot && panel.heatConfirmed
        let isUnconfirmedHeat = row.level >= .hot && !panel.heatConfirmed
        let stopRisk = isConfirmedUrgent && panel.hasOwnedTargets ? panel.stopRisk : nil
        let consequence = stopRisk.flatMap(Self.consequence(of:))
        let recommendation: String
        if let consequence {
            recommendation = consequence
        } else if isConfirmedUrgent, panel.hasOwnedTargets {
            recommendation = "Review the process tree, then use Stop… only if this work is no longer needed."
        } else if isConfirmedUrgent {
            recommendation = "Inspect the process tree and its evidence; no user-owned target is available to stop."
        } else if isUnconfirmedHeat {
            recommendation = "Keep it under observation for another sample window. Activity is elevated, but persistence is not confirmed yet."
        } else if hasCredibleForecastEscalation {
            recommendation = "Inspect the emerging resource trend before it becomes urgent."
        } else {
            recommendation = "\(panel.forecastRecommendationTitle): \(panel.forecastRecommendationDetail)"
        }
        let confidenceText = panel.assessment.measurementText
        let eyebrow: String
        let actionTitle: String
        if isConfirmedUrgent {
            eyebrow = "Recommended now"
            actionTitle = stopRisk.map(Self.actionTitle(for:)) ?? "Review family"
        } else if isUnconfirmedHeat {
            eyebrow = "Confirming activity"
            actionTitle = "Inspect signals"
        } else {
            eyebrow = "Early warning"
            actionTitle = "Inspect early"
        }

        return RadarIntelligenceBrief(
            eyebrow: eyebrow,
            title: "\(row.title): \(panel.assessment.reasonInSentence)",
            detail: panel.assessment.evidence,
            recommendation: recommendation,
            confidenceText: confidenceText,
            evidence: evidence,
            familyKey: row.familyKey,
            familyName: row.title,
            actionTitle: actionTitle,
            systemImage: panel.verdict.systemImage,
            level: max(row.level, panel.verdict.level),
            stopConsequence: stopRisk?.headline
        )
    }

    /// The headline, then a supervisor that restarts the process, which makes
    /// stopping it pointless. Other hazards restate the headline ("asked to quit
    /// like ⌘Q"), so they stay in the stop preview.
    private static func consequence(of risk: KillRiskAssessment) -> String? {
        let respawn = risk.hazards.first { $0.kind == .respawn }?.detail
        let lead = risk.headline ?? respawn ?? risk.hazards.first?.detail
        let parts = [lead, respawn == lead ? nil : respawn].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Mirrors the stop planner's strategy choice for the cases it takes
    /// from the risk assessment alone.
    private static func actionTitle(for risk: KillRiskAssessment) -> String {
        if risk.appQuitPID != nil {
            return "Quit app"
        }
        if risk.kind == .dataStore || risk.kind == .containerRuntime {
            return "Stop safely"
        }
        if risk.supervisor != nil || risk.risks.contains(where: { $0.kind == .respawn }) {
            return "Review supervisor"
        }
        return "Review family"
    }
}

public struct CompactConsoleSnapshot: Equatable, Sendable {
    public let commandCenter: OverviewCommandCenterModel
    public let engineStatus: EngineStatusSnapshot
    public let allRows: [CompactSidebarRowModel]
    public let topRiskRows: [CompactSidebarRowModel]
    public let warmingRows: [CompactSidebarRowModel]
    public let duplicateCount: Int
    public let intelligenceBrief: RadarIntelligenceBrief
    /// False only before the first sample. Empty rows after it mean nothing
    /// in scope, which views must show as quiet rather than as a scan.
    public let hasSampled: Bool

    public static let empty = CompactConsoleSnapshot(
        commandCenter: .empty,
        engineStatus: .empty,
        allRows: [],
        topRiskRows: [],
        warmingRows: [],
        duplicateCount: 0,
        intelligenceBrief: .empty,
        hasSampled: false
    )

    public init(
        commandCenter: OverviewCommandCenterModel,
        engineStatus: EngineStatusSnapshot,
        allRows: [CompactSidebarRowModel],
        topRiskRows: [CompactSidebarRowModel],
        warmingRows: [CompactSidebarRowModel],
        duplicateCount: Int = 0,
        intelligenceBrief: RadarIntelligenceBrief = .empty,
        hasSampled: Bool = true
    ) {
        self.commandCenter = commandCenter
        self.engineStatus = engineStatus
        self.allRows = allRows
        self.topRiskRows = topRiskRows
        self.warmingRows = warmingRows
        self.duplicateCount = duplicateCount
        self.intelligenceBrief = intelligenceBrief
        self.hasSampled = hasSampled
    }

    public static func build(
        summary: RadarSummary,
        triage: [FamilyTriageViewModel],
        detailPanels: [String: FamilyDetailPanelModel],
        engineStatus: EngineStatusSnapshot,
        duplicateCount: Int = 0
    ) -> CompactConsoleSnapshot {
        let rows = triage.map(CompactSidebarRowModel.init(item:))
        return build(
            summary: summary,
            rows: rows,
            priorities: priorityRows(from: rows),
            detailPanels: detailPanels,
            engineStatus: engineStatus,
            duplicateCount: duplicateCount
        )
    }

    /// For callers that already built the rows and their priorities.
    static func build(
        summary: RadarSummary,
        rows: [CompactSidebarRowModel],
        priorities: (risk: [CompactSidebarRowModel], warming: [CompactSidebarRowModel]),
        detailPanels: [String: FamilyDetailPanelModel],
        engineStatus: EngineStatusSnapshot,
        duplicateCount: Int
    ) -> CompactConsoleSnapshot {
        let topRiskRows = priorities.risk
        let warmingRows = priorities.warming
        let intelligenceBrief = RadarIntelligenceBrief.build(
            summary: summary,
            topRiskRows: topRiskRows,
            warmingRows: warmingRows,
            detailPanels: detailPanels
        )
        return CompactConsoleSnapshot(
            commandCenter: OverviewCommandCenterModel(summary: summary, engineStatus: engineStatus, duplicateCount: duplicateCount),
            engineStatus: engineStatus,
            allRows: rows,
            topRiskRows: Array(topRiskRows.prefix(8)),
            warmingRows: Array(warmingRows.prefix(6)),
            duplicateCount: duplicateCount,
            intelligenceBrief: intelligenceBrief
        )
    }

    /// Shared by queue presentation and detail demand: the guidance target
    /// must always have a prepared panel, even when most panels are deferred.
    static func priorityRows(from rows: [CompactSidebarRowModel]) -> (risk: [CompactSidebarRowModel], warming: [CompactSidebarRowModel]) {
        let topRiskRows = rows
            .filter { row in
                row.level >= .hot || (row.forecastState >= .leaking && row.forecastConfidence >= 0.55)
            }
            .sorted { lhs, rhs in
                if lhs.level != rhs.level { return lhs.level > rhs.level }
                if lhs.heatValue != rhs.heatValue { return lhs.heatValue > rhs.heatValue }
                if lhs.scoreValue != rhs.scoreValue { return lhs.scoreValue > rhs.scoreValue }
                if lhs.forecastState != rhs.forecastState { return lhs.forecastState > rhs.forecastState }
                return lhs.id < rhs.id
            }
        let riskIDs = Set(topRiskRows.map(\.id))
        let warmingRows = rows.filter { row in
            !riskIDs.contains(row.id) &&
                (row.level == .watch || (row.forecastState >= .warming && row.forecastConfidence >= 0.42))
        }
        return (topRiskRows, warmingRows)
    }

    public func updatingEngineStatus(_ engineStatus: EngineStatusSnapshot, summary: RadarSummary) -> CompactConsoleSnapshot {
        CompactConsoleSnapshot(
            commandCenter: OverviewCommandCenterModel(summary: summary, engineStatus: engineStatus, duplicateCount: duplicateCount,
                                                      hasSampled: hasSampled),
            engineStatus: engineStatus,
            allRows: allRows,
            topRiskRows: topRiskRows,
            warmingRows: warmingRows,
            duplicateCount: duplicateCount,
            intelligenceBrief: intelligenceBrief,
            hasSampled: hasSampled
        )
    }

    public static func sidebarSections(from rows: [CompactSidebarRowModel]) -> [CompactSidebarSection] {
        let attention = rows.filter { $0.level >= .watch || $0.forecastState >= .warming }
        let attentionIDs = Set(attention.map(\.id))
        let stable = rows.filter { !attentionIDs.contains($0.id) }
        var sections = [
            CompactSidebarSection(kind: .attention, title: "Attention", count: attention.count, rows: attention)
        ]
        if !stable.isEmpty {
            sections.append(
                CompactSidebarSection(kind: .watched, title: "Stable", count: stable.count, rows: stable)
            )
        }
        return sections
    }
}
