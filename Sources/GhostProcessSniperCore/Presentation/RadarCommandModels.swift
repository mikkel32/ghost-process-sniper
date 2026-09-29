import Foundation

public enum RadarFocusedSelection: Hashable, Sendable {
    case overview
    case processes
    case family(String)
    case duplicates
    case incidents
    case rules
    case security
    case energy

    public var familyKey: String? {
        if case let .family(familyKey) = self {
            return familyKey
        }
        return nil
    }

    public var storageValue: String {
        switch self {
        case .overview: "overview"
        case .processes: "processes"
        case .family(let key): "family|\(key)"
        case .duplicates: "duplicates"
        case .incidents: "incidents"
        case .rules: "rules"
        case .security: "security"
        case .energy: "energy"
        }
    }

    public init(storageValue: String) {
        if storageValue.hasPrefix("family|"), storageValue.count > "family|".count {
            self = .family(String(storageValue.dropFirst("family|".count)))
            return
        }
        switch storageValue {
        case "processes": self = .processes
        case "duplicates": self = .duplicates
        case "incidents": self = .incidents
        case "rules": self = .rules
        case "security": self = .security
        case "energy": self = .energy
        // The Engine screen moved to Settings; a saved "engine" lands on Overview.
        default: self = .overview
        }
    }
}

public struct RadarConsoleState: Equatable, Sendable {
    public var focusedSelection: RadarFocusedSelection
    public var searchText: String
    public var familyFilter: RadarFilter
    public var familySort: RadarSort
    /// Literal direction of `familySort`: names A to Z, numbers smallest
    /// first. Only the process browser table applies it.
    public var familySortAscending: Bool
    public var incidentQuery: IncidentQuery
    public var showInspector: Bool

    public static let `default` = RadarConsoleState(
        focusedSelection: .overview,
        searchText: "",
        familyFilter: .all,
        familySort: .smart,
        incidentQuery: .default,
        showInspector: false
    )

    public init(
        focusedSelection: RadarFocusedSelection,
        searchText: String,
        familyFilter: RadarFilter,
        familySort: RadarSort,
        familySortAscending: Bool = false,
        incidentQuery: IncidentQuery,
        showInspector: Bool
    ) {
        self.focusedSelection = focusedSelection
        self.searchText = searchText
        self.familyFilter = familyFilter
        self.familySort = familySort
        self.familySortAscending = familySortAscending
        self.incidentQuery = incidentQuery
        self.showInspector = showInspector
    }
}

public enum RadarIncidentSort: String, CaseIterable, Sendable {
    case recent
    case severity
    case memory
    case recurrence
    case name

    public var label: String {
        switch self {
        case .recent: "Recent"
        case .severity: "Severity"
        case .memory: "Memory"
        case .recurrence: "Recurrence"
        case .name: "Name"
        }
    }
}

public struct IncidentQuery: Equatable, Sendable {
    public var text: String
    public var filter: RadarIncidentFilter
    public var sort: RadarIncidentSort
    /// Literal direction: names A to Z, numbers smallest first. False gives
    /// the usual view: names Z to A, newest, worst and biggest first.
    public var ascending: Bool
    public var limit: Int

    public static let `default` = IncidentQuery(text: "", filter: .all, sort: .recent, limit: IncidentHistory.publishedWindow)

    public init(
        text: String = "",
        filter: RadarIncidentFilter = .all,
        sort: RadarIncidentSort = .recent,
        ascending: Bool = false,
        limit: Int = IncidentHistory.publishedWindow
    ) {
        self.text = text
        self.filter = filter
        self.sort = sort
        self.ascending = ascending
        self.limit = limit
    }

    /// Whether the answer depends on incidents older than the newest published
    /// ones: a search, or a filter on how an incident ended or peaked. Active
    /// incidents are always among the newest rows, so that filter needs none.
    public var reachesHistory: Bool {
        if !ProcessSearchQuery(text).terms.isEmpty { return true }
        return filter == .resolved || filter == .critical
    }

    private func matches(_ incident: RadarIncident, query: ProcessSearchQuery) -> Bool {
        let filterMatches: Bool = switch filter {
        case .all:
            true
        case .active:
            incident.resolvedAt == nil
        case .resolved:
            incident.resolvedAt != nil
        case .critical:
            incident.level == .critical
        }
        guard filterMatches else {
            return false
        }
        return query.terms.isEmpty || query.matchesText([
            incident.familyName,
            incident.signature.canonicalPath,
            incident.reasons.joined(separator: " ")
        ])
    }

    public func apply(to incidents: [RadarIncident]) -> [RadarIncident] {
        let query = ProcessSearchQuery(text)
        let sorted = incidents.filter { matches($0, query: query) }.sorted(by: sortComparator)
        // Comparators order names ascending and everything else descending.
        let isAscending = sort == .name
        let ordered: [RadarIncident] = ascending == isAscending ? sorted : sorted.reversed()
        return ordered.prefix(max(0, limit)).map { $0 }
    }

    private func sortComparator(_ lhs: RadarIncident, _ rhs: RadarIncident) -> Bool {
        switch sort {
        case .recent:
            return lhs.lastSeenAt > rhs.lastSeenAt
        case .severity:
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            return lhs.maxScore > rhs.maxScore
        case .memory:
            return lhs.memoryBytes == rhs.memoryBytes ? lhs.maxScore > rhs.maxScore : lhs.memoryBytes > rhs.memoryBytes
        case .recurrence:
            // The hits each row shows, so the Hits column orders by what it displays.
            if lhs.occurrenceCount != rhs.occurrenceCount { return lhs.occurrenceCount > rhs.occurrenceCount }
            return lhs.lastSeenAt > rhs.lastSeenAt
        case .name:
            return lhs.familyName.localizedStandardCompare(rhs.familyName) == .orderedAscending
        }
    }
}

