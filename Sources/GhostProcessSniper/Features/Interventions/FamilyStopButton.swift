import GhostProcessSniperCore
import SwiftUI

/// What a family page needs to offer a stop: what it would interrupt,
/// whether it may be stopped at all, and whether a preview is on its way.
struct FamilyStopState {
    let risk: KillRiskAssessment
    /// Why the family can never be stopped, such as Ghost running inside it.
    let blockedReason: String?
    /// A preview is being prepared; stop buttons show it and take no clicks.
    let isPreparing: Bool
    let stopSupervisor: () -> Void

    /// The supervisor that restarts the family as soon as it exits, when it
    /// is a process the user can stop; stopping it is what lasts.
    var restartingSupervisor: KillSupervisor? {
        guard let supervisor = risk.supervisor, supervisor.pid != nil,
              supervisor.kind.restartPolicy == .onExit else { return nil }
        return supervisor
    }
}

/// The family's stop button: a spinner in place of its icon while the
/// preview is prepared, and disabled with the reason when the family is
/// protected.
struct FamilyStopButton: View {
    let title: String
    let stop: FamilyStopState
    let hasOwnedTargets: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label {
                Text(title)
            } icon: {
                if stop.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "stop.circle")
                }
            }
        }
        .disabled(!hasOwnedTargets || stop.isPreparing || stop.blockedReason != nil)
        .help(help)
    }

    private var help: String {
        if let blockedReason = stop.blockedReason { return blockedReason }
        if stop.isPreparing { return "Preparing the preview\u{2026}" }
        return hasOwnedTargets ? "Preview exactly what will be stopped, then confirm" : "No live processes owned by you to target"
    }
}
