import GhostProcessSniperCore
import SwiftUI

/// The Risk and Warming queues, right under the verdict. Risk rows carry a
/// Quick Stop on hover and keyboard focus; warming rows only offer it in the
/// context menu, because an early warning is not yet a reason to stop.
struct OverviewQueuesSection: View {
    let session: RadarConsoleSession

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OverviewSectionLabel(eyebrow: "Triage", title: "Needs your attention",
                                 detail: "Review current issues first, then keep an eye on emerging changes.")
            AdaptivePairLayout(breakpoint: 680, spacing: 14) {
                riskQueue
                warmingQueue
            }
        }
    }

    private var riskQueue: some View {
        let rows = Array(session.compactSnapshot.topRiskRows.prefix(6))
        return CompactRadarSection(
            title: "Risk Queue",
            subtitle: "\(session.compactSnapshot.topRiskRows.count) priority",
            systemImage: "flame",
            tip: RadarTip(
                title: "Risk Queue",
                message: "Families ranked by current severity and confirmed resource behavior. Review the stated cause, measurements, and process tree. Historical incidents and noisy forecasts do not outrank a current urgent problem.",
                shortcut: "⌘↓ / ⌘↑ walk families"
            ),
            accent: .red
        ) {
            if rows.isEmpty {
                QuietOverviewState(familyCount: session.compactSnapshot.allRows.count,
                                   hasSampled: session.compactSnapshot.hasSampled)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                queueRows(rows, showsStopButton: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var warmingQueue: some View {
        let rows = Array(session.compactSnapshot.warmingRows.prefix(5))
        return CompactRadarSection(
            title: "Warming Up",
            subtitle: "early signs first",
            systemImage: "thermometer.medium",
            tip: RadarTip(
                title: "Warming Up",
                message: "Families with an early sign of trouble come first, before any hard threshold is crossed: rising memory, sustained CPU, duplicates or a forgotten process tree. Below them are families that are only big, at a size that is usual for them; they never headline the Overview."
            ),
            accent: .orange
        ) {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No early warnings", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                    Text("Quiet watched tools stay visible in the source list.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            } else {
                queueRows(rows, showsStopButton: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func queueRows(_ rows: [CompactSidebarRowModel], showsStopButton: Bool) -> some View {
        let isPreparing = session.preparingStop != nil
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                CompactFamilyQueueRow(
                    row: row,
                    quickStop: showsStopButton ? session.quickStops.actions[row.id].flatMap { $0.isAvailable ? $0 : nil } : nil,
                    isPreparing: isPreparing,
                    onOpen: { session.focus(.family(row.id)) },
                    onStop: { session.quickStop($0) }
                )
                .familyRowActions(row: row, session: session)
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
    }
}

struct OverviewSectionLabel: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

private struct CompactFamilyQueueRow: View {
    private enum Focus: Hashable { case open, stop }

    let row: CompactSidebarRowModel
    let quickStop: QuickStopAction?
    let isPreparing: Bool
    let onOpen: () -> Void
    let onStop: (QuickStopAction) -> Void

    @State private var isHovering = false
    @FocusState private var focus: Focus?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                summary
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .open)

            // Visible on hover or keyboard focus, so a stop is one click away
            // without a column of red buttons down the queue. It keeps its
            // space, so the row does not reflow under the pointer, and Tab
            // and VoiceOver still reach it.
            if let quickStop {
                QuickStopButton(action: quickStop) { onStop(quickStop) }
                    .labelStyle(.titleOnly)
                    .controlSize(.small)
                    .disabled(isPreparing)
                    .focused($focus, equals: .stop)
                    .opacity(isHovering || focus != nil ? 1 : 0)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 7)
        .background(isHovering ? AnyShapeStyle(RadarTheme.accent(for: row.level).opacity(0.07)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help(row.helpText)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(RadarTheme.accent(for: row.level).gradient)
                .frame(width: 3, height: 34)
            Image(systemName: row.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(RadarTheme.accent(for: row.level))
                .frame(width: 28, height: 28)
                .background(RadarTheme.accent(for: row.level).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScoreCapsuleBadge(scoreText: row.statusText, level: row.level)
                }
                HStack(spacing: 6) {
                    Text(row.subtitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.metricText)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovering && quickStop == nil ? 1 : 0)
        }
        .contentShape(Rectangle())
    }
}

private struct QuietOverviewState: View {
    let familyCount: Int
    let hasSampled: Bool

    private var detail: String {
        if !hasSampled { return "The first scan is still running" }
        return familyCount == 0
            ? "Nothing in the radar's scope is running"
            : "\(familyCount) families watched; emerging signals remain in Warming Up"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green.gradient)
            Text("No urgent families")
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