public struct RuleDraft: Equatable, Sendable {
    public var commandContains: String
    public var pathContains: String
    public var minimumLevel: GhostLevel
    public var action: RadarActionType

    public static let empty = RuleDraft(commandContains: "", pathContains: "", minimumLevel: .watch, action: .notify)

    public init(
        commandContains: String,
        pathContains: String = "",
        minimumLevel: GhostLevel = .watch,
        action: RadarActionType = .notify
    ) {
        self.commandContains = commandContains
        self.pathContains = pathContains
        self.minimumLevel = minimumLevel
        self.action = action
    }

    public var normalizedCommand: String {
        commandContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedPath: String {
        pathContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !normalizedCommand.isEmpty || !normalizedPath.isEmpty
    }

    public func makeRule(existingRules: [RadarRule]) -> RadarRule? {
        guard isValid else {
            return nil
        }

        let command = normalizedCommand
        let path = normalizedPath
        let duplicate = existingRules.contains { rule in
            !rule.isBuiltIn &&
                rule.action == action &&
                rule.match.minimumLevel == minimumLevel &&
                (rule.match.commandContains ?? "") == command &&
                (rule.match.pathContains ?? "") == path
        }
        guard !duplicate else {
            return nil
        }

        let nameSubject: String
        if !command.isEmpty {
            nameSubject = command
        } else {
            nameSubject = path
        }

        return RadarRule(
            name: "\(action.label): \(nameSubject)",
            isBuiltIn: false,
            match: RadarRuleMatch(
                commandContains: command.isEmpty ? nil : command,
                pathContains: path.isEmpty ? nil : path,
                minimumLevel: minimumLevel
            ),
            action: action
        )
    }
}

public enum RadarCommand: String, CaseIterable, Sendable {
    case refresh
    case openConsole
    case toggleInspector
    case copyReport
    case copyDiagnostics
    case find
    case nextFamily
    case previousFamily
    case snooze
    case ignore
    case killPreview
}

public struct RadarCommandAvailability: Equatable, Sendable {
    public let command: RadarCommand
    public let isEnabled: Bool
    public let reason: String?

    public init(command: RadarCommand, isEnabled: Bool, reason: String? = nil) {
        self.command = command
        self.isEnabled = isEnabled
        self.reason = reason
    }
}

public struct RadarCommandRouter: Sendable {
    public init() {}

    public func availability(
        for command: RadarCommand,
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> RadarCommandAvailability {
        let family = selectedFamily(selection: selection, families: families)
        switch command {
        case .refresh, .openConsole, .toggleInspector, .copyReport, .copyDiagnostics, .find:
            return RadarCommandAvailability(command: command, isEnabled: true)
        case .nextFamily, .previousFamily:
            return RadarCommandAvailability(
                command: command,
                isEnabled: !families.isEmpty,
                reason: families.isEmpty ? "No process families are visible." : nil
            )
        case .snooze, .ignore:
            return RadarCommandAvailability(
                command: command,
                isEnabled: family != nil,
                reason: family == nil ? "Select a family first." : nil
            )
        case .killPreview:
            let enabled = family?.ownedIdentities.isEmpty == false
            return RadarCommandAvailability(
                command: command,
                isEnabled: enabled,
                reason: enabled ? nil : "Select a killable family first."
            )
        }
    }

    public func selectedFamily(
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> ProcessFamily? {
        guard let familyKey = selection.familyKey else {
            return nil
        }
        return families.first { $0.familyKey == familyKey || $0.signature.id == familyKey }
    }

    /// Family selections always carry the concrete family key, because the
    /// prebuilt detail panels and the sidebar highlight are keyed by it. A
    /// signature id (as incidents store) is rewritten to the live family's
    /// key; anything else is returned unchanged.
    public func canonicalSelection(
        _ selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> RadarFocusedSelection {
        guard let key = selection.familyKey, !families.contains(where: { $0.familyKey == key }),
              let resolved = selectedFamily(selection: selection, families: families) else {
            return selection
        }
        return .family(resolved.familyKey)
    }
}

public struct RadarCommandCoordinator: Sendable {
    private let router: RadarCommandRouter

    public init(router: RadarCommandRouter = RadarCommandRouter()) {
        self.router = router
    }

    /// Navigation follows the visible query order, rather than the unfiltered monitor.
    public func selection(
        after selection: RadarFocusedSelection,
        orderedFamilyKeys keys: [String],
        direction: Int
    ) -> RadarFocusedSelection {
        guard !keys.isEmpty, direction != 0 else { return selection }
        guard let key = selection.familyKey, let index = keys.firstIndex(of: key) else {
            return .family(direction < 0 ? keys[keys.count - 1] : keys[0])
        }
        let offset = direction % keys.count
        let next = (index + offset + keys.count) % keys.count
        return .family(keys[next])
    }

    public func availability(
        for command: RadarCommand,
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> RadarCommandAvailability {
        router.availability(for: command, selection: selection, families: families)
    }

    public func selectedFamily(
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> ProcessFamily? {
        router.selectedFamily(selection: selection, families: families)
    }

    public func canonicalSelection(
        _ selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> RadarFocusedSelection {
        router.canonicalSelection(selection, families: families)
    }
}
