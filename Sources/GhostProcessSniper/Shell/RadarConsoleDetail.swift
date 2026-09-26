import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleDetail: View {
    let session: RadarConsoleSession

    var body: some View {
        Group {
            switch session.state.focusedSelection {
            case .overview:
                RadarOverviewView(session: session)
            case .processes:
                ProcessBrowserView(session: session)
            case .family(let familyKey):
                if let family = session.family(forKey: familyKey) {
                    FamilyDetailConsoleView(
                        family: family,
                        detail: session.monitor.detailViewModel(signatureID: familyKey),
                        panel: session.monitor.consoleSnapshot.detailPanel(for: familyKey),
                        compact: session.selectedCompactDetail,
                        onSnooze: { minutes in session.snoozeSelected(minutes: minutes) },
                        onIgnore: { session.ignoreSelected() },
                        onKill: { session.prepareKill(family) },
                        thermals: session.monitor.thermals,
                        onPreviewProcess: { session.prepareKill(family, member: $0) },
                        stopRisk: KillRiskAssessor().assess(
                            KillWorkloadProfile(family: family, sample: session.monitor.sampledProcesses)
                        )
                    )
                } else {
                    ContentUnavailableView {
                        Label("Process no longer running", systemImage: "checkmark.circle")
                    } description: {
                        Text("This family has left the current scan. Browse running processes or check its history in Incidents.")
                    } actions: {
                        Button("Browse Processes") { session.browseFamilies() }
                            .buttonStyle(.borderedProminent)
                        Button("View Incidents") { session.focus(.incidents) }
                    }
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
        .navigationTitle(session.state.focusedSelection.navigationTitle)
    }
}

private extension RadarFocusedSelection {
    var navigationTitle: String {
        switch self {
        case .overview: "Command Center"
        case .processes: "All Processes"
        case .family: "Process Family"
        case .duplicates: "Duplicates"
        case .incidents: "Incidents"
        case .rules: "Rules"
        case .engine: "Engine"
        }
    }
}

struct RadarConsoleInspector: View {
    let session: RadarConsoleSession

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
