import GhostProcessSniperCore
import SwiftUI

struct FamilyActionsPanel: View {
    let panel: FamilyDetailPanelModel
    let risk: KillRiskAssessment
    let onSnooze: (TimeInterval) -> Void
    let onIgnore: () -> Void
    let onKill: () -> Void

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
                Button(role: .destructive, action: onKill) {
                    Label(risk.appQuitPID != nil ? "Quit App\u{2026}" : "Stop Tree\u{2026}", systemImage: "scope")
                }
                .disabled(!panel.hasOwnedTargets)
                .help(panel.hasOwnedTargets ? "Preview exactly what will be stopped, then confirm" : "No live processes owned by you to target")
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
