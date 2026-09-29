import Foundation

public struct FamilyMetricCard: Identifiable, Equatable, Sendable {
    public var id: String { title }

    public let title: String
    public let value: String
    public let systemImage: String
    public let level: GhostLevel
    /// Where the Overview card leads; nil for cards that only display a value.
    public let destination: OverviewMetricDestination?
    public let actionTitle: String?

    public init(
        title: String,
        value: String,
        systemImage: String,
        level: GhostLevel = .quiet,
        destination: OverviewMetricDestination? = nil,
        actionTitle: String? = nil
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.level = level
        self.destination = destination
        self.actionTitle = actionTitle
    }
}

public enum OverviewMetricDestination: Sendable, Equatable {
    case families, review, leaking, duplicates, memory

    /// The family list a card opens, so its count can be the list's length.
    /// Nil for the cards that go elsewhere: Duplicates has its own page and
    /// Memory sorts the list rather than filtering it.
    public var filter: RadarFilter? {
        switch self {
        case .families: .all
        case .review: .review
        case .leaking: .leaking
        case .duplicates, .memory: nil
        }
    }
}

public struct FamilyForensicsSummary: Equatable, Sendable {
    public let currentDirectory: String
    public let rootDirectory: String
    public let openFileText: String
    public let socketText: String
    public let portsText: String
    public let freshnessText: String
    public let isPartial: Bool
    public let notes: [String]

    public init(family: ProcessFamily) {
        currentDirectory = family.forensics.currentDirectory ?? "unavailable"
        rootDirectory = family.forensics.rootDirectory ?? "unavailable"
        openFileText = family.forensics.openFileCount.map { "\($0)" } ?? "locked"
        socketText = family.forensics.socketCount.map { "\($0)" } ?? "locked"
        portsText = family.forensics.listeningPorts.isEmpty ? "none" : family.forensics.listeningPorts.map(String.init).joined(separator: ", ")
        freshnessText = Self.freshnessText(family.forensicsFreshness)
        isPartial = family.forensics.isPartial
        notes = family.forensics.notes
    }

    public static func freshnessText(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .standard) ?? "deferred"
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

    /// How many processes the inspector lists before pointing to the Processes tab.
    public static let inspectorTreeLimit = 10

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
    public let brief: FamilyDecisionBrief
    public let processTree: [FamilyProcessTreeRow]
    /// The inspector's list, ranked once here so its view never sorts:
    /// the root and the biggest processes, at most `inspectorTreeLimit`.
    public let inspectorTree: [FamilyProcessTreeRow]
    public let forecastETASeconds: TimeInterval?
    public let scoreValue: Double
    public let isKillable: Bool
    public let hasOwnedTargets: Bool
    public let protectedPIDs: [Int32]
    public let lastScoredText: String
    /// What stopping this family would do. Nil when the panel was built
    /// without a process sample, which the supervisor lookup needs.
    public let stopRisk: KillRiskAssessment?
    /// Why the family's root can never be stopped, such as Ghost running
    /// inside it. Looked up from the same sample as `stopRisk`, and only
    /// meaningful when that is set.
    public let stopBlockedReason: String?
    /// Identifies the stop set `stopRisk` assessed, the same way the
    /// monitor's memo does, so a panel reuses it only while that set is
    /// unchanged. Nil when the panel has no assessment.
    let workloadKey: Int?

    /// Panels are stateless, so a panel built for one refresh can be reused
    /// by any later one with the same content.
    public init(
        family: ProcessFamily,
        sampleIndex: KillSampleIndex? = nil,
        classifier: DevProcessClassifier = DevProcessClassifier(),
        classification: DevClassification? = nil,
        culprit: CulpritAnalysis? = nil
    ) {
        self.init(
            family: family,
            stop: sampleIndex.map { StopFacts(family: family, index: $0) },
            classifier: classifier,
            classification: classification,
            culprit: culprit
        )
    }

