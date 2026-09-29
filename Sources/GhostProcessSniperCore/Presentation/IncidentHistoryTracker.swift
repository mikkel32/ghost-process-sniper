import Foundation

/// When the console reads the incident log, keeps it and lets go of it. The
/// log is read only while the Incidents page is searched or filtered, once
/// per change to the incident table, and never by two reads at once. A pure
/// value the console session drives, so the rules are testable without a store.
public struct IncidentHistoryTracker: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case none
        /// Read the log, then pass the result back with this ticket.
        case load(ticket: UInt64)
    }

    /// The last log read, kept while a newer read is in flight so the list
    /// does not blank between two writes.
    public private(set) var history: IncidentHistory?
    private var loadingTicket: UInt64?
    private var lastTicket: UInt64 = 0
    /// A failed read is not repeated at every sample; the next search tries again.
    private var failed = false

    public var isLoading: Bool { loadingTicket != nil }
    /// Nothing to show yet, as opposed to a newer read replacing rows on screen.
    public var isAwaitingFirstRead: Bool { isLoading && history == nil }

    public init() {}

    /// - Parameters:
    ///   - isWanted: the Incidents page is showing a query that reaches the log.
    ///   - incidentWrites: `StoreWriteStats.incidentWrites` as last published.
    public mutating func update(isWanted: Bool, incidentWrites: Int) -> Step {
        guard isWanted else {
            reset()
            return .none
        }
        if isLoading || failed { return .none }
        // A read taken after the published counter was still current: the
        // store can write once more between a flush and its publish.
        if let history, history.writeCount >= incidentWrites { return .none }
        lastTicket &+= 1
        loadingTicket = lastTicket
        return .load(ticket: lastTicket)
    }

    /// Returns whether the result was taken, so the caller projects again.
    /// A result for a search that ended, or an older read, is dropped.
    @discardableResult
    public mutating func received(_ loaded: IncidentHistory?, ticket: UInt64) -> Bool {
        guard loadingTicket == ticket else { return false }
        loadingTicket = nil
        guard let loaded else {
            failed = true
            return false
        }
        history = loaded
        return true
    }

    /// Forgets the log and any read in flight, for a console that is hidden
    /// or on another page: it holds none of it.
    public mutating func reset() {
        history = nil
        loadingTicket = nil
        failed = false
    }
}
