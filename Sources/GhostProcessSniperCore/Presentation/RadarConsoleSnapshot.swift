import Foundation

public enum ConsoleSidebarSectionKind: String, Codable, Sendable {
    case attention
    case watched
}

public struct RadarConsoleSnapshot: Equatable, Sendable {
    public let summary: RadarSummary
    public let families: [FamilyTriageViewModel]
    public let detailPanels: [String: FamilyDetailPanelModel]
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
        detailPanels: [:],
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
        detailPanels: [String: FamilyDetailPanelModel],
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
        self.detailPanels = detailPanels
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
        }.sorted { FamilyTriageViewModel.areInIncreasingOrder($0, $1, by: .smart) }
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

        let previews = rules.map { RuleMatchPreview(rule: $0, families: families, now: generatedAt) }
        let matchCounts = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0.matchCount) })
        let duplicateRows = DuplicateClusterViewModel.rows(from: duplicateClusters)

        return RadarConsoleSnapshot(
            summary: summary,
            families: triage,
            detailPanels: detailPanels,
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
            detailPanels: detailPanels,
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

    /// Rows matching a search, filter and sort, via the console's search
    /// engine but without a live process sample.
    public func families(query: String, filter: RadarFilter, sort: RadarSort) -> [FamilyTriageViewModel] {
        ConsoleSearchProjection.run(
            rows: families,
            query: ProcessSearchQuery(query),
            filter: filter,
            sort: sort,
            index: nil
        ).rows
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
}
