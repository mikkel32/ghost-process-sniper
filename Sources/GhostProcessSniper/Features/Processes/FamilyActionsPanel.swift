import GhostProcessSniperCore
import SwiftUI

struct FamilyActionsPanel: View {
    let panel: FamilyDetailPanelModel
    let stop: FamilyStopState
    let onSnooze: (TimeInterval) -> Void
    let onIgnore: () -> Void
    let onKill: () -> Void

    private var risk: KillRiskAssessment { stop.risk }

    var body: some View {
        RadarSection(title: "Actions", subtitle: "advisory only") {
            if !panel.suggestions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(panel.suggestions) { suggestion in
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: suggestion.type))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.caption.weight(.semibold))
                                Text(suggestion.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }

            if let blockedReason = stop.blockedReason {
                Label(blockedReason, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let headline = risk.headline {
                Label(headline, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The most serious consequence, so it is seen before the preview.
            if let hazard = risk.hazards.max(by: { $0.severity < $1.severity }), hazard.severity > .info {
                KillRiskCard(risk: hazard)
            }

            HStack {
                Menu {
                    FamilySnoozeMenu(snooze: onSnooze)
                } label: {
                    Label("Snooze", systemImage: "moon")
                }
                .menuStyle(.button)
                .fixedSize()
                Button(action: onIgnore) {
                    Label("Ignore", systemImage: "eye.slash")
                }
                Spacer()
                if let supervisor = stop.restartingSupervisor {
                    Button(action: stop.stopSupervisor) {
                        Label("Stop \(supervisor.name) Instead\u{2026}", systemImage: "arrow.uturn.up")
                    }
                    .disabled(stop.isPreparing || stop.blockedReason != nil)
                    .help("\(supervisor.name) starts it again as soon as it exits; stopping \(supervisor.name) keeps it stopped.")
                }
                FamilyStopButton(title: risk.appQuitPID != nil ? "Quit App\u{2026}" : "Stop Tree\u{2026}", stop: stop,
                                 hasOwnedTargets: panel.hasOwnedTargets, action: onKill)
            }
            .controlSize(.small)
        }
    }

    private func icon(for type: RadarActionType) -> String {
        switch type {
        case .notify: "bell"
        case .highlight: "highlighter"
        case .snooze: "moon"
        case .ignore: "eye.slash"
        case .inspect: "info.circle"
        case .suggestKill: "scope"
        case .kill: "scope"
        }
    }
}
