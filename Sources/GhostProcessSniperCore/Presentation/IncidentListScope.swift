import Foundation

/// Which incidents the Incidents page drew its rows from, and how it says so.
/// Only the newest 80 are published, so a page that reads "80 events shown"
/// or "No Matching Incidents" without saying that would look like the whole log.
public enum IncidentListScope: Equatable, Sendable {
    /// The published window: the newest incidents every refresh reads.
    case published(total: Int)
    /// The log read for a search or filter: all of it, or the newest `total`
    /// when the table held more than one read returns.
    case history(total: Int, isTruncated: Bool)

    public var readsHistory: Bool {
        if case .history = self { return true }
        return false
    }

    /// The Incidents page subtitle. `shown` is the row count after the query.
    public func caption(shown: Int, query: IncidentQuery, isLoadingHistory: Bool) -> String {
        if isLoadingHistory {
            return "Searching the whole log\u{2026}"
        }
        switch self {
        case let .history(total, isTruncated):
            return "Showing \(shown) of \(isTruncated ? "the newest " : "")\(total) logged events"
        case let .published(total):
            let isFull = total >= IncidentHistory.publishedWindow
            if query.reachesHistory {
                // The log could not be read, so the rows are only the window's.
                return "Showing \(shown) of \(isFull ? "the latest " : "")\(total) events"
            }
            if isFull, query.filter == .all {
                return "Latest \(shown) events; search or filter to look further back"
            }
            return "\(shown) events shown"
        }
    }

    /// The Overview card's subtitle, which used to print the window size as a total.
    public var overviewText: String {
        switch self {
        case let .published(total):
            total >= IncidentHistory.publishedWindow ? "latest \(IncidentHistory.publishedWindow)" : "\(total) total"
        case let .history(total, _):
            "\(total) total"
        }
    }
}
