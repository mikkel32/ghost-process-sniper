import GhostProcessSniperCore
import SwiftUI

/// The top of a family page: what is wrong, how sure the engine is, what
/// stopping it would cost and give back, and the one action that fits.
struct FamilyDecisionHero: View {
    let brief: FamilyDecisionBrief
    let risk: KillRiskAssessment
    let stopTitle: String
    let hasOwnedTargets: Bool
    let actions: FamilyPageActions

    var body: some View {
        let accent = RadarTheme.accent(for: brief.level)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: brief.systemImage)
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(brief.headline)
                        .font(.title2.weight(.semibold))
                    Text(brief.detail)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ConfidenceCapsule(confidence: brief.confidence, text: brief.confidenceText)
            }

            Text(brief.recommendationText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !brief.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(brief.evidence.prefix(3), id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .imageScale(.small)
                                .scaleEffect(0.5)
                                .accessibilityHidden(true)
                            Text(item)
                                .lineLimit(2)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // The most serious consequence, so it is seen before the preview.
            if let hazard = risk.hazards.max(by: { $0.severity < $1.severity }), hazard.severity > .info {
                KillRiskCard(risk: hazard)
            }

            if hasOwnedTargets, brief.mute == .none {
                VStack(alignment: .leading, spacing: 3) {
                    Label(brief.reclaimText, systemImage: "arrow.uturn.backward.circle")
                    if let headline = risk.headline {
                        Label(headline, systemImage: "info.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                primaryActions
                Spacer(minLength: 8)
                Menu {
                    FamilySnoozeMenu(snooze: actions.snooze)
                } label: {
                    Label("Snooze", systemImage: "moon")
                }
                .menuStyle(.button)
                .fixedSize()
                if brief.mute != .ignored {
                    Button("Ignore", systemImage: "eye.slash", action: actions.ignore)
                }
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .radarSurface(tint: accent, raised: true)
    }

    @ViewBuilder
    private var primaryActions: some View {
        switch brief.mute {
        case .snoozed:
            Button("Unsnooze", systemImage: "bell", action: actions.unmute)
                .buttonStyle(.borderedProminent)
        case .ignored:
            Button("Stop Ignoring", systemImage: "eye", action: actions.unmute)
                .buttonStyle(.borderedProminent)
        case .none:
            if hasOwnedTargets, let supervisor = risk.supervisor, supervisor.pid != nil {
                // Stopping the child alone would only make the supervisor restart it.
                Button("Stop \(supervisor.name) Instead\u{2026}", systemImage: "stop.circle") {
                    actions.stopSupervisor(supervisor)
                }
                .buttonStyle(.borderedProminent)
                .help("\(supervisor.name) restarts what it watches; stopping it stops both")
                Button(stopTitle, role: .destructive, action: actions.stop)
            } else if brief.recommendation == .stop {
                Button(stopTitle, systemImage: "stop.circle", role: .destructive, action: actions.stop)
                    .buttonStyle(.borderedProminent)
                    .help("Preview exactly what will be stopped, then confirm")
            }
        }
    }
}

/// Three segments that fill with the engine's confidence in its verdict.
private struct ConfidenceCapsule: View {
    let confidence: FamilyDecisionBrief.Confidence
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { step in
                    Capsule()
                        .fill(step <= confidence.rawValue ? tint : Color.primary.opacity(0.12))
                        .frame(width: 16, height: 5)
                }
            }
            Text("\(confidence.label) confidence")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence")
        .accessibilityValue(text)
    }

    private var tint: Color {
        switch confidence {
        case .low: .orange
        case .medium: .yellow
        case .high: .green
        }
    }
}
