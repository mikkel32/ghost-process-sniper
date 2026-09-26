import GhostProcessSniperCore
import SwiftUI

/// Consumes a worker-prepared projection; opening this screen does not rescan processes.
struct ConsoleThermalDashboard: View {
    let session: RadarConsoleSession

    var body: some View {
        ThermalInsightPanel(summary: session.monitor.thermalActivity,
            snapshot: session.monitor.thermals, observations: session.monitor.thermalObservations,
            stopTarget: { ThermalStopTarget.resolve(for: $0, family: session.monitor.family(signatureID: $0.familyKey)) },
            onInspect: { session.focus(.family($0)) },
            onStop: { session.prepareKill(familyKey: $0) },
            onBrowse: { session.browseFamilies() },
            onRefresh: { await session.monitor.refresh() })
    }
}
