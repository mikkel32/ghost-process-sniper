import Foundation

/// How often one app's episodes recur in the loaded incidents, as facts: a
/// count, a typical length and a peak range. It never says the episodes are
/// harmless: the scorer raises a family's score for recurring incidents (the
/// "Recurring family" component and the "N x recurring incident" alert), so a
/// pane that called nine repeats routine would contradict the score beside it.
public struct IncidentPattern: Equatable, Sendable {
    /// Episodes of this signature in the list the pattern was drawn from.
    public let episodes: Int
    /// "9 since Sep 22": the oldest of them is a fact about the list, and it
    /// stays true however much older history there is.
    public let episodesText: String
    /// The middle length of the episodes that ended; nil under two of them,
    /// because one is only its own length.
    public let lengthText: String?
    /// "195 MB to 3.8 GB", written like the table's Memory column.
    public let peakText: String

    /// Patterns for every signature with at least two episodes in `incidents`.
    /// Pass the list as loaded, before any search or filter, so hiding rows
    /// never hides episodes from the count.
    public static func bySignature(in incidents: [RadarIncident]) -> [String: IncidentPattern] {
        var groups: [String: [RadarIncident]] = [:]
        for incident in incidents {
            groups[incident.signature.id, default: []].append(incident)
        }
        return groups.compactMapValues { group in
            group.count >= 2 ? IncidentPattern(group) : nil
        }
    }

    private init(_ group: [RadarIncident]) {
        episodes = group.count
        let oldest = group.lazy.map(\.startedAt).min() ?? .distantPast
        episodesText = "\(group.count) since \(oldest.formatted(date: .abbreviated, time: .omitted))"

        let ended = group.compactMap { incident in
            incident.resolvedAt.map { $0.timeIntervalSince(incident.startedAt) }
        }.sorted()
        if ended.count >= 2 {
            let middle = ended.count / 2
            let median = ended.count.isMultiple(of: 2) ? (ended[middle - 1] + ended[middle]) / 2 : ended[middle]
            lengthText = EnergyFormat.duration(median)
        } else {
            lengthText = nil
        }

        let peaks = group.map(\.memoryBytes)
        let smallest = RadarFormat.bytes(peaks.min() ?? 0)
        let largest = RadarFormat.bytes(peaks.max() ?? 0)
        peakText = smallest == largest ? smallest : "\(smallest) to \(largest)"
    }
}
