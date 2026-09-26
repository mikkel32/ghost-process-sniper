import GhostProcessSniperCore

/// Which detail panel a family page shows. The refresh prepares panels for
/// the top rows; the projection worker builds one for any other selection
/// (see `schedulePanelUpdate`).
extension RadarConsoleSession {
    /// Resolve once per body. This builds on the main actor only for the
    /// frame before the worker's panel arrives.
    func detailPanel(for family: ProcessFamily) -> FamilyDetailPanelModel {
        monitor.consoleSnapshot.detailPanel(for: family.familyKey)
            ?? workerPanel(for: family.familyKey)
            ?? FamilyDetailPanelModel(family: family)
    }

    private func workerPanel(for familyKey: String) -> FamilyDetailPanelModel? {
        guard let panel = queries.selectedPanel, panel.familyKey == familyKey else { return nil }
        return panel
    }
}
