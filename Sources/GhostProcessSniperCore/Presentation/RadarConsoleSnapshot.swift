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
        generatedAt: Date,
        detailSignatures: Set<String>? = nil
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
        if let previous, previous.contentRevision == contentRevision,
           previous.coversDetails(families: families, requested: detailSignatures) {
            return previous.updatingEngine(engine, health: health, generatedAt: generatedAt)
        }

        let previousPanels = previous?.detailPanels ?? [:]
        let classifier = DevProcessClassifier()
        let triage = families.map { family in
            let classification = family.classification ?? classifier.classification(for: family)
            return FamilyTriageViewModel(family: family, classification: classification,
                                         culprit: CulpritAnalysis(family: family, classifier: classifier, classification: classification))
        }.sorted(by: Self.smartSort)
        var wantedKeys: Set<String>?
        if let detailSignatures {
            let priorities = CompactConsoleSnapshot.priorityRows(from: triage.map(CompactSidebarRowModel.init(item:)))
            var keys = Set(priorities.risk.prefix(8).map(\.familyKey))
            keys.formUnion(priorities.warming.prefix(6).map(\.familyKey))
            // A signature may describe hundreds of identical instances. Prepare
            // one representative, plus every explicitly requested runtime key.
            var signaturesSeen = Set<String>()
            for family in families {
                if detailSignatures.contains(family.familyKey) ||
                    (detailSignatures.contains(family.signature.id) && signaturesSeen.insert(family.signature.id).inserted) {
                    keys.insert(family.familyKey)
                }
            }
            wantedKeys = keys
        }
        var detailPanels: [String: FamilyDetailPanelModel] = [:]
        detailPanels.reserveCapacity((wantedKeys?.count ?? families.count) * 2)
        for family in families where wantedKeys?.contains(family.familyKey) ?? true {
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
                case .smart: return Self.smartSort(lhs, rhs)
                case .memory:
                    if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.id < rhs.id
                case .cpu:
                    if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.id < rhs.id
                case .leak:
                    if lhs.leakVelocity != rhs.leakVelocity { return lhs.leakVelocity > rhs.leakVelocity }
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.id < rhs.id
                case .name:
                    let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                    return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
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

    func coversDetails(families: [ProcessFamily], requested: Set<String>?) -> Bool {
        guard let requested else {
            return families.allSatisfy { detailPanels[$0.familyKey] != nil }
        }
        for key in requested where detailPanels[key] == nil {
            if families.contains(where: { $0.familyKey == key || $0.signature.id == key }) { return false }
        }
        return true
    }

    private static func smartSort(_ lhs: FamilyTriageViewModel, _ rhs: FamilyTriageViewModel) -> Bool {
        if lhs.level != rhs.level { return lhs.level > rhs.level }
        if lhs.heat != rhs.heat { return lhs.heat > rhs.heat }
        if lhs.forecastPriority != rhs.forecastPriority { return lhs.forecastPriority > rhs.forecastPriority }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.leakVelocity != rhs.leakVelocity { return lhs.leakVelocity > rhs.leakVelocity }
        if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
        return lhs.id < rhs.id
    }
}
