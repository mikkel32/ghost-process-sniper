import Charts
import GhostProcessSniperCore
import SwiftUI

struct RadarOverviewView: View {
    @Bindable var session: RadarConsoleSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CommandCenterHeader(model: session.commandCenter)
                statusBand
                HStack(alignment: .top, spacing: 12) {
                    CompactRadarSection(
                        title: "Live Radar",
                        subtitle: "closer to center = higher risk",
                        systemImage: "dot.radiowaves.left.and.right",
                        tip: RadarTip(
                            title: "Live Radar",
                            message: "Every blip is a tracked process family. Distance from the center encodes risk — a blip drifting inward is getting worse. Each family keeps a fixed bearing, so you can watch the same blip over time. Click a blip to open its detail, right-click for snooze, ignore, or kill preview.",
                            shortcut: "⌘1 Overview"
                        )
                    ) {
                        RadarSweepView(session: session)
                            .frame(height: 235)
                    }
                    CompactRadarSection(
                        title: "Memory Share",
                        subtitle: RadarFormat.bytes(session.monitor.summary.totalMemoryBytes),
                        systemImage: "chart.pie",
                        tip: RadarTip(
                            title: "Memory Share",
                            message: "How the tracked memory splits across the five biggest families, with everything else grouped as Other. The center names the single biggest consumer right now."
                        )
                    ) {
                        MemoryShareDonut(shares: memoryShares)
                            .equatable()
                            .frame(height: 235)
                    }
                    .frame(width: 265)
                }
                HStack(alignment: .top, spacing: 12) {
                    riskQueue
                    warmingQueue
                }
                memoryPulseStrip
                recentIncidents
                OverviewEngineStatusStrip(monitor: session.monitor)
            }
            .padding(18)
            // Animate only when the queue MEMBERSHIP changes — never on the
            // per-second metric text ticks, which would re-animate the whole
            // overview every refresh.
            .animation(
                .snappy(duration: 0.32),
                value: session.compactSnapshot.topRiskRows.map(\.id) + session.compactSnapshot.warmingRows.map(\.id)
            )
        }
        .background {
            AmbientLevelBackdrop(level: session.commandCenter.level)
                .ignoresSafeArea()
        }
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
                    shortcut: "⌘3 Incidents"
                )
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

    private var statusBand: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                ForEach(session.commandCenter.chips) { chip in
                    CompactRadarChip(
                        title: chip.title,
                        value: chip.value,
                        systemImage: chip.systemImage,
                        level: chip.level
                    )
                }
                MemoryPressureBadge(pressure: session.monitor.systemPressure)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(RadarStyle.glass(for: session.commandCenter.level), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                )
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

    private var riskQueue: some View {
        CompactRadarSection(
            title: "Risk Queue",
            subtitle: "\(session.compactSnapshot.topRiskRows.count) priority",
            systemImage: "flame",
            tip: RadarTip(
                title: "Risk Queue",
                message: "Families that need attention now, ordered by ghost score. The score (0–100) blends memory, CPU, leak velocity, deviation from the family's learned baseline, and forecast risk.",
                shortcut: "⌘↓ / ⌘↑ walk families"
            )
        ) {
            if session.compactSnapshot.topRiskRows.isEmpty {
                QuietOverviewState(status: session.engineStatus)
                    .frame(maxWidth: .infinity, minHeight: 178)
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
            )
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
                .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
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

private struct CommandCenterHeader: View {
    let model: OverviewCommandCenterModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: RadarStyle.icon(for: model.level))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(RadarStyle.color(for: model.level))
                .frame(width: 34, height: 34)
                .background(
                    RadarStyle.color(for: model.level).opacity(model.level == .quiet ? 0.07 : 0.14),
                    in: Circle()
                )
                .symbolEffect(.pulse, options: .repeating, isActive: model.level >= .hot)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.title.weight(.semibold))
                        .lineLimit(1)
                    LevelLegendTip()
                }
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(model.statusText)
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(RadarStyle.color(for: model.level))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: model.statusText)
                Text(model.updatedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct CompactFamilyQueueRow: View {
    let row: CompactSidebarRowModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.systemImage)
                .foregroundStyle(RadarStyle.color(for: row.level))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScoreCapsuleBadge(scoreText: row.scoreText, level: row.level)
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
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
    let status: EngineStatusSnapshot

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green.gradient)
            Text("All Quiet")
                .font(.subheadline.weight(.semibold))
            Text("\(status.processText) processes sampled, nothing misbehaving")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewEngineStatusStrip: View {
    @Bindable var monitor: ProcessMonitor

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
                    Text("Scores run 0–100 and blend memory, CPU, leak velocity, baseline deviation, recurrence, and forecast risk.")
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
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 0) {
                Text("PRESSURE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(pressure.isKnown ? pressure.level.label : "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pressure.level == .nominal ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
                    .contentTransition(.opacity)
            }
        }
        .frame(minHeight: 34, alignment: .leading)
        .animation(.easeOut(duration: 0.5), value: pressure.level)
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

/// A soft mesh-gradient wash behind the overview, tinted by the overall
/// threat level: cool and calm while quiet, warming toward red as pressure
/// rises. Static per level — it cross-fades on level changes instead of
/// animating continuously.
private struct AmbientLevelBackdrop: View {
    let level: GhostLevel

    private var palette: (Color, Color, Color) {
        switch level {
        case .quiet: (.teal, .blue, .indigo)
        case .watch: (.orange, .yellow, .teal)
        case .hot: (.red, .orange, .pink)
        case .critical: (.pink, .red, .purple)
        }
    }

    var body: some View {
        let (a, b, c) = palette
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                a.opacity(0.45), b.opacity(0.2), c.opacity(0.35),
                b.opacity(0.15), .clear, a.opacity(0.18),
                c.opacity(0.3), a.opacity(0.15), b.opacity(0.28)
            ]
        )
        .opacity(0.14)
        .animation(.easeInOut(duration: 1.4), value: level)
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

    // Bytes quantized to 16 MB buckets: the donut only re-renders when a
    // family actually moves, not on every few-hundred-KB jitter.
    var memoryShares: [MemoryShare] {
        func quantized(_ bytes: UInt64) -> UInt64 {
            max(16_777_216, bytes - bytes % 16_777_216)
        }
        let sorted = session.monitor.families.sorted { $0.totalPhysicalFootprintBytes > $1.totalPhysicalFootprintBytes }
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

private struct MemoryShareDonut: View, Equatable {
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
            VStack(spacing: 10) {
                Chart(shares) { share in
                    SectorMark(
                        angle: .value("Memory", Double(share.bytes) / 1_048_576),
                        innerRadius: .ratio(0.66),
                        angularInset: 1.4
                    )
                    .cornerRadius(3)
                    .foregroundStyle(share.color.gradient)
                }
                .chartLegend(.hidden)
                .overlay {
                    VStack(spacing: 1) {
                        Text(shares.first?.name ?? "")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text(RadarFormat.bytes(shares.first?.bytes ?? 0))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shares.prefix(3)) { share in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(share.color)
                                .frame(width: 7, height: 7)
                            Text(share.name)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(RadarFormat.bytes(share.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
