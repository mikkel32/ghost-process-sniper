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
    /// Live samples only matter while searching: results then follow every
    /// refresh, and an idle console does no projection work at all.
    public let sampleRevision: UInt64

    public init(_ request: ConsoleProjectionRequest) {
        let state = request.state
        contentRevision = request.source.contentRevision
        searchText = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        familyFilter = state.familyFilter
        familySort = state.familySort
        incidentText = state.incidentQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        incidentFilter = state.incidentQuery.filter
        incidentSort = state.incidentQuery.sort
        incidentLimit = state.incidentQuery.limit
        sampleRevision = searchText.isEmpty ? 0 : request.sampleRevision
    }
}

public struct ConsoleDerivedSnapshot: Equatable, Sendable {
    public let key: ConsoleDerivedSnapshotKey
    public let familyRows: [FamilyTriageViewModel]
    public let compactFamilyRows: [CompactSidebarRowModel]
    public let compactSidebarSections: [CompactSidebarSection]
    public let incidentRows: [IncidentRowViewModel]
    public let duplicateRows: [DuplicateClusterViewModel]
    public let search: ConsoleSearchResults

    public static let empty = ConsoleDerivedSnapshot(
        key: ConsoleDerivedSnapshotKey(ConsoleProjectionRequest(source: .empty, incidents: [], state: .default)),
        familyRows: [],
        compactFamilyRows: [],
        compactSidebarSections: [],
        incidentRows: [],
        duplicateRows: [],
        search: .inactive
    )

    public init(
        key: ConsoleDerivedSnapshotKey,
        familyRows: [FamilyTriageViewModel],
        compactFamilyRows: [CompactSidebarRowModel],
        compactSidebarSections: [CompactSidebarSection],
        incidentRows: [IncidentRowViewModel],
        duplicateRows: [DuplicateClusterViewModel],
        search: ConsoleSearchResults
    ) {
        self.key = key
        self.familyRows = familyRows
        self.compactFamilyRows = compactFamilyRows
        self.compactSidebarSections = compactSidebarSections
        self.incidentRows = incidentRows
        self.duplicateRows = duplicateRows
        self.search = search
    }

    /// Projection without a live process sample: families are searched by
    /// their row text, and untracked processes are not available.
    public static func build(
        snapshot: RadarConsoleSnapshot,
        incidents: [RadarIncident],
        state: RadarConsoleState
    ) -> ConsoleDerivedSnapshot {
        build(ConsoleProjectionRequest(source: snapshot, incidents: incidents, state: state), index: nil)
    }

    static func build(_ request: ConsoleProjectionRequest, index: ProcessSearchIndex?) -> ConsoleDerivedSnapshot {
        let snapshot = request.source
        let state = request.state
        let query = ProcessSearchQuery(state.searchText)
        let usesDefaultFamilyProjection = query.isEmpty && state.familyFilter == .all && state.familySort == .smart
        let projection = usesDefaultFamilyProjection
            ? (rows: snapshot.families, results: ConsoleSearchResults.inactive)
            : ConsoleSearchProjection.run(
                rows: snapshot.families,
                query: query,
                filter: state.familyFilter,
                sort: state.familySort,
                index: index
            )
        let compactRows = usesDefaultFamilyProjection
            ? snapshot.compact.allRows
            : projection.rows.map(CompactSidebarRowModel.init(item:))
        let duplicateRows = query.terms.isEmpty
            ? snapshot.duplicateRows
            : snapshot.duplicateRows.filter { query.matchesText([$0.title, $0.subtitle, $0.kindText, $0.reasonText]) }
        return ConsoleDerivedSnapshot(
            key: ConsoleDerivedSnapshotKey(request),
            familyRows: projection.rows,
            compactFamilyRows: compactRows,
            compactSidebarSections: CompactConsoleSnapshot.sidebarSections(from: compactRows),
            incidentRows: state.incidentQuery
                .apply(to: request.incidents)
                .map(IncidentRowViewModel.init(incident:)),
            duplicateRows: duplicateRows,
            search: projection.results
        )
    }
}

/// Reuses the last projection until its inputs change. Selection is not an
/// input, so moving between families never re-runs a search.
public struct ConsoleDerivedSnapshotCache: Sendable {
    public private(set) var snapshot: ConsoleDerivedSnapshot?
    public private(set) var hitCount = 0
    public private(set) var missCount = 0
    private var searchIndex = ProcessSearchIndex()

    public init() {}

    public mutating func update(_ request: ConsoleProjectionRequest) -> ConsoleDerivedSnapshot {
        let key = ConsoleDerivedSnapshotKey(request)
        if let snapshot, snapshot.key == key {
            hitCount += 1
            return snapshot
        }
        missCount += 1
        var index: ProcessSearchIndex?
        if !key.searchText.isEmpty {
            searchIndex.update(
                rows: request.source.families,
                families: request.families,
                processes: request.processes,
                sampleRevision: request.sampleRevision,
                contentRevision: request.source.contentRevision
            )
            index = searchIndex
        }
        let built = ConsoleDerivedSnapshot.build(request, index: index)
        snapshot = built
        return built
    }
}
