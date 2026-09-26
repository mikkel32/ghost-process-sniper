import Charts
import GhostProcessSniperCore
import SwiftUI

/// The scroll shell has no live-data dependency. Each section observes only
/// the state it draws; history ticks no longer rebuild the entire dashboard.
struct RadarOverviewView: View {
    let session: RadarConsoleSession

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                OverviewHeaderSection(session: session)
                ConsoleThermalDashboard(session: session)
                OverviewGuidanceSection(session: session)
                OverviewMetricsView(session: session)
                OverviewQueuesSection(session: session)
                OverviewAnalyticsSection(session: session)
                OverviewEngineStatusStrip(monitor: session.monitor)
            }
            .padding(24)
        }
        .background { OverviewBackdrop(session: session).ignoresSafeArea() }
    }
}

private struct OverviewBackdrop: View {
    let session: RadarConsoleSession
    var body: some View { AmbientLevelBackdrop(level: session.commandCenter.level) }
}

private struct OverviewHeaderSection: View {
    let session: RadarConsoleSession
    var body: some View {
        CommandCenterHeader(model: session.commandCenter, processCount: session.monitor.health.processCount,
                            isRefreshing: session.isRefreshing, onRefresh: session.refresh)
    }
}

private struct OverviewGuidanceSection: View {
    let session: RadarConsoleSession
    var body: some View {
        IntelligenceBriefCard(brief: session.compactSnapshot.intelligenceBrief) {
            if let key = session.compactSnapshot.intelligenceBrief.familyKey { session.focus(.family(key)) }
        }
    }
}

