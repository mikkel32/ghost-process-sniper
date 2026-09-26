import Foundation

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

    public init(item: FamilyTriageViewModel) {
        familyKey = item.familyKey
        statusText = item.assessment.status
        signature = item.signature
        title = item.displayName
        subtitle = item.assessment.cause
        metricText = item.gpuPercent > 0.5 ? "\(item.memoryText) · CPU \(item.cpuText) · GPU \(item.gpuText)" : "\(item.memoryText) · CPU \(item.cpuText)"
        scoreText = item.scoreText
        scoreValue = item.score
        heatText = item.heatText
        heatValue = item.heat
        systemImage = Self.icon(for: item.level)
        level = item.level
        forecastState = item.forecastState
        forecastConfidence = item.forecastConfidence
        let gpuHelp = item.gpuPercent > 0.5 ? ", GPU \(item.gpuText)" : ""
        helpText = "\(item.assessment.cause). \(item.assessment.evidence)\n\(item.memoryText), \(item.cpuText)\(gpuHelp), \(item.leakText)"
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
        if summary.familyCount == 0 {
            statusText = "Starting scan"
        } else if summary.hotCount > 0 {
            statusText = "\(summary.hotCount) to review"
        } else {
            statusText = summary.level >= .watch ? "Observing" : "Monitoring"
        }
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
    public let heatText: String
    public let heatValue: Double
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
        heatText = panel.heatText
        heatValue = panel.heatValue
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
        level: GhostLevel
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
    }

    public static func build(
        summary: RadarSummary,
        topRiskRows: [CompactSidebarRowModel],
        warmingRows: [CompactSidebarRowModel],
        detailPanels: [String: FamilyDetailPanelModel]
    ) -> RadarIntelligenceBrief {
        guard let row = topRiskRows.first ?? warmingRows.first,
              let panel = detailPanels[row.familyKey]
        else {
            let hasFamilies = summary.familyCount > 0
            return RadarIntelligenceBrief(
                eyebrow: hasFamilies ? "Live guidance" : "Getting started",
                title: hasFamilies ? "No credible problems right now" : "Learning what is normal",
                detail: hasFamilies
                    ? "Current readings and trends show no credible leak, runaway load, or forgotten process tree."
                    : "The radar is collecting enough history to separate ordinary bursts from persistent problems.",
                recommendation: hasFamilies
                    ? "Keep working normally. The radar will surface a clear next step if behavior changes."
                    : "No setup is required; useful guidance appears automatically as processes are observed.",
                confidenceText: hasFamilies ? "Continuous" : "Warming up",
                evidence: hasFamilies ? ["Current readings", "Trend shape", "Host pressure"] : [],
                familyKey: nil,
                familyName: nil,
                actionTitle: "Review",
                systemImage: hasFamilies ? "checkmark.seal" : "wand.and.stars",
                level: .quiet
            )
        }

        let evidence = panel.heatEvidence.isEmpty
            ? panel.scoreComponents.sorted { $0.impact > $1.impact }.prefix(3).map(\.title)
            : Array(panel.heatEvidence.prefix(3))
        let hasCredibleForecastEscalation = row.forecastState >= .leaking && row.forecastConfidence >= 0.55
        let isConfirmedUrgent = row.level >= .hot && panel.heatConfirmed
        let isUnconfirmedHeat = row.level >= .hot && !panel.heatConfirmed
        let recommendation: String
        if isConfirmedUrgent, panel.hasOwnedTargets {
            recommendation = "Review the process tree, then use Kill Preview only if this work is no longer needed."
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
            actionTitle = "Review family"
        } else if isUnconfirmedHeat {
            eyebrow = "Confirming activity"
            actionTitle = "Inspect signals"
        } else {
            eyebrow = "Early warning"
            actionTitle = "Inspect early"
        }

        return RadarIntelligenceBrief(
            eyebrow: eyebrow,
            title: "\(row.title): \(panel.assessment.cause.lowercased())",
            detail: panel.assessment.evidence,
            recommendation: recommendation,
            confidenceText: confidenceText,
            evidence: evidence,
            familyKey: row.familyKey,
            familyName: row.title,
            actionTitle: actionTitle,
            systemImage: panel.verdict.systemImage,
            level: max(row.level, panel.verdict.level)
        )
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
    public let intelligenceBrief: RadarIntelligenceBrief

    public static let empty = CompactConsoleSnapshot(
        layoutMode: .compact,
        commandCenter: .empty,
        engineStatus: .empty,
        allRows: [],
        topRiskRows: [],
        warmingRows: [],
        detailModels: [:],
        duplicateCount: 0,
        intelligenceBrief: .empty
    )

    public init(
        layoutMode: ConsoleLayoutMode,
        commandCenter: OverviewCommandCenterModel,
        engineStatus: EngineStatusSnapshot,
        allRows: [CompactSidebarRowModel],
        topRiskRows: [CompactSidebarRowModel],
        warmingRows: [CompactSidebarRowModel],
        detailModels: [String: CompactFamilyDetailModel],
        duplicateCount: Int = 0,
        intelligenceBrief: RadarIntelligenceBrief = .empty
    ) {
        self.layoutMode = layoutMode
        self.commandCenter = commandCenter
        self.engineStatus = engineStatus
        self.allRows = allRows
        self.topRiskRows = topRiskRows
        self.warmingRows = warmingRows
        self.detailModels = detailModels
        self.duplicateCount = duplicateCount
        self.intelligenceBrief = intelligenceBrief
    }

    public static func build(
        summary: RadarSummary,
        triage: [FamilyTriageViewModel],
        detailPanels: [String: FamilyDetailPanelModel],
        engineStatus: EngineStatusSnapshot,
        duplicateCount: Int = 0
    ) -> CompactConsoleSnapshot {
        let rows = triage.map(CompactSidebarRowModel.init(item:))
        let priorities = priorityRows(from: rows)
        let topRiskRows = priorities.risk
        let warmingRows = priorities.warming
        let detailModels = Dictionary(
            uniqueKeysWithValues: detailPanels.map { key, panel in
                (key, CompactFamilyDetailModel(panel: panel))
            }
        )
        let intelligenceBrief = RadarIntelligenceBrief.build(
            summary: summary,
            topRiskRows: topRiskRows,
            warmingRows: warmingRows,
            detailPanels: detailPanels
        )
        return CompactConsoleSnapshot(
            layoutMode: .compact,
            commandCenter: OverviewCommandCenterModel(summary: summary, engineStatus: engineStatus, duplicateCount: duplicateCount),
            engineStatus: engineStatus,
            allRows: rows,
            topRiskRows: Array(topRiskRows.prefix(8)),
            warmingRows: Array(warmingRows.prefix(6)),
            detailModels: detailModels,
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
            layoutMode: layoutMode,
            commandCenter: OverviewCommandCenterModel(summary: summary, engineStatus: engineStatus, duplicateCount: duplicateCount),
            engineStatus: engineStatus,
            allRows: allRows,
            topRiskRows: topRiskRows,
            warmingRows: warmingRows,
            detailModels: detailModels,
            duplicateCount: duplicateCount,
            intelligenceBrief: intelligenceBrief
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
