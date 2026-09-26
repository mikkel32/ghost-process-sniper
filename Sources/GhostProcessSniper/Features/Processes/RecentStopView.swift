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

    /// The narrated outcome: what happened, what was freed, what to do next.
    private var description: String {
        report.summary
    }
}
