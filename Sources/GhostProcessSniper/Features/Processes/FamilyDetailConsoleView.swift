import AppKit
import Charts
import GhostProcessSniperCore
import SwiftUI

struct FamilyDetailConsoleView: View {
    let family: ProcessFamily
    let detail: FamilyDetailViewModel?
    let panel: FamilyDetailPanelModel?
    let compact: CompactFamilyDetailModel?
    let onSnooze: (TimeInterval) -> Void
    let onIgnore: () -> Void
    let onKill: () -> Void
    let thermals: ThermalSnapshot
    let onPreviewProcess: (ProcessIdentity) -> Void

    @State private var selectedTab: FamilyDetailTab = .overview

    private var model: FamilyDetailViewModel {
        detail ?? FamilyDetailViewModel(family: family)
    }

    private var panelModel: FamilyDetailPanelModel {
        panel ?? FamilyDetailPanelModel(family: family, previous: nil)
    }

    private var compactModel: CompactFamilyDetailModel {
        compact ?? CompactFamilyDetailModel(panel: panelModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            FamilyDetailHeader(compact: compactModel, panel: panelModel, onSnooze: onSnooze, onIgnore: onIgnore, onKill: onKill)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider()

            HStack(spacing: 12) {
                Picker("Detail section", selection: $selectedTab) {
                    ForEach(FamilyDetailTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)

                Spacer()

                Label(panelModel.lastScoredText, systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(RadarTheme.panel)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .overview:
                        ProcessCauseView(family: family)
                        PrecisionTargetsView(family: family, onPreview: onPreviewProcess)
                        ThermalDashboardView(snapshot: thermals)
                        FamilySummaryPanel(panel: panelModel)
                        FamilyForecastPanel(panel: panelModel)
                        FamilyTrendPanel(panel: panelModel)

                    case .signals:
                        FamilyScorePanel(panel: panelModel)
                        FamilyCulpritPanel(panel: panelModel)
                        FamilyForecastPanel(panel: panelModel)

                    case .processes:
                        PrecisionTargetsView(family: family, onPreview: onPreviewProcess)
                        FamilyProcessTreePanel(family: family, panel: panelModel)
                        FamilyCulpritPanel(panel: panelModel)
                        FamilyActionsPanel(panel: panelModel, onSnooze: onSnooze, onIgnore: onIgnore, onKill: onKill)

                    case .forensics:
                        FamilyForensicsPanel(panel: panelModel)
                        FamilyActionsPanel(panel: panelModel, onSnooze: onSnooze, onIgnore: onIgnore, onKill: onKill)
                    }
                }
                .padding(18)
            }
        }
        .background {
            LinearGradient(
                colors: [RadarTheme.accent(for: panelModel.level).opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
    }
}

private enum FamilyDetailTab: String, CaseIterable, Identifiable {
    case overview
    case signals
    case processes
    case forensics

    var id: Self { self }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .signals: "Signals"
        case .processes: "Processes"
        case .forensics: "Forensics"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .signals: "waveform.path.ecg"
        case .processes: "point.3.connected.trianglepath.dotted"
        case .forensics: "doc.text.magnifyingglass"
        }
    }
}

private struct FamilyDetailHeader: View {
    let compact: CompactFamilyDetailModel
    let panel: FamilyDetailPanelModel
    let onSnooze: (TimeInterval) -> Void
    let onIgnore: () -> Void
    let onKill: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RadarBrandMark(level: panel.level, size: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(compact.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(compact.kindText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(compact.commandLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    RadarStatusPill(title: compact.statusText, level: compact.level)
                    Text(panel.assessment.cause)
                    Text(compact.pidText)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(RadarFormat.bytes(panel.memoryBytes)).font(.title3.monospacedDigit().weight(.semibold))
                Text("CPU \(RadarFormat.percent(panel.cpuPercent))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Menu {
                    Menu("Snooze", systemImage: "moon") {
                        FamilySnoozeMenu(snooze: onSnooze)
                    }
                    Button(action: onIgnore) {
                        Label("Ignore Family", systemImage: "eye.slash")
                    }

                    Divider()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(compact.commandLine, forType: .string)
                    } label: {
                        Label("Copy Command Line", systemImage: "terminal")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(compact.pidText, forType: .string)
                    } label: {
                        Label("Copy PIDs", systemImage: "number")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(compact.title, forType: .string)
                    } label: {
                        Label("Copy Name", systemImage: "textformat")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .help("Snooze, ignore, or copy family details")

                Button(role: .destructive, action: onKill) {
                    Label("Kill Tree", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!panel.hasOwnedTargets)
                .help(panel.hasOwnedTargets ? "Preview and confirm a kill of this process tree" : "No live processes owned by you to target")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FamilyVerdictBanner: View {
    let verdict: FamilyVerdict
    let pattern: MemoryPatternAnalysis

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: verdict.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(RadarStyle.color(for: verdict.level))
                .frame(width: 30, height: 30)
                .background(
                    RadarStyle.color(for: verdict.level).opacity(verdict.level == .quiet ? 0.08 : 0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verdict.headline)
                        .font(.headline)
                        .contentTransition(.opacity)
                    InfoTip(tip: RadarTip(
                        title: "Verdict",
                        message: "One synthesized judgment from everything the engine knows: forecast state, the shape of the memory curve (steady climb vs churn vs step), deviation from this family's learned baseline, and any active rules. It's the sentence you'd want a colleague to tell you about this process."
                    ))
                }
                Text(verdict.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if pattern.pattern != .unknown {
                Label(pattern.pattern.label, systemImage: pattern.pattern.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .help(pattern.detail)
            }
        }
        .padding(14)
        .radarSurface(tint: RadarTheme.accent(for: verdict.level), cornerRadius: 16, raised: verdict.level >= .hot)
    }
}

private struct FamilyForecastPanel: View {
    let panel: FamilyDetailPanelModel

    var body: some View {
        RadarSection(
            title: "Predictive Forecast",
            subtitle: "\(panel.forecastStateText) - \(panel.forecastConfidenceText) confidence",
            systemImage: "clock.badge.exclamationmark",
            tip: RadarTip(
                title: "Predictive Forecast",
                message: "Where this family is headed: threshold ETA extrapolated from measured velocity and acceleration, plus recurrence and staleness signals. Confidence rises with more samples, a cleaner trend fit, and a learned baseline — and falls for noisy data, freshly launched processes, and GC-style churn."
            ),
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                MetricCardGrid(cards: panel.forecastCards)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(RadarStyle.color(for: panel.forecastState.level))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(panel.forecastWhyNow)
                            .font(.headline)
                        Text("\(panel.forecastRecommendationTitle): \(panel.forecastRecommendationDetail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct FamilyCulpritPanel: View {
    let panel: FamilyDetailPanelModel

    var body: some View {
        RadarSection(
            title: "Culprit Finder",
            subtitle: panel.culprit.kind.label,
            systemImage: "target",
            tip: RadarTip(
                title: "Culprit Finder",
                message: "The engine's best guess at what spawned this family and why it's still here — inferred from command lines, working directories, and process ancestry. The evidence tags show what the guess is based on."
            ),
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "target")
                        .foregroundStyle(RadarStyle.color(for: panel.level))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(panel.culprit.likelyCause)
                            .font(.headline)
                        Text(panel.culprit.nextAction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let repoHint = panel.culprit.repoHint {
                    Label(repoHint, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                FlowTags(title: "Evidence", items: panel.culprit.evidence)
            }
        }
    }
}

private struct FamilySummaryPanel: View {
    let panel: FamilyDetailPanelModel

    var body: some View {
        RadarSection(
            title: "Summary",
            subtitle: panel.change.summary,
            systemImage: "rectangle.grid.2x2",
            accent: .blue
        ) {
            MetricCardGrid(cards: panel.summaryCards)
            MetricCardGrid(cards: panel.baselineCards)
            HStack(spacing: 8) {
                Label("What changed", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(RadarStyle.color(for: panel.change.level))
                Text(panel.change.summary)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
        }
    }
}

private struct FamilyScorePanel: View {
    let panel: FamilyDetailPanelModel

    var body: some View {
        RadarSection(
            title: "Why Flagged",
            subtitle: "\(panel.scoreComponents.count) signals",
            systemImage: "list.bullet.rectangle",
            tip: RadarTip(
                title: "Why Flagged",
                message: "These diagnostic cards explain the internal evidence score. Action levels also consider persistence, trend quality, learned normal behavior, and system pressure. Neither is a temperature; measured Celsius is shown in Hardware temperatures."
            ),
            accent: .red
        ) {
            if panel.scoreComponents.isEmpty {
                Text("No elevated score components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach(panel.scoreComponents.prefix(10)) { component in
                        ScoreComponentView(component: component)
                    }
                }
            }
        }
    }
}

private struct FamilyTrendPanel: View {
    let panel: FamilyDetailPanelModel

    @State private var hoveredSample: TrendSample?

    private var trendColor: Color {
        panel.trendVelocityMegabytesPerMinute > 0 ? RadarStyle.color(for: max(panel.level, .watch)) : .green
    }

    private var projectionEnd: (date: Date, megabytes: Double)? {
        guard panel.trendVelocityMegabytesPerMinute > 1,
              panel.memoryPattern.pattern.indicatesAccumulation,
              let last = panel.trendSamples.last
        else {
            return nil
        }
        let horizonMinutes = 3.0
        return (
            last.date.addingTimeInterval(horizonMinutes * 60),
            Double(last.memoryBytes) / 1_048_576 + panel.trendVelocityMegabytesPerMinute * horizonMinutes
        )
    }

    var body: some View {
        RadarSection(
            title: "Memory Trend",
            subtitle: "\(panel.memoryPattern.pattern.label) · \(panel.lastScoredText)",
            systemImage: "chart.xyaxis.line",
            tip: RadarTip(
                title: "Memory Trend",
                message: "Live footprint over the sampling window — hover the chart for exact values. The dashed line projects the current leak rate 3 minutes ahead (only drawn when the shape says memory is truly accumulating). Trend fit is the regression R²: steady means the slope is trustworthy, noisy means don't panic over it yet."
            ),
            accent: .blue
        ) {
            HStack(spacing: 16) {
                VStack(spacing: 8) {
                    memoryChart
                        .frame(height: 132)
                    cpuChart
                        .frame(height: 44)
                }
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    if let leak = panel.summaryCards.first(where: { $0.title == "Leak" }) {
                        metric("Leak velocity", leak.value)
                    }
                    if let cpu = panel.summaryCards.first(where: { $0.title == "CPU" }) {
                        metric("Current CPU", cpu.value)
                    }
                    metric("Trend fit", fitText)
                    metric("Pattern", panel.memoryPattern.pattern.label)
                }
                .frame(width: 170, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var memoryChart: some View {
        let samples = panel.trendSamples
        if samples.count >= 2 {
            Chart {
                ForEach(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        y: .value("Memory in MB", Double(sample.memoryBytes) / 1_048_576)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [trendColor.opacity(0.32), trendColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Memory in MB", Double(sample.memoryBytes) / 1_048_576),
                        series: .value("Series", "measured")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .foregroundStyle(trendColor.gradient)
                }

                if let projection = projectionEnd, let last = samples.last {
                    LineMark(
                        x: .value("Time", last.date),
                        y: .value("Memory in MB", Double(last.memoryBytes) / 1_048_576),
                        series: .value("Series", "projected")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                    .foregroundStyle(trendColor.opacity(0.55))
                    LineMark(
                        x: .value("Time", projection.date),
                        y: .value("Memory in MB", projection.megabytes),
                        series: .value("Series", "projected")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                    .foregroundStyle(trendColor.opacity(0.55))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("projected")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let hovered = hoveredSample {
                    RuleMark(x: .value("Time", hovered.date))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.secondary.opacity(0.5))
                    PointMark(
                        x: .value("Time", hovered.date),
                        y: .value("Memory in MB", Double(hovered.memoryBytes) / 1_048_576)
                    )
                    .symbolSize(46)
                    .foregroundStyle(trendColor)
                    .annotation(position: .top) {
                        VStack(spacing: 1) {
                            Text(RadarFormat.bytes(hovered.memoryBytes))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                            Text(hovered.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute().second(), anchor: .top)
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let megabytes = value.as(Double.self) {
                            Text(RadarFormat.bytes(UInt64(max(0, megabytes) * 1_048_576)))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else {
                                    hoveredSample = nil
                                    return
                                }
                                let x = location.x - geo[plotFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else {
                                    hoveredSample = nil
                                    return
                                }
                                hoveredSample = samples.min {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                }
                            case .ended:
                                hoveredSample = nil
                            }
                        }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Collecting samples…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var cpuChart: some View {
        let samples = panel.trendSamples
        if samples.count >= 2 {
            Chart(samples) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("CPU percent", sample.cpuPercent)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .foregroundStyle(Color.orange.gradient)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Text("CPU")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var fitText: String {
        guard panel.trendPoints.count >= 4 else {
            return "warming up"
        }
        let percent = Int((panel.trendFitQuality * 100).rounded())
        if panel.trendFitQuality >= 0.8 {
            return "\(percent)% steady"
        }
        if panel.trendFitQuality >= 0.4 {
            return "\(percent)% mixed"
        }
        return "\(percent)% noisy"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
        }
    }
}

private struct FamilyProcessTreePanel: View {
    let family: ProcessFamily
    let panel: FamilyDetailPanelModel

    var body: some View {
        RadarSection(title: "Process Tree", subtitle: "\(panel.members.count) processes") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    column("Role")
                    column("Name")
                    column("PID")
                    column("Memory")
                    column("CPU")
                }
                Divider()
                    .gridCellColumns(5)
                ForEach(panel.members.prefix(22)) { process in
                    GridRow {
                        Text(process.identity == family.root.identity ? "root" : "child")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(process.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(process.pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(RadarBytes.string(process.memoryForScoringBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(Int(process.cpuPercent.rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func column(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

private struct FamilyForensicsPanel: View {
    let panel: FamilyDetailPanelModel

    var body: some View {
        RadarSection(
            title: "Forensics",
            subtitle: panel.forensics.isPartial ? "partial" : "fresh",
            systemImage: "magnifyingglass",
            tip: RadarTip(
                title: "Forensics",
                message: "Deeper facts gathered on demand: working directory, open files, sockets, and listening ports. \"Partial\" means the scanner deferred some probes to stay inside its time budget — they refresh on the next pass."
            )
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                forensic("Fresh", panel.forensics.freshnessText)
                forensic("CWD", panel.forensics.currentDirectory)
                forensic("Root", panel.forensics.rootDirectory)
                forensic("Files", panel.forensics.openFileText)
                forensic("Sockets", panel.forensics.socketText)
                forensic("Ports", panel.forensics.portsText)
            }
            if !panel.forensics.notes.isEmpty {
                FlowTags(title: "Notes", items: panel.forensics.notes)
            }
        }
    }

    private func forensic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct FamilyActionsPanel: View {
    let panel: FamilyDetailPanelModel
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
                    Label("Kill Tree", systemImage: "scope")
                }
                .disabled(!panel.hasOwnedTargets)
                .help(panel.hasOwnedTargets ? "Preview and confirm a kill of this process tree" : "No live processes owned by you to target")
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

private struct MetricCardGrid: View {
    let cards: [FamilyMetricCard]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            ForEach(cards) { card in
                RadarChip(title: card.title, value: card.value, systemImage: card.systemImage, level: card.level)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

struct FamilyInspectorView: View {
    let family: ProcessFamily
    let detail: FamilyDetailViewModel?
    let panel: FamilyDetailPanelModel?

    private var panelModel: FamilyDetailPanelModel {
        panel ?? FamilyDetailPanelModel(family: family, previous: nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RadarSection(title: "Selection") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Kind", panelModel.kind.label)
                        row("Score", panelModel.scoreText)
                        row("Status", panelModel.statusText)
                        row("Forecast", "\(panelModel.forecastStateText), \(panelModel.forecastETA)")
                        row("Why now", panelModel.forecastWhyNow)
                        row("Changed", panelModel.change.summary)
                    }
                }

                RadarSection(title: "Forensics") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Fresh", panelModel.forensics.freshnessText)
                        row("CWD", panelModel.forensics.currentDirectory)
                        row("Files", panelModel.forensics.openFileText)
                        row("Ports", panelModel.forensics.portsText)
                    }
                }

                RadarSection(title: "Tree") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(panelModel.members.prefix(10)) { process in
                            HStack(spacing: 8) {
                                Text(process.identity == family.root.identity ? "root" : "child")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .leading)
                                Text(process.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("pid \(process.pid)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}
