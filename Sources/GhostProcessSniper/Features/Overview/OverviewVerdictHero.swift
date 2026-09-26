import GhostProcessSniperCore
import SwiftUI

/// The one answer the Overview leads with: what, if anything, needs doing,
/// and the button that does it. It reads only the content-gated snapshot and
/// the Quick Stop for the brief's family, so a sample does not redraw it.
struct OverviewVerdictHero: View {
    let session: RadarConsoleSession

    @State private var evidenceExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let compact = session.compactSnapshot
        let brief = compact.intelligenceBrief
        let hasFamilies = !compact.allRows.isEmpty
        let accent = RadarTheme.accent(for: brief.level)
        let quickStop = brief.familyKey
            .flatMap { session.quickStops.actions[$0] }
            .flatMap { $0.isAvailable ? $0 : nil }

        HStack(alignment: .top, spacing: 16) {
            Image(systemName: brief.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent.gradient)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(brief.eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.15)
                        .foregroundStyle(accent)
                    RadarStatusPill(
                        title: compact.commandCenter.statusText.uppercased(),
                        level: compact.commandCenter.level,
                        systemImage: RadarStyle.icon(for: compact.commandCenter.level)
                    )
                    LevelLegendTip()
                    Spacer(minLength: 8)
                    Text(brief.confidenceText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(Self.headline(for: brief, hasFamilies: hasFamilies))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)

                if !hasFamilies {
                    RadarWaitLabel("Scanning your processes…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text(brief.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(brief.recommendation, systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                if !brief.evidence.isEmpty {
                    DisclosureGroup("Why this recommendation", isExpanded: $evidenceExpanded) {
                        FlowTags(title: "Evidence", items: brief.evidence)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if let familyKey = brief.familyKey {
                        Button {
                            session.focus(.family(familyKey))
                        } label: {
                            Label(brief.actionTitle, systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .help("Open the process family behind this recommendation")
                    }
                    if let quickStop {
                        OverviewVerdictStopButton(session: session, action: quickStop)
                    }
                    Spacer(minLength: 8)
                    OverviewScanButton(session: session)
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .radarSurface(tint: accent, cornerRadius: 20, raised: brief.level >= .hot)
        .accessibilityElement(children: .contain)
        .animation(RadarMotion.response(reduceMotion), value: evidenceExpanded)
        .onChange(of: brief.familyKey) { _, _ in evidenceExpanded = false }
    }

    static func headline(for brief: RadarIntelligenceBrief, hasFamilies: Bool) -> String {
        if brief.familyKey != nil { return brief.title }
        return hasFamilies ? "Your Mac is running smoothly" : "Learning what is normal"
    }
}

/// Reads the preparing flag on its own, so starting a stop redraws one button.
private struct OverviewVerdictStopButton: View {
    let session: RadarConsoleSession
    let action: QuickStopAction

    var body: some View {
        QuickStopButton(action: action, usesShortTitle: false) { session.quickStop(action) }
            .disabled(session.preparingStop != nil)
    }
}

/// Reads the refresh flag on its own, so a scan redraws one button.
private struct OverviewScanButton: View {
    let session: RadarConsoleSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: session.refresh) {
            Label(session.isRefreshing ? "Scanning" : "Scan now", systemImage: "dot.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative, isActive: session.isRefreshing && !reduceMotion)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(session.isRefreshing)
        .help("Request a fresh sample without changing monitoring settings")
    }
}
