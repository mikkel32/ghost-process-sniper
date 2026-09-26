import Foundation

/// A running process that matched a search but is not a tracked family.
public struct ProcessSearchRowModel: Identifiable, Equatable, Sendable {
    public let id: ProcessIdentity
    public let pid: Int32
    public let name: String
    public let nameHighlights: [Range<Int>]
    /// Why it matched, or what it runs when the name says it all.
    public let detail: String
    public let ownerName: String
    public let memoryBytes: UInt64
    public let memoryText: String
    /// Zero when the CPU could not be measured; the text shows a dash.
    public let cpuPercent: Double
    public let cpuText: String
    public let commandLine: String
    public let executablePath: String
    public let isSystemProcess: Bool
    /// Owned by the current user and not a system process, so it can go
    /// through the stop preview.
    public let isStoppable: Bool

    init(process: ProcessMetrics, match: ProcessSearchMatch, isMine: Bool) {
        id = process.identity
        pid = process.pid
        name = process.name
        nameHighlights = match.nameHighlights
        let command = process.commandLine == process.name ? "" : process.commandLine
        detail = match.reason ?? (command.isEmpty ? process.executablePath : command)
        ownerName = process.ownerName
        // Other users' processes cannot be measured without privileges;
        // a dash is honest where a zero would be a claim.
        memoryBytes = process.memoryForScoringBytes
        cpuPercent = process.cpuMeasurementStatus == .unavailable ? 0 : process.cpuPercent
        memoryText = process.memoryForScoringBytes > 0 ? RadarFormat.bytes(process.memoryForScoringBytes) : "\u{2014}"
        cpuText = process.cpuMeasurementStatus == .unavailable ? "\u{2014}" : RadarFormat.percent(process.cpuPercent)
        commandLine = process.commandLine
        executablePath = process.executablePath
        isSystemProcess = process.isSystemProcess
        isStoppable = isMine && !process.isSystemProcess
    }
}

public struct ConsoleSearchResults: Equatable, Sendable {
    public static let inactive = ConsoleSearchResults(
        query: .empty,
        familyMatches: [:],
        processRows: [],
        processMatchCount: 0,
        isApproximate: false
    )

    public let query: ProcessSearchQuery
    /// Highlights and match reasons for family rows, keyed by family key.
    public let familyMatches: [String: ProcessSearchMatch]
    /// Untracked processes that matched, best first, capped for display.
    public let processRows: [ProcessSearchRowModel]
    public let processMatchCount: Int
    /// Nothing matched exactly; the rows are typo-tolerant guesses.
    public let isApproximate: Bool

    public var isActive: Bool { !query.isEmpty }
    public var hiddenProcessCount: Int { processMatchCount - processRows.count }
}

/// Filters, searches and orders family rows and finds matching processes
/// the radar does not track.
enum ConsoleSearchProjection {
    static let processRowLimit = 150

    static func run(
        rows: [FamilyTriageViewModel],
        query: ProcessSearchQuery,
        filter: RadarFilter,
        sort: RadarSort,
        index: ProcessSearchIndex?
    ) -> (rows: [FamilyTriageViewModel], results: ConsoleSearchResults) {
        let filtered = filter == .all ? rows : rows.filter { $0.matches(filter) }
        guard !query.isEmpty else {
            // Snapshot rows already arrive in priority order.
            let ordered = sort == .smart ? filtered : filtered.sorted { FamilyTriageViewModel.areInIncreasingOrder($0, $1, by: sort) }
            return (ordered, .inactive)
        }

        let indexed = index?.familySubjects ?? [:]
        let missing = filtered.filter { indexed[$0.familyKey] == nil }
        let fallback = missing.isEmpty ? [:] : ProcessSearchIndex.subjects(for: missing)
        let familySubjects = filtered.compactMap { indexed[$0.familyKey] ?? fallback[$0.familyKey] }
        // Filter chips and radar-only conditions describe tracked families.
        let untracked = filter == .all && !query.requiresTrackedFamily ? index?.untracked ?? [] : []
        let outcome = ProcessSearchEngine.search(query, families: familySubjects, processes: untracked.map(\.subject))

        let byRelevance = query.ranksByRelevance && sort == .smart
        let matchedRows = outcome.families
            .map { (row: filtered[$0.key], match: $0.value) }
            .sorted { lhs, rhs in
                if byRelevance, lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                return FamilyTriageViewModel.areInIncreasingOrder(lhs.row, rhs.row, by: sort)
            }
        let processRows = outcome.processes
            .map { (entry: untracked[$0.key], match: $0.value) }
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                if lhs.entry.process.memoryForScoringBytes != rhs.entry.process.memoryForScoringBytes {
                    return lhs.entry.process.memoryForScoringBytes > rhs.entry.process.memoryForScoringBytes
                }
                return lhs.entry.process.pid < rhs.entry.process.pid
            }
            .prefix(processRowLimit)
            .map {
                ProcessSearchRowModel(process: $0.entry.process, match: $0.match, isMine: $0.entry.subject.flags.contains(.mine))
            }

        let results = ConsoleSearchResults(
            query: query,
            familyMatches: Dictionary(matchedRows.map { ($0.row.familyKey, $0.match) }, uniquingKeysWith: { first, _ in first }),
            processRows: processRows,
            processMatchCount: outcome.processes.count,
            isApproximate: outcome.isApproximate
        )
        return (matchedRows.map(\.row), results)
    }
}
