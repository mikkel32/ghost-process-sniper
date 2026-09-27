import Charts
import GhostProcessSniperCore
import SwiftUI

/// Its own body reads only cached shares: the radar, pulse chart and
/// incidents each observe their own data, so a pulse append redraws one chart.
struct OverviewAnalyticsSection: View {
    let session: RadarConsoleSession
    @State private var cachedMemoryShares: [MemoryShare] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OverviewSectionLabel(eyebrow: "Analytics", title: "Where your resources go",
                                 detail: "Explore activity, memory usage, and changes over time.")
            visualizationGrid
            MemoryPulseCard(session: session)
            RecentIncidentsCard(session: session)
        }
        .onAppear(perform: rebuildMemoryShares)
        .onChange(of: session.snapshotContentToken) { _, _ in rebuildMemoryShares() }
    }
    private func rebuildMemoryShares() {
        let shares = MemoryShare.build(from: session.monitor.families)
        if cachedMemoryShares != shares { cachedMemoryShares = shares }
    }
    private var visualizationGrid: some View {
        AdaptivePairLayout(breakpoint: 720, spacing: 14, secondaryWidth: 320) {
            LiveRadarCard(session: session)
            MemoryShareCard(session: session, shares: cachedMemoryShares)
        }
    }
}

/// Every tracked family, riskiest first — never the All Processes search,
/// filter or sort — straight from the content-gated snapshot.
private struct LiveRadarCard: View {
    let session: RadarConsoleSession

    var body: some View {
        CompactRadarSection(
            title: "Live Radar",
            subtitle: "closer to center = higher risk",
            systemImage: "dot.radiowaves.left.and.right",
            tip: RadarTip(
                title: "Live Radar",
                message: "Every blip is a tracked process family. Distance from the center encodes risk — a blip drifting inward is getting worse. Each family keeps a fixed bearing, so you can watch the same blip over time. Click a blip to open its detail, right-click to snooze, ignore, or stop it.",
                shortcut: "⌘1 Overview"
            ),
            accent: RadarTheme.accent(for: session.commandCenter.level)
        ) {
            RadarSweepView(rows: Array(session.compactSnapshot.allRows.prefix(24)), session: session)
                .frame(height: 255)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MemoryShareCard: View {
    let session: RadarConsoleSession
    let shares: [MemoryShare]

    var body: some View {
        CompactRadarSection(
            title: "Memory Share",
            subtitle: RadarFormat.bytes(session.monitor.summary.totalMemoryBytes),
            systemImage: "chart.pie",
            tip: RadarTip(
                title: "Memory Share",
                message: "How the tracked memory splits across the five biggest families, with everything else grouped as Other. The center names the single biggest consumer right now."
            ),
            accent: .blue
        ) {
            MemoryShareRanking(shares: shares)
                .equatable()
                .frame(height: 255)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The only reader of `monitor.incidents` on the Overview.
private struct RecentIncidentsCard: View {
    let session: RadarConsoleSession

    var body: some View {
        let rows = session.monitor.incidents.prefix(3).map(IncidentRowViewModel.init)
        if !rows.isEmpty {
            CompactRadarSection(
                title: "Recent Incidents",
                subtitle: "\(session.monitor.incidents.count) total",
                systemImage: "clock.badge.exclamationmark",
                tip: RadarTip(
                    title: "Incidents",
                    message: "Every time a family crosses into hot, an incident is recorded with its peak score, metrics, and timeline — a memory of what misbehaved even after it calms down. Click through for the full log.",
                    shortcut: "⌘5 Incidents"
                ),
                accent: .pink
            ) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button {
                            session.focus(.incidents)
                        } label: {
                            OverviewIncidentRow(row: row)
                        }
                        .buttonStyle(.plain)
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// The only reader of `memoryPulse`, which grows every few seconds.
private struct MemoryPulseCard: View {
    let session: RadarConsoleSession

    var body: some View {
        if session.memoryPulse.count >= 3 {
            CompactRadarSection(
                title: "Tracked Memory",
                subtitle: "all watched families combined",
                systemImage: "waveform.path.ecg",
                tip: RadarTip(
                    title: "Tracked Memory",
                    message: "The combined footprint of every family the radar is watching, sampled every few seconds while the console is open. A steady climb here means pressure is building somewhere even if no single family stands out yet."
                ),
                accent: .blue
            ) {
                Chart(session.memoryPulse) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        y: .value("Memory", Double(sample.trackedBytes) / 1_048_576)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Memory", Double(sample.trackedBytes) / 1_048_576)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .foregroundStyle(Color.blue.gradient)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let megabytes = value.as(Double.self) {
                                Text(RadarFormat.bytes(UInt64(max(0, megabytes) * 1_048_576)))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .frame(height: 64)
            }
        }
    }
}

private struct OverviewIncidentRow: View {
    let row: IncidentRowViewModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: RadarStyle.icon(for: row.level))
                .foregroundStyle(RadarStyle.color(for: row.level))
                .frame(width: 16)
            Text(row.familyName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(row.stateText)
                .font(.caption2)
                .foregroundStyle(row.stateText == "Active" ? RadarStyle.color(for: row.level) : .secondary)
            Spacer(minLength: 6)
            Text(row.timeRangeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text("score \(row.scoreText)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
