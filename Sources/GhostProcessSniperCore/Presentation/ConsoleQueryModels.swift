import Foundation

public struct ConsoleDerivedSnapshotKey: Hashable, Sendable {
    public let contentRevision: SnapshotContentRevision
    public let searchText: String
    public let familyFilter: RadarFilter
    public let familySort: RadarSort
    public let familySortAscending: Bool
    public let incidentText: String
    public let incidentFilter: RadarIncidentFilter
    public let incidentSort: RadarIncidentSort
    public let incidentAscending: Bool
    public let incidentLimit: Int
    /// Which read of the incident log the request searches, 0 for the published
    /// list. The content revision hashes only the published rows, so without
    /// this a new read would be served the projection of the old one.
    public let incidentHistoryRevision: UInt64
    /// Live samples only matter while searching: results then follow every
    /// refresh, and an idle console does no projection work at all.
    public let sampleRevision: UInt64

    public init(_ request: ConsoleProjectionRequest) {
        let state = request.state
        contentRevision = request.source.contentRevision
        searchText = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        familyFilter = state.familyFilter
        familySort = state.familySort
        familySortAscending = state.familySortAscending
        incidentText = state.incidentQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        incidentFilter = state.incidentQuery.filter
        incidentSort = state.incidentQuery.sort
        incidentAscending = state.incidentQuery.ascending
        incidentLimit = state.incidentQuery.limit
        incidentHistoryRevision = request.incidentHistory?.revision ?? 0
        sampleRevision = searchText.isEmpty ? 0 : request.sampleRevision
    }
}

public struct ConsoleDerivedSnapshot: Equatable, Sendable {
    public let key: ConsoleDerivedSnapshotKey
    public let familyRows: [FamilyTriageViewModel]
    public let compactFamilyRows: [CompactSidebarRowModel]
    public let compactSidebarSections: [CompactSidebarSection]
    public let incidentRows: [IncidentRowViewModel]
    /// Which incidents `incidentRows` were drawn from, for the page's caption.
    public let incidentScope: IncidentListScope
    public let duplicateRows: [DuplicateClusterViewModel]
    public let search: ConsoleSearchResults
    /// Tracked families and untracked matches, ordered for the browser table.
    public let browserRows: [ProcessBrowserRowModel]
    /// Every tracked family in the snapshot the rows came from: the "of" in
    /// All Processes' "26 of 26". The live summary can be a scan ahead of the
    /// rows, and "26 of 25" or "175 of 26" is what the two made together.
    public let familyTotal: Int

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
        search: ConsoleSearchResults,
        browserRows: [ProcessBrowserRowModel] = [],
        incidentScope: IncidentListScope = .published(total: 0),
        familyTotal: Int = 0
    ) {
        self.key = key
        self.familyRows = familyRows
        self.compactFamilyRows = compactFamilyRows
        self.compactSidebarSections = compactSidebarSections
        self.incidentRows = incidentRows
        self.duplicateRows = duplicateRows
        self.search = search
        self.browserRows = browserRows
        self.incidentScope = incidentScope
        self.familyTotal = familyTotal
    }

    /// Projection without a live process sample: families are searched by
    /// their row text, and untracked processes are not available.
    public static func build(
        snapshot: RadarConsoleSnapshot,
        incidents: [RadarIncident],
        incidentHistory: IncidentHistory? = nil,
        state: RadarConsoleState
    ) -> ConsoleDerivedSnapshot {
        build(
            ConsoleProjectionRequest(source: snapshot, incidents: incidents, incidentHistory: incidentHistory, state: state),
            index: nil
        )
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
        // Rows arrive in priority order, so the first family per signature is the one to open.
        var liveKeys: [String: String] = [:]
        for row in snapshot.families where liveKeys[row.signature.id] == nil {
            liveKeys[row.signature.id] = row.familyKey
        }
        // The published list is capped for display; the log is searched whole.
        let searched = request.incidentHistory?.incidents ?? request.incidents
        var incidentQuery = state.incidentQuery
        if request.incidentHistory != nil { incidentQuery.limit = max(incidentQuery.limit, searched.count) }
        // Counted over everything loaded, so a filter or search never hides an episode from it.
        let patterns = IncidentPattern.bySignature(in: searched)
        return ConsoleDerivedSnapshot(
            key: ConsoleDerivedSnapshotKey(request),
            familyRows: projection.rows,
            compactFamilyRows: compactRows,
            compactSidebarSections: CompactConsoleSnapshot.sidebarSections(from: compactRows),
            incidentRows: incidentQuery
                .apply(to: searched)
                .map {
                    IncidentRowViewModel(incident: $0, liveFamilyKey: liveKeys[$0.signature.id], recurrence: patterns[$0.signature.id])
                },
            duplicateRows: duplicateRows,
            search: projection.results,
            browserRows: browserRows(request, rows: projection.rows, results: projection.results),
            incidentScope: request.incidentHistory.map { .history(total: $0.incidents.count, isTruncated: $0.isTruncated) }
                ?? .published(total: request.incidents.count),
            familyTotal: snapshot.families.count
        )
    }

    private static func browserRows(
        _ request: ConsoleProjectionRequest,
        rows: [FamilyTriageViewModel],
        results: ConsoleSearchResults
    ) -> [ProcessBrowserRowModel] {
        let families = Dictionary(request.families.map { ($0.familyKey, $0.root) }, uniquingKeysWith: { first, _ in first })
        let tracked = rows.map { row in
            let root = families[row.familyKey]
            return ProcessBrowserRowModel(
                family: row,
                match: results.familyMatches[row.familyKey],
                executablePath: root?.executablePath ?? row.signature.canonicalPath,
                commandLine: root?.commandLine ?? row.subtitle
            )
        }
        return ProcessBrowserRowModel.ordered(
            tracked: tracked,
            untracked: results.processRows.map(ProcessBrowserRowModel.init(process:)),
            sort: request.state.familySort,
            ascending: request.state.familySortAscending
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
