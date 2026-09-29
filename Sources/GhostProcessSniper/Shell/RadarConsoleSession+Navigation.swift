import Foundation
import GhostProcessSniperCore

/// Back/Forward, Quick Stop and the return after a stop. Every stop still
/// goes through prepareKill and the preview sheet.
extension RadarConsoleSession {
    func recordVisit(_ selection: RadarFocusedSelection) {
        history.visit(selection)
    }

    func goBack() {
        pruneHistory()
        guard let selection = history.goBack() else { return }
        showHistoryPage(selection)
    }

    func goForward() {
        pruneHistory()
        guard let selection = history.goForward() else { return }
        showHistoryPage(selection)
    }

    /// The "Process no longer running" page's way out.
    func goBackOrOverview() {
        pruneHistory()
        if let selection = history.goBack() {
            showHistoryPage(selection)
        } else {
            focus(.overview)
        }
    }

    private func pruneHistory() {
        var live = Set<String>()
        for family in monitor.families {
            live.insert(family.familyKey)
            live.insert(family.signature.id)
        }
        history.prune(liveFamilyKeys: live)
    }

    /// Moves without recording: the page is already in the history.
    private func showHistoryPage(_ selection: RadarFocusedSelection) {
        state.focusedSelection = selection
        updateFocusedFamilies()
        updateCanStopSelection()
        schedulePanelUpdate()
    }

    /// Opens the stop preview for the action's target, on its own page.
    func quickStop(_ action: QuickStopAction) {
        // One stop at a time; a second click must not move the page under the first.
        guard action.isAvailable, preparingStop == nil, pendingKill == nil, !refusesStopDuringCull() else { return }
        focus(.family(action.targetFamilyKey))
        prepareKill(
            familyKey: action.targetFamilyKey,
            name: action.redirectedFromName == nil ? action.displayName : nil,
            redirectedFrom: action.redirectedFromName
        )
    }

    /// The page before the stopped family's own page, or the current page
    /// when the stop started elsewhere (a Risk Queue context menu).
    func returnSelection(afterStopping family: ProcessFamily) -> RadarFocusedSelection {
        let current = state.focusedSelection
        guard let key = current.familyKey, key == family.familyKey || key == family.signature.id else {
            return current
        }
        return history.previous ?? .overview
    }

    /// The sheet's close. After a stop that left nothing running, the page
    /// would only say "Process no longer running", so go back instead.
    func closeStopSheet() {
        let closing = pendingKill
        pendingKill = nil
        guard let closing, let result = lastStopResult, result.pendingID == closing.id else { return }
        lastStopResult = nil
        guard let message = result.report.cleanStopToastText else { return }
        var destination = closing.returnSelection ?? .overview
        if let key = destination.familyKey, family(forKey: key) == nil {
            destination = .overview
        }
        focus(destination)
        showToast(message)
    }

    /// Closes the sheet so another preview can open in its place, such as
    /// the process still holding a port: no return navigation, no toast.
    func dismissStopSheetForFollowUp() {
        pendingKill = nil
        lastStopResult = nil
    }

    /// A preview that takes longer than this is stuck; say so rather than
    /// leaving the click unanswered.
    func expirePreparation(_ stop: PreparingStop) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.preparingStop?.id == stop.id else { return }
            self.preparingStop = nil
            self.showToast("Couldn't prepare the stop preview — try again", systemImage: "exclamationmark.triangle")
        }
    }

    func updateOverviewThermalBand() {
        let now = Date()
        let band = thermalBandTracker.update(
            thermalState: ThermalPressureReading.current(at: now).state,
            temperature: ThermalTemperatureAssessment.evaluate(
                snapshot: monitor.thermals, observations: monitor.thermalObservations, at: now),
            at: now
        )
        if band != overviewThermalBand { overviewThermalBand = band }
    }

    func updateOverviewQueueLayout() {
        let compact = compactSnapshot
        let layout = queueLayoutTracker.update(
            riskCount: compact.riskCount, warmingCount: compact.warmingRows.count,
            hasSampled: compact.hasSampled, at: Date()
        )
        if layout != overviewQueueLayout { overviewQueueLayout = layout }
    }
}

extension RadarConsoleSession {
    /// The Quick Stop for the family on screen, when the advisor has one.
    var selectedQuickStop: QuickStopAction? {
        state.focusedSelection.familyKey.flatMap { quickStops.actions[$0] }
    }

    /// The toolbar and ⇧⌘⌫: the same risk-aware stop the Overview offers,
    /// falling back to a plain preview for families off the queues.
    func stopSelected() {
        if let action = selectedQuickStop, action.isAvailable {
            quickStop(action)
        } else {
            prepareKillSelected()
        }
    }
}