private struct OverviewQueuesSection: View {
    let session: RadarConsoleSession
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OverviewSectionLabel(eyebrow: "Triage", title: "Needs your attention",
                                 detail: "Review current issues first, then keep an eye on emerging changes.")
            queueGrid
        }
    }
    private var queueGrid: some View {
        AdaptivePairLayout(breakpoint: 680, spacing: 14) {
            riskQueue
            warmingQueue
        }
    }

    private var riskQueue: some View {
        CompactRadarSection(
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
            if session.compactSnapshot.topRiskRows.isEmpty {
                QuietOverviewState(monitor: session.monitor)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(session.compactSnapshot.topRiskRows.prefix(6)) { row in
                        Button {
                            session.focus(.family(row.id))
                        } label: {
                            CompactFamilyQueueRow(row: row)
                        }
                        .buttonStyle(.plain)
                        .familyRowActions(row: row, session: session)
                        if row.id != session.compactSnapshot.topRiskRows.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var warmingQueue: some View {
        CompactRadarSection(
            title: "Warming Up",
            subtitle: "predictive",
            systemImage: "thermometer.medium",
            tip: RadarTip(
                title: "Warming Up",
                message: "The predictive queue: families whose trends say trouble is coming before any hard threshold is crossed — rising leak velocity, threshold ETAs, or recurring offenders. Catch them here and you never see them go hot."
            ),
            accent: .orange
        ) {
            if session.compactSnapshot.warmingRows.isEmpty {
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
                LazyVStack(spacing: 0) {
                    ForEach(session.compactSnapshot.warmingRows.prefix(5)) { row in
                        Button {
                            session.focus(.family(row.id))
                        } label: {
                            CompactFamilyQueueRow(row: row)
                        }
                        .buttonStyle(.plain)
                        .familyRowActions(row: row, session: session)
                        if row.id != session.compactSnapshot.warmingRows.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

}

private struct OverviewAnalyticsSection: View {
    let session: RadarConsoleSession
    @State private var cachedMemoryShares: [MemoryShare] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OverviewSectionLabel(eyebrow: "Analytics", title: "Where your resources go",
                                 detail: "Explore activity, memory usage, and changes over time.")
            visualizationGrid
            memoryPulseStrip
            recentIncidents
        }
        .onAppear(perform: rebuildMemoryShares)
        .onChange(of: session.snapshotContentToken) { _, _ in rebuildMemoryShares() }
    }
    private func rebuildMemoryShares() {
        let shares = RadarOverviewView.buildMemoryShares(from: session.monitor.families)
        if cachedMemoryShares != shares { cachedMemoryShares = shares }
    }
    private var visualizationGrid: some View {
        AdaptivePairLayout(breakpoint: 720, spacing: 14, secondaryWidth: 320) {
            liveRadarCard
            memoryShareCard
        }
    }

    private var liveRadarCard: some View {
        CompactRadarSection(
            title: "Live Radar",
            subtitle: "closer to center = higher risk",
            systemImage: "dot.radiowaves.left.and.right",
            tip: RadarTip(
                title: "Live Radar",
                message: "Every blip is a tracked process family. Distance from the center encodes risk — a blip drifting inward is getting worse. Each family keeps a fixed bearing, so you can watch the same blip over time. Click a blip to open its detail, right-click for snooze, ignore, or kill preview.",
                shortcut: "⌘1 Overview"
            ),
            accent: RadarTheme.accent(for: session.commandCenter.level)
        ) {
            RadarSweepView(session: session)
                .frame(height: 255)
        }
        .frame(maxWidth: .infinity)
    }

    private var memoryShareCard: some View {
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
            MemoryShareRanking(shares: cachedMemoryShares)
                .equatable()
                .frame(height: 255)
        }
        .frame(maxWidth: .infinity)
    }

    private var recentIncidentRows: [IncidentRowViewModel] {
        session.monitor.incidents.prefix(3).map(IncidentRowViewModel.init)
    }

    @ViewBuilder
    private var recentIncidents: some View {
        let rows = recentIncidentRows
        if !rows.isEmpty {
            CompactRadarSection(
                title: "Recent Incidents",
                subtitle: "\(session.monitor.incidents.count) total",
                systemImage: "clock.badge.exclamationmark",
                tip: RadarTip(
                    title: "Incidents",
                    message: "Every time a family crosses into hot, an incident is recorded with its peak score, metrics, and timeline — a memory of what misbehaved even after it calms down. Click through for the full log.",
                    shortcut: "⌘4 Incidents"
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

    @ViewBuilder
    private var memoryPulseStrip: some View {
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

private struct OverviewSectionLabel: View {
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

private struct CommandCenterHeader: View {
    let model: OverviewCommandCenterModel
    let processCount: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 16) {
            RadarBrandMark(level: .quiet, size: 44)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("PROCESS INTELLIGENCE")
                        .font(.caption.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(RadarTheme.brand)
                    LevelLegendTip()
                }

                Text("Your Mac, in focus.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(String(processCount)) processes sampled · Your live workspace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                RadarStatusPill(
                    title: model.statusText.uppercased(),
                    level: model.level,
                    systemImage: RadarStyle.icon(for: model.level)
                )
                Text("Updated \(model.updatedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: onRefresh) {
                    Label(isRefreshing ? "Scanning" : "Scan now", systemImage: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative, isActive: isRefreshing && !reduceMotion)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("Request a fresh sample without changing monitoring settings")
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [RadarTheme.brand.opacity(0.09), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .radarSurface(
            tint: RadarTheme.brand,
            cornerRadius: 20
        )
    }
}

private struct IntelligenceBriefCard: View {
    let brief: RadarIntelligenceBrief
    let onReview: () -> Void
    @State private var evidenceExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: brief.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(RadarTheme.accent(for: brief.level).gradient)
                .frame(width: 42, height: 42)
                .background(
                    RadarTheme.accent(for: brief.level).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(brief.eyebrow.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .tracking(1.15)
                        .foregroundStyle(RadarTheme.accent(for: brief.level))
                    Text(brief.confidenceText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(brief.title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)

                Text(brief.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(brief.recommendation, systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !brief.evidence.isEmpty {
                    DisclosureGroup("Why this recommendation", isExpanded: $evidenceExpanded) {
                        FlowTags(title: "Evidence", items: brief.evidence)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if brief.familyKey != nil {
                Button(action: onReview) {
                    Label(brief.actionTitle, systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(RadarTheme.accent(for: brief.level))
                .controlSize(.regular)
                .help("Open the process family behind this recommendation")
            }
        }
        .padding(16)
        .radarSurface(
            tint: RadarTheme.accent(for: brief.level),
            cornerRadius: 18,
            raised: brief.level >= .hot
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(brief.eyebrow). \(brief.title). \(brief.detail). \(brief.recommendation)")
        .animation(RadarMotion.response(reduceMotion), value: evidenceExpanded)
        .onChange(of: brief.familyKey) { _, _ in evidenceExpanded = false }
    }
}

private struct CompactFamilyQueueRow: View {
    let row: CompactSidebarRowModel

    @State private var isHovering = false

    var body: some View {
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
                .opacity(isHovering ? 1 : 0)
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

private struct QuietOverviewState: View {
    let monitor: ProcessMonitor

    var body: some View {
        let status = monitor.engineStatus
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green.gradient)
            Text("No urgent families")
                .font(.subheadline.weight(.semibold))
            Text("\(status.processText) processes sampled; emerging signals remain in Warming Up")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewEngineStatusStrip: View {
    let monitor: ProcessMonitor

    var body: some View {
        CompactEngineHealthStrip(status: monitor.engineStatus)
    }
}

/// A hoverable legend explaining the four threat levels with their colors.
private struct LevelLegendTip: View {
    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    private let entries: [(level: GhostLevel, name: String, meaning: String)] = [
        (.quiet, "Quiet", "Inside its learned range — nothing to do."),
        (.watch, "Watch", "Elevated or trending up; the radar is paying attention."),
        (.hot, "Hot", "Crossed a threshold or forecast to — worth triaging now."),
        (.critical, "Critical", "Far out of bounds or breaching imminently.")
    ]

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(isPresented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .contentShape(Circle().inset(by: -4))
            .onHover { hovering in
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: hovering ? 220_000_000 : 150_000_000)
                    guard !Task.isCancelled else {
                        return
                    }
                    isPresented = hovering
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Threat Levels")
                        .font(.subheadline.weight(.semibold))
                    ForEach(entries, id: \.name) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(entry.level == .quiet ? Color.teal : RadarStyle.color(for: entry.level))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name)
                                    .font(.caption.weight(.semibold))
                                Text(entry.meaning)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    Text("Action levels summarize measured resource use, persistence, and system pressure. Celsius values come from hardware sensors and are shown separately. A high resource reading does not automatically mean a process should be stopped.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(width: 280, alignment: .leading)
            }
            .accessibilityLabel("Threat level legend")
    }
}

/// Host memory pressure as a compact circular gauge, tinted by severity.
/// Hovering reveals the full breakdown and what pressure does to scoring.
struct MemoryPressureBadge: View {
    let pressure: SystemMemoryPressure

    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    private var color: Color {
        pressure.level == .nominal ? .teal : RadarStyle.color(for: pressure.level.ghostLevel)
    }

    var body: some View {
        HStack(spacing: 7) {
            Gauge(value: pressure.usedFraction) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int((pressure.usedFraction * 100).rounded()))")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(color.gradient)
            .scaleEffect(0.62)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("PRESSURE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                    .lineLimit(1)
                Text(pressure.isKnown ? pressure.level.label : "—")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(pressure.level == .nominal ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
                    .contentTransition(.opacity)
            }
        }
        .frame(minHeight: 38, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTask?.cancel()
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: hovering ? 220_000_000 : 150_000_000)
                guard !Task.isCancelled else {
                    return
                }
                isPresented = hovering
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("System Memory Pressure")
                    .font(.subheadline.weight(.semibold))
                if pressure.isKnown {
                    breakdownRow("Used", "\(Int((pressure.usedFraction * 100).rounded()))% of \(RadarFormat.bytes(pressure.totalBytes))")
                    breakdownRow("Available", RadarFormat.bytes(pressure.availableBytes))
                    breakdownRow("Compressed", RadarFormat.bytes(pressure.compressedBytes))
                    Divider()
                }
                Text("Sampled from host VM statistics every refresh. At Warning or Critical, large families get boosted scores — the same footprint matters more when the whole machine is starved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 270, alignment: .leading)
        }
        .accessibilityLabel("System memory pressure \(pressure.level.label), \(pressure.summaryText)")
    }

    private func breakdownRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

/// A cheap, static ambient wash. It avoids the offscreen surfaces created by
/// a full-window material or mesh gradient while retaining level context.
private struct AmbientLevelBackdrop: View {
    let level: GhostLevel

    var body: some View {
        LinearGradient(
            colors: [
                RadarTheme.accent(for: level).opacity(0.055),
                RadarTheme.canvas,
                RadarTheme.canvas
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }
}

struct MemoryShare: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: UInt64
    let color: Color
}

extension RadarOverviewView {
    private static let sharePalette: [Color] = [.blue, .teal, .purple, .orange, .pink, .gray]

    // Bytes quantized to 16 MB buckets: the ranking only re-renders when a
    // family actually moves, not on every few-hundred-KB jitter.
    static func buildMemoryShares(from families: [ProcessFamily]) -> [MemoryShare] {
        func quantized(_ bytes: UInt64) -> UInt64 {
            max(16_777_216, bytes - bytes % 16_777_216)
        }
        let sorted = families.sorted { $0.totalPhysicalFootprintBytes > $1.totalPhysicalFootprintBytes }
        var result = sorted.prefix(5).enumerated().map { index, family in
            MemoryShare(
                id: family.familyKey,
                name: family.displayName,
                bytes: quantized(family.totalPhysicalFootprintBytes),
                color: Self.sharePalette[index]
            )
        }
        let restBytes = sorted.dropFirst(5).reduce(0 as UInt64) { $0 + $1.totalPhysicalFootprintBytes }
        if restBytes > 0 {
            result.append(MemoryShare(id: "other", name: "Other", bytes: quantized(restBytes), color: Self.sharePalette[5]))
        }
        return result
    }
}

private struct MemoryShareRanking: View, Equatable {
    let shares: [MemoryShare]

    var body: some View {
        let shares = shares
        if shares.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.pie")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("No tracked families yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let total = max(1, shares.reduce(0) { $0 + $1.bytes })
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Largest consumer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(shares.first?.name ?? "—")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(RadarFormat.bytes(shares.first?.bytes ?? 0))
                        .font(.headline.monospacedDigit())
                }

                ForEach(shares.prefix(6)) { share in
                    let fraction = Double(share.bytes) / Double(total)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(share.color)
                                .frame(width: 7, height: 7)
                            Text(share.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(Int((fraction * 100).rounded()))%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(RadarFormat.bytes(share.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.055))
                                Capsule()
                                    .fill(share.color)
                                    .frame(width: max(3, proxy.size.width * fraction))
                            }
                        }
                        .frame(height: 5)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }
}
