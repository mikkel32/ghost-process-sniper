import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleDetail: View {
    @Bindable var session: RadarConsoleSession

    var body: some View {
        switch session.state.focusedSelection {
        case .overview:
            RadarOverviewView(session: session)
        case .family(let familyKey):
            if let family = session.monitor.family(signatureID: familyKey) {
                FamilyDetailConsoleView(
                    family: family,
                    detail: session.monitor.detailViewModel(signatureID: familyKey),
                    panel: session.monitor.consoleSnapshot.detailPanel(for: familyKey),
                    compact: session.selectedCompactDetail,
                    onSnooze: { minutes in session.snoozeSelected(minutes: minutes) },
                    onIgnore: { session.ignoreSelected() },
                    onKill: { session.prepareKill(family) }
                )
            } else {
                RadarOverviewView(session: session)
            }
        case .duplicates:
            DuplicatesConsoleView(session: session)
        case .incidents:
            IncidentsConsoleView(session: session)
        case .rules:
            RulesConsoleView(session: session)
        case .engine:
            EngineConsoleView(
                monitor: session.monitor,
                refreshHistory: session.refreshCostHistory,
                onCopyDiagnostics: { session.copyDiagnostics() }
            )
        }
    }
}

struct RadarConsoleInspector: View {
    @Bindable var session: RadarConsoleSession

    var body: some View {
        if let family = session.selectedFamily {
            FamilyInspectorView(
                family: family,
                detail: session.selectedDetail,
                panel: session.selectedPanel
            )
        } else {
            EngineInspectorView(monitor: session.monitor)
        }
    }
}
