import AppKit
import GhostProcessSniperCore
import SwiftUI

struct KillTargetRow: View {
    let target: KillTarget
    var showsDivider = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if target.isRoot {
                            Text("root")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(target.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text("PID \(String(target.pid))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Text(target.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 78, alignment: .trailing)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(target.name), PID \(String(target.pid)), \(target.state.label)\(target.isRoot ? ", root" : "")")
            .accessibilityValue(target.reason)
            .contextMenu {
                Button("Copy PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(target.pid), forType: .string)
                }
            }

            if showsDivider {
                Divider()
            }
        }
        .animation(.easeOut(duration: 0.2), value: target.state)
    }

    private var icon: String {
        switch target.state {
        case .ready: "checkmark.circle"
        case .locked: "lock"
        case .stale: "clock.badge.xmark"
        case .recycled: "arrow.triangle.2.circlepath"
        case .stopping: "hourglass"
        case .terminated: "checkmark.seal"
        case .forceKilled: "bolt"
        case .survived: "exclamationmark.triangle"
        case .exitedBeforeSignal: "figure.run"
        case .failed: "xmark.octagon"
        }
    }

    private var color: Color {
        switch target.state {
        case .ready, .terminated: .green
        case .locked, .stale, .recycled, .stopping: .orange
        case .forceKilled: .red
        case .exitedBeforeSignal: .secondary
        case .survived, .failed: .red
        }
    }
}

/// Process rows in a rounded well: the first few, then the rest behind a
/// disclosure, so a 100-helper tree does not push everything else away.
struct KillTargetRows: View {
    let rows: [KillTarget]
    var visibleCount = 8

    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            well(Array(rows.prefix(visibleCount)))
            if rows.count > visibleCount {
                DisclosureGroup("Show all \(rows.count)", isExpanded: $showsAll) {
                    well(Array(rows.dropFirst(visibleCount)))
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }

    private func well(_ shown: [KillTarget]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(shown) { target in
                KillTargetRow(target: target, showsDivider: target.id != shown.last?.id)
            }
        }
        .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Why the engine would stop it and why it would wait, side by side.
struct KillEvidenceColumns: View {
    let preview: KillPreview

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                column(title: "Why stop it", factors: preview.whyKillEvidence.filter { $0.source != .risk },
                       empty: "No strong reason to stop it yet.")
                column(title: "Why wait", factors: preview.whyWaitEvidence.filter { $0.source != .risk },
                       empty: "Nothing suggests waiting.")
            }
        }
    }

    private func column(title: String, factors: [KillDecisionFactor], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "list.bullet.clipboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(factors.prefix(4)) { factor in
                let text = "\(factor.title): \(factor.detail)"
                Label(text, systemImage: KillFactorStyle.icon(for: factor.kind))
                    .font(.caption)
                    .foregroundStyle(KillFactorStyle.color(for: factor.kind))
                    .lineLimit(2)
                    .help(text)
            }
            if factors.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct KillNearbyPanel: View {
    let candidates: [KillCollateralCandidate]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Nearby but not targeted", systemImage: "person.2.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(candidates.prefix(4), id: \.id) { (candidate: KillCollateralCandidate) in
                HStack {
                    Text(candidate.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text("PID \(String(candidate.identity.pid))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(candidate.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(candidate.reason)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum KillFactorStyle {
    static func icon(for factor: KillDecisionFactorKind) -> String {
        switch factor {
        case .whyKill: "checkmark.seal"
        case .whyWait: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }

    static func color(for factor: KillDecisionFactorKind) -> Color {
        switch factor {
        case .whyKill: .green
        case .whyWait: .orange
        case .blocking: .red
        }
    }
}
