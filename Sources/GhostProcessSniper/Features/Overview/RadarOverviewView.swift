import GhostProcessSniperCore
import SwiftUI

/// Verdict first, queues above the fold. The shell reads only the thermal
/// band, which changes when the Mac becomes or stops being genuinely hot;
/// each section observes only the state it draws.
struct RadarOverviewView: View {
    let session: RadarConsoleSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            // A plain VStack: the chart and radar are built with the page,
            // not lazily in the middle of a scroll.
            VStack(alignment: .leading, spacing: 20) {
                ForEach(OverviewLayoutPlan.sections(thermal: session.overviewThermalBand), id: \.self) { section in
                    OverviewSection(id: section, session: session)
                }
            }
            .padding(24)
            .animation(RadarMotion.response(reduceMotion), value: session.overviewThermalBand)
        }
        .background { OverviewBackdrop(session: session).ignoresSafeArea() }
    }
}

private struct OverviewSection: View {
    let id: OverviewSectionID
    let session: RadarConsoleSession

    var body: some View {
        switch id {
        case .verdict: OverviewVerdictHero(session: session)
        case .queues: OverviewQueuesSection(session: session)
        case .metrics: OverviewMetricsView(session: session)
        case .thermals: ConsoleThermalDashboard(session: session)
        case .analytics: OverviewAnalyticsSection(session: session)
        }
    }
}

private struct OverviewBackdrop: View {
    let session: RadarConsoleSession
    var body: some View { AmbientLevelBackdrop(level: session.commandCenter.level) }
}
