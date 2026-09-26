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
    /// Unresolved incidents, for the sidebar badge; the rows themselves
    /// are projected on demand.
    public let activeIncidentCount: Int
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
        activeIncidentCount: 0,
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
        activeIncidentCount: Int = 0,
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
        self.activeIncidentCount = activeIncidentCount
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
        detailSignatures: Set<String>? = nil,
        processes: [ProcessMetrics] = []
    ) -> RadarConsoleSnapshot {
        build(
            families: families, duplicateClusters: duplicateClusters, summary: summary,
            incidents: incidents, rules: rules, metrics: metrics, health: health,
            storeHealth: storeHealth, storeError: storeError, previous: previous,
            generatedAt: generatedAt, detailSignatures: detailSignatures, processes: processes,
            contentRevision: SnapshotContentRevision.compute(
                families: families,
                summary: summary,
                incidents: incidents,
                rules: rules,
                duplicateClusters: duplicateClusters
            )
        )
    }

    /// `contentRevision` must be the revision of exactly these inputs; the
    /// publish payload computes it once and passes it here. `processes` is
    /// the whole sample, which stop assessments search for supervisors.
    static func build(
        families: [ProcessFamily],
        duplicateClusters: [DuplicateProcessCluster],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        metrics: RadarPerformanceMetrics,
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        previous: RadarConsoleSnapshot?,
        generatedAt: Date,
        detailSignatures: Set<String>?,
        processes: [ProcessMetrics],
        contentRevision: SnapshotContentRevision
    ) -> RadarConsoleSnapshot {
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
        let rows = families.map { family in
            FamilyTriageViewModel(family: family, classification: family.classification ?? classifier.classification(for: family))
        }
        let keys = rows.map(FamilyTriageViewModel.SmartSortKey.init)
        let triage = keys.indices.sorted { keys[$0] < keys[$1] }.map { rows[$0] }
        let compactRows = triage.map(CompactSidebarRowModel.init(item:))
        let priorities = CompactConsoleSnapshot.priorityRows(from: compactRows)

        var wantedKeys: Set<String>?
        if let detailSignatures {
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
        // The PID index is built at most once per snapshot; an assessment
        // only reruns when a family's stop set changed.
        var sampleIndex: KillSampleIndex?
        func stopFacts(for family: ProcessFamily) -> FamilyDetailPanelModel.StopFacts? {
            guard !processes.isEmpty else {
                return nil
            }
            let index = sampleIndex ?? KillSampleIndex(processes)
            sampleIndex = index
            return FamilyDetailPanelModel.StopFacts(family: family, index: index, reusing: previousPanels[family.familyKey])
        }
        var detailPanels: [String: FamilyDetailPanelModel] = [:]
        detailPanels.reserveCapacity((wantedKeys?.count ?? families.count) * 2)
        for family in families where wantedKeys?.contains(family.familyKey) ?? true {
            let classification = family.classification ?? classifier.classification(for: family)
            let culprit = CulpritAnalysis(family: family, classifier: classifier, classification: classification)
            let panel = FamilyDetailPanelModel(
                family: family,
                stop: stopFacts(for: family),
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
            activeIncidentCount: incidents.reduce(0) { $1.resolvedAt == nil ? $0 + 1 : $0 },
            engine: engine,
            compact: CompactConsoleSnapshot.build(
                summary: summary,
                rows: compactRows,
                priorities: priorities,
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
            activeIncidentCount: activeIncidentCount,
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
