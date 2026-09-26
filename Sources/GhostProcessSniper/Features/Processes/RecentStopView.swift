import GhostProcessSniperCore
import SwiftUI

/// Where a family page lands after its family was stopped: what happened
/// and what was freed, instead of a generic "no longer running".
struct RecentStopView: View {
    let report: KillReport
    let browse: () -> Void
    let stopRespawner: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                report.succeeded ? "Stopped \(report.displayName)" : "\(report.displayName) partly stopped",
                systemImage: report.succeeded ? "checkmark.circle" : "exclamationmark.circle"
            )
        } description: {
            Text(description)
        } actions: {
            Button("Browse Processes", action: browse)
                .buttonStyle(.borderedProminent)
            if !report.respawnedPIDs.isEmpty {
                Button("Stop \(report.respawnedBy ?? "the Supervisor") Instead\u{2026}", action: stopRespawner)
            }
        }
    }

    private var description: String {
        let freed = report.realizedMemoryReclaimBytes
        guard freed > 0 else { return report.summary }
        return "\(report.summary) Freed \(RadarFormat.bytes(freed))."
    }
}
