import Foundation

public enum RadarFocusedSelection: Hashable, Sendable {
    case overview
    case family(String)
    case duplicates
    case incidents
    case rules
    case engine

    public var signatureID: String? {
        familyKey
    }

    public var familyKey: String? {
        if case let .family(familyKey) = self {
            return familyKey
        }
        return nil
    }
}

public struct RadarConsoleState: Equatable, Sendable {
    public var focusedSelection: RadarFocusedSelection
    public var searchText: String
    public var familyFilter: RadarFilter
    public var familySort: RadarSort
    public var incidentQuery: IncidentQuery
    public var showInspector: Bool

    public static let `default` = RadarConsoleState(
        focusedSelection: .engine,
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
        incidentQuery: IncidentQuery,
        showInspector: Bool
    ) {
        self.focusedSelection = focusedSelection
        self.searchText = searchText
        self.familyFilter = familyFilter
        self.familySort = familySort
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
    public var limit: Int

    public static let `default` = IncidentQuery(text: "", filter: .all, sort: .recent, limit: 80)

    public init(
        text: String = "",
        filter: RadarIncidentFilter = .all,
        sort: RadarIncidentSort = .recent,
        limit: Int = 80
    ) {
        self.text = text
        self.filter = filter
        self.sort = sort
        self.limit = limit
    }

    public func matches(_ incident: RadarIncident) -> Bool {
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

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return true
        }
        return incident.familyName.lowercased().contains(query) ||
            incident.signature.canonicalPath.lowercased().contains(query) ||
            incident.reasons.joined(separator: " ").lowercased().contains(query)
    }

    public func apply(to incidents: [RadarIncident]) -> [RadarIncident] {
        incidents
            .filter(matches)
            .sorted(by: sortComparator)
            .prefix(max(0, limit))
            .map { $0 }
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
            return lhs.occurrenceCount == rhs.occurrenceCount ? lhs.lastSeenAt > rhs.lastSeenAt : lhs.occurrenceCount > rhs.occurrenceCount
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
}

public struct RadarCommandCoordinator: Sendable {
    private let router: RadarCommandRouter

    public init(router: RadarCommandRouter = RadarCommandRouter()) {
        self.router = router
    }

    public func availability(
        for command: RadarCommand,
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> RadarCommandAvailability {
        router.availability(for: command, selection: selection, families: families)
    }

    public func availabilityMap(
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> [RadarCommand: RadarCommandAvailability] {
        Dictionary(uniqueKeysWithValues: RadarCommand.allCases.map { command in
            (command, availability(for: command, selection: selection, families: families))
        })
    }

    public func selectedFamily(
        selection: RadarFocusedSelection,
        families: [ProcessFamily]
    ) -> ProcessFamily? {
        router.selectedFamily(selection: selection, families: families)
    }

    public func selection(
        after selection: RadarFocusedSelection,
        families: [ProcessFamily],
        direction: Int
    ) -> RadarFocusedSelection {
        guard !families.isEmpty else {
            return selection
        }
        let sorted = families.sorted { lhs, rhs in
            if lhs.score.level != rhs.score.level { return lhs.score.level > rhs.score.level }
            if lhs.score.value != rhs.score.value { return lhs.score.value > rhs.score.value }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        guard let familyKey = selection.familyKey,
              let currentIndex = sorted.firstIndex(where: { $0.familyKey == familyKey || $0.signature.id == familyKey })
        else {
            return .family(sorted[0].familyKey)
        }
        let next = (currentIndex + direction + sorted.count) % sorted.count
        return .family(sorted[next].familyKey)
    }
}
