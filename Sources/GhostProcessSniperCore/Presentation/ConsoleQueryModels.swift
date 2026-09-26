import Foundation

public struct ConsoleDerivedSnapshotKey: Hashable, Sendable {
    public let contentRevision: SnapshotContentRevision
    public let searchText: String
    public let familyFilter: RadarFilter
    public let familySort: RadarSort
    public let incidentText: String
    public let incidentFilter: RadarIncidentFilter
    public let incidentSort: RadarIncidentSort
    public let incidentLimit: Int

    public init(snapshot: RadarConsoleSnapshot, state: RadarConsoleState) {
        contentRevision = snapshot.contentRevision
        searchText = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        familyFilter = state.familyFilter
        familySort = state.familySort
        incidentText = state.incidentQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        incidentFilter = state.incidentQuery.filter
        incidentSort = state.incidentQuery.sort
        incidentLimit = state.incidentQuery.limit
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
        let normalizedSearch = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesDefaultFamilyProjection = normalizedSearch.isEmpty && state.familyFilter == .all && state.familySort == .smart
        let familyRows = usesDefaultFamilyProjection
            ? snapshot.families
            : snapshot.families(query: normalizedSearch, filter: state.familyFilter, sort: state.familySort)
        let compactRows = usesDefaultFamilyProjection
            ? snapshot.compact.allRows
            : familyRows.map(CompactSidebarRowModel.init(item:))
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let duplicateRows = snapshot.duplicateRows.filter { row in
            query.isEmpty ||
                row.title.lowercased().contains(query) ||
                row.subtitle.lowercased().contains(query) ||
                row.kindText.lowercased().contains(query) ||
                row.reasonText.lowercased().contains(query)
        }
        let attentionRows = familyRows.filter { $0.level >= .watch || $0.forecastState >= .warming }
        let attentionIDs = Set(attentionRows.map(\.id))
        let stableRows = familyRows.filter { !attentionIDs.contains($0.id) }
        let sidebarSections = [
            ConsoleSidebarSection(kind: .attention, title: "Attention", count: attentionRows.count, families: attentionRows),
            ConsoleSidebarSection(kind: .watched, title: "Stable", count: stableRows.count, families: stableRows),
            ConsoleSidebarSection(kind: .tools, title: "Tools", count: 4, families: [])
        ]
        return ConsoleDerivedSnapshot(
            key: key,
            familyRows: familyRows,
            compactFamilyRows: compactRows,
            incidentRows: state.incidentQuery
                .apply(to: incidents)
                .map(IncidentRowViewModel.init(incident:)),
            duplicateRows: duplicateRows,
            sidebarSections: sidebarSections,
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

    public func selecting(
        _ selection: RadarFocusedSelection,
        from source: RadarConsoleSnapshot,
        cacheHitCount: Int? = nil
    ) -> ConsoleDerivedSnapshot {
        ConsoleDerivedSnapshot(
            key: key,
            familyRows: familyRows,
            compactFamilyRows: compactFamilyRows,
            incidentRows: incidentRows,
            duplicateRows: duplicateRows,
            sidebarSections: sidebarSections,
            compactSidebarSections: compactSidebarSections,
            selectedPanel: selection.familyKey.flatMap { source.detailPanel(for: $0) },
            selectedCompactDetail: selection.familyKey.flatMap { source.compact.detailModels[$0] },
            cacheHitCount: cacheHitCount ?? self.cacheHitCount
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
            let selected = snapshot.selecting(state.focusedSelection, from: source, cacheHitCount: hitCount)
            self.snapshot = selected
            return selected
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
        return snapshot?.selecting(state.focusedSelection, from: source)
    }
}

