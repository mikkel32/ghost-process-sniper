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
                if let family = session.monitor.family(signatureID: familyKey) {
                    // Look up by the concrete key so an alias still finds the prebuilt panel.
                    let panel = session.monitor.consoleSnapshot.detailPanel(for: family.familyKey)
                        ?? FamilyDetailPanelModel(family: family, previous: nil)
                    FamilyDetailConsoleView(
                        panel: panel,
                        stopRisk: KillRiskAssessor().assess(
                            KillWorkloadProfile(family: family, sample: session.monitor.sampledProcesses)
                        ),
                        actions: FamilyPageActions(session: session, family: family)
                    )
                } else if let report = session.recentStops[familyKey] {
                    RecentStopView(
                        report: report,
                        browse: { session.browseFamilies() },
                        stopRespawner: { session.prepareKillRespawner(of: report) }
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
        }
    }
}

struct RadarConsoleInspector: View {
    let session: RadarConsoleSession

    var body: some View {
        if let family = session.selectedFamily {
            FamilyInspectorView(panel: session.selectedPanel ?? FamilyDetailPanelModel(family: family, previous: nil))
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
        }
    }
}