    init(
        family: ProcessFamily,
        stop: StopFacts?,
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
        change = Self.change(trend: family.trend.samples)
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
        brief = FamilyDecisionBrief(family: family, verdict: verdict, assessment: assessment, pattern: patternAnalysis, culprit: culprit)
        // Growth figures need history behind them; calling a member "leaking" needs the verdict
        // that the "Stop only" suggestion uses, so the tree never contradicts the advice.
        let leaking = family.hasCredibleLeak
        let growing = leaking || family.trend.credibleMemoryVelocity > 0
        // A linked helper is out of the family's own stop plan, not out of reach of its own Stop.
        let tree = FamilyProcessTreeRow.build(members: family.members, root: family.root,
                                              ownedIdentities: family.ownedIdentities + family.linkedIdentities,
                                              growth: growing ? family.growth : [],
                                              culprit: leaking ? family.culprit?.identity : nil)
        processTree = tree
        inspectorTree = FamilyProcessTreeRow.largest(tree, limit: Self.inspectorTreeLimit)
        forecastETASeconds = family.forecast.etaSeconds
        scoreValue = family.score.value
        isKillable = family.isKillable
        hasOwnedTargets = !family.ownedIdentities.isEmpty
        protectedPIDs = family.protectedPIDs
        lastScoredText = Self.lastScoredText(family.lastScoredAt)
        stopRisk = stop?.risk
        stopBlockedReason = stop?.blockedReason
        workloadKey = stop?.key
    }

    /// Views format live dates with these, because a reused panel's strings
    /// freeze at the time it was built.
    public static func lastScoredText(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .standard) ?? "warming"
    }

    /// What stopping the family would do, from one sample. The stop set is
    /// every same-user descendant of the root, including processes of other
    /// families, so it is keyed like `StopRiskCache` and the family page
    /// agrees with the stop preview. A prepared panel is rebuilt only when the
    /// snapshot's content revision changes, which does not hash listening
    /// ports or Ghost's own parent chain, so a change in only those shows on
    /// the page one content change late; the stop preview always assesses
    /// the live sample.
    struct StopFacts {
        let risk: KillRiskAssessment
        let blockedReason: String?
        let key: Int

        /// Reuses `previous`'s assessment when it covered the same stop set;
        /// the protection floor is looked up on every sample.
        init(family: ProcessFamily, index: KillSampleIndex, reusing previous: FamilyDetailPanelModel? = nil) {
            let stopSet = KillWorkloadProfile.stopSet(root: family.root, index: index, family: family)
            key = StopRiskCache.key(root: family.root, stopSet: stopSet)
            if let previous, previous.workloadKey == key, let reused = previous.stopRisk {
                risk = reused
            } else {
                risk = KillRiskAssessor().assess(KillWorkloadProfile(root: family.root, stopSet: stopSet, index: index))
            }
            blockedReason = KillProtectionPolicy().neverReason(forRoot: family.root) { index.byPID[$0]?.parentPID }
        }
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

    /// Compares the newest trend sample with the newest one at least
    /// `changeWindow` older, so the delta means the same on every panel,
    /// however recently the panel was built.
    static let changeWindow: TimeInterval = 30

    static func change(trend samples: [TrendSample]) -> FamilyChangeSummary {
        guard samples.count >= 2, let latest = samples.last else {
            return .warming
        }
        let reference = samples.last { latest.date.timeIntervalSince($0.date) >= changeWindow } ?? samples[0]
        let memoryDelta = Int64(clamping: latest.memoryBytes) - Int64(clamping: reference.memoryBytes)
        let cpuDelta = latest.cpuPercent - reference.cpuPercent
        let level: GhostLevel
        if memoryDelta > 256 * 1_048_576 || cpuDelta > 25 {
            level = .hot
        } else if memoryDelta > 64 * 1_048_576 || cpuDelta > 8 {
            level = .watch
        } else {
            level = .quiet
        }

        var parts: [String] = []
        if abs(memoryDelta) >= 1_048_576 {
            parts.append("memory \(RadarFormat.signedBytes(memoryDelta))")
        }
        if abs(cpuDelta) >= 1 {
            parts.append("CPU \(RadarFormat.signedPercent(cpuDelta))")
        }
        let window = windowText(latest.date.timeIntervalSince(reference.date))
        let summary = parts.isEmpty
            ? "No material change in the last \(window)"
            : "\(parts.joined(separator: ", ")) in the last \(window)"
        return FamilyChangeSummary(
            memoryDeltaBytes: memoryDelta,
            cpuDelta: cpuDelta,
            childDelta: 0,
            summary: summary,
            level: level
        )
    }

    private static func windowText(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded()))
        return rounded < 90 ? "\(rounded) s" : "\(Int((seconds / 60).rounded())) min"
    }
}

