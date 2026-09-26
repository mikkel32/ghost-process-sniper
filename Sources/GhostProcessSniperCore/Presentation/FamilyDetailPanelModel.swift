import Foundation

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
    public let assessment: ProcessAssessment
    public let title: String
    public let kind: DevProcessKind
    public let kindReason: String
    public let commandLine: String
    public let rootPID: Int32
    public let level: GhostLevel
    public let scoreText: String
    public let heatText: String
    public let heatValue: Double
    public let heatConfidenceText: String
    public let heatEvidence: [String]
    public let heatConfirmed: Bool
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
        assessment = ProcessAssessment(family: family)
        title = family.displayName
        kind = classification.kind
        kindReason = classification.reason
        commandLine = family.root.commandLine
        rootPID = family.root.pid
        level = family.score.level
        scoreText = "\(Int(family.score.value.rounded()))"
        heatText = family.score.heat.valueText
        heatValue = family.score.heat.value
        heatConfidenceText = family.score.heat.confidenceText
        heatEvidence = family.score.heat.evidence
        heatConfirmed = family.score.heat.isConfirmed
        statusText = family.alertState.kind == .normal ? family.score.level.label : family.alertState.message
        memoryBytes = family.totalPhysicalFootprintBytes
        cpuPercent = family.totalCPUPercent
        gpuPercent = family.totalGPUPercent
        childCount = family.childCount
        var cards = [
            FamilyMetricCard(title: "Action", value: assessment.status, systemImage: "scope", level: family.score.level),
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
        let patternAnalysis = family.trend.resolvedPattern
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
            FamilyMetricCard(title: "Incidents", value: "\(family.recentIncidentCount)", systemImage: "waveform.path.ecg", level: family.recentIncidentCount > 0 ? .watch : .quiet)
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

