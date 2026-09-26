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
                    // Look up by the concrete key so an alias still finds the prebuilt panel.
                    let panel = session.detailPanel(for: family)
                    FamilyDetailConsoleView(
                        panel: panel,
                        // Panels carry the assessment and protection floor, built
                        // off the main actor over the same stop set as the
                        // monitor's memo; the memo covers a first frame without one.
                        stop: FamilyStopState(
                            risk: panel.stopRisk ?? session.monitor.stopRisk(for: family),
                            blockedReason: panel.stopRisk == nil
                                ? session.monitor.stopBlockedReason(for: family)
                                : panel.stopBlockedReason,
                            isPreparing: session.isPreparingIntervention,
                            stopSupervisor: { session.prepareKillSupervisor(of: family) }
                        ),
                        actions: FamilyPageActions(session: session, family: family),
                        lastScoredAt: family.lastScoredAt,
                        forensicsFreshness: family.forensicsFreshness
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
                        Button("Back") { session.goBackOrOverview() }
                            .buttonStyle(.borderedProminent)
                            .help("Back (⌘[)")
                        Button("Browse Processes") { session.browseFamilies() }
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
            FamilyInspectorView(panel: session.detailPanel(for: family), forensicsFreshness: family.forensicsFreshness)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
        }
    }
}
