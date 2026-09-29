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
                    // Panels carry the assessment and protection floor, built
                    // off the main actor over the same stop set as the
                    // monitor's memo; the memo covers a first frame without one.
                    let stopFacts = panel.stopRisk.map { (risk: $0, blockedReason: panel.stopBlockedReason) }
                        ?? session.monitor.stopFacts(for: family)
                    FamilyDetailConsoleView(
                        panel: panel,
                        stop: FamilyStopState(
                            risk: stopFacts.risk,
                            blockedReason: stopFacts.blockedReason,
                            isPreparing: session.isPreparingIntervention,
                            stopSupervisor: { session.prepareKillSupervisor(of: family) }
                        ),
                        actions: FamilyPageActions(session: session, family: family),
                        lastScoredAt: family.lastScoredAt,
                        forensicsFreshness: family.forensicsFreshness,
                        monitor: session.monitor
                    )
                } else if let remembered = session.recentStops[familyKey] {
                    // The family has left the scan, so whatever the stop
                    // listed as still running is not: no stale "still open".
                    let report = remembered.settlingSurvivors()
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
            case .security:
                SentinelConsoleView(session: session)
            case .energy:
                EnergyConsoleView(session: session)
            }
        }
        // The column's hosting view re-asks for its minimum size on every
        // update; answering without measuring the page halves the redraw cost.
        .sizedIndependentlyOfContent(minimum: CGSize(width: 460, height: 320))
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
        case .security: "Security"
        case .energy: "Energy"
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
