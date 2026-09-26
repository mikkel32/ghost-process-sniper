import GhostProcessSniperCore
import SwiftUI

/// Consumes a worker-prepared projection; opening this screen does not rescan processes.
struct ConsoleThermalDashboard: View {
    let session: RadarConsoleSession

    var body: some View {
        ThermalInsightPanel(summary: session.monitor.thermalActivity,
            snapshot: session.monitor.thermals, observations: session.monitor.thermalObservations,
            // Asked only for a strong heat suspect and the open detail sheet;
            // the risk comes from the monitor's per-sample memo.
            stopTarget: { contributor in
                guard let family = session.family(forKey: contributor.familyKey) else { return nil }
                return ThermalStopTarget.resolve(for: contributor, family: family, risk: session.monitor.stopRisk(for: family))
            },
            onInspect: { session.focus(.family($0)) },
            onStop: { session.quickStop($0) },
            onBrowse: { session.browseFamilies() },
            onRefresh: { await session.monitor.refresh() })
    }
}
