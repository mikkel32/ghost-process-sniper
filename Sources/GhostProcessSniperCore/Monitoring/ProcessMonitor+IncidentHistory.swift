import Foundation

extension ProcessMonitor {
    /// The incident log past the published 80, for the Incidents page's search
    /// and filters. The read runs on the store's actor, so nothing on the main
    /// actor waits for SQLite; nil when there is no store or it cannot be read.
    public func loadIncidentHistory() async -> IncidentHistory? {
        guard let store else { return nil }
        do {
            return try await store.incidentHistory()
        } catch {
            RadarLogger.store.error("Incident history unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
