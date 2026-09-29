import GhostProcessSniperCore

/// The incident log behind the Incidents page's search and filters. The
/// refresh publishes only the newest 80 incidents, so a query that reaches
/// past them reads the log on demand; `IncidentHistoryTracker` decides when.
extension RadarConsoleSession {
    /// Runs with every projection request. Starts a read when the page needs
    /// one, drops the log when it does not, and returns the log the request
    /// should search (nil for the published list).
    func incidentHistoryForProjection() -> IncidentHistory? {
        let isWanted = state.focusedSelection == .incidents && state.incidentQuery.reachesHistory
        let step = incidentHistoryTracker.update(
            isWanted: isWanted,
            incidentWrites: monitor.storeHealth.writeStats.incidentWrites
        )
        if case let .load(ticket) = step {
            let monitor = monitor
            // A read that outlives its search is dropped by its ticket when it lands.
            Task { [weak self] in
                let loaded = await monitor.loadIncidentHistory()
                guard let self else { return }
                if incidentHistoryTracker.received(loaded, ticket: ticket) {
                    scheduleQueryUpdate()
                }
                syncIncidentSearchState()
            }
        }
        syncIncidentSearchState()
        return incidentHistoryTracker.history
    }

    /// The page says it is searching until the rows on screen are the log's,
    /// not only until the log has been read, so the caption never claims the
    /// window while a projection of the log is a moment away.
    func syncIncidentSearchState() {
        let isSearching = incidentHistoryTracker.isAwaitingFirstRead
            || (incidentHistoryTracker.history != nil && !incidentScope.readsHistory)
        if isSearchingIncidentLog != isSearching { isSearchingIncidentLog = isSearching }
    }

    /// The full incident behind a row. The published copy is the freshest,
    /// and a row found only by searching the log comes from the log.
    func incident(id: RadarIncident.ID) -> RadarIncident? {
        monitor.incidents.first { $0.id == id }
            ?? incidentHistoryTracker.history?.incidents.first { $0.id == id }
    }
}
