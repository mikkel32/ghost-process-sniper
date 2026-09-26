import Foundation

/// Carries start times across refreshes: an alert that keeps its kind keeps
/// its `since`, and a suggestion that keeps its id keeps its `createdAt`.
/// Scoring rebuilds both every tick, which would otherwise make every alert
/// look brand new and every card look replaced.
struct RadarContinuity: Sendable {
    private struct Memory: Sendable {
        var alertKind: AlertStateKind
        var alertSince: Date
        var suggestionDates: [UUID: Date]
    }

    private var memory: [String: Memory] = [:]

    mutating func apply(to families: [ProcessFamily]) -> [ProcessFamily] {
        if memory.count > families.count + 64 {
            let activeKeys = Set(families.map(\.familyKey))
            memory = memory.filter { activeKeys.contains($0.key) }
        }
        return families.map { family in
            let key = family.familyKey
            let previous = memory[key]
            var alert = family.alertState
            if let previous, previous.alertKind == alert.kind, previous.alertSince != alert.since {
                alert = AlertState(kind: alert.kind, message: alert.message, since: previous.alertSince)
            }
            var suggestionsChanged = false
            let suggestions = family.suggestions.map { suggestion in
                guard let createdAt = previous?.suggestionDates[suggestion.id], createdAt != suggestion.createdAt else {
                    return suggestion
                }
                suggestionsChanged = true
                return RadarActionSuggestion(
                    id: suggestion.id,
                    type: suggestion.type,
                    title: suggestion.title,
                    detail: suggestion.detail,
                    ruleID: suggestion.ruleID,
                    createdAt: createdAt
                )
            }
            memory[key] = Memory(
                alertKind: alert.kind,
                alertSince: alert.since,
                suggestionDates: Dictionary(suggestions.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
            )
            guard suggestionsChanged || alert != family.alertState else { return family }
            return family.enriched(suggestions: suggestions, alertState: alert)
        }
    }
}
