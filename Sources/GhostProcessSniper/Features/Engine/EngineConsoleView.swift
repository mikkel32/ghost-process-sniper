import AppKit
import Charts
import GhostProcessSniperCore
import SwiftUI

struct EngineConsoleView: View {
    let monitor: ProcessMonitor
    var refreshHistory: [RefreshCostSample] = []
    var onCopyDiagnostics: (() -> Void)?

    private var engine: EngineDiagnosticsViewModel {
        monitor.engineDiagnostics
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RadarPageHeader(
                    eyebrow: "System Health",
                    title: "Engine",
                    subtitle: engine.statusLine,
                    systemImage: "gauge.with.dots.needle.67percent",
                    accent: .teal
                ) {
                    Button {
                        if let onCopyDiagnostics {
                            onCopyDiagnostics()
                        } else {
                            Task {
                                let report = await monitor.exportDiagnosticsReport()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report, forType: .string)
                            }
                        }
                    } label: {
                        Label("Copy Diagnostics", systemImage: "stethoscope")
                    }
                }

                EngineHealthStrip(
                    metrics: monitor.performanceMetrics,
                    health: monitor.health,
                    storeHealth: monitor.storeHealth
                )

                if refreshHistory.count >= 3 {
                    RadarSection(
                        title: "Refresh Cost",
                        subtitle: "last \(refreshHistory.count) refreshes",
                        systemImage: "chart.bar",
                        tip: RadarTip(
                            title: "Refresh Cost",
                            message: "What each radar sweep costs the engine, in milliseconds. Bars turn orange past 2× the average. If the app's own average CPU crosses budget, it self-throttles by stretching the refresh cadence — see the Self rows below."
                        ),
                        accent: .teal
                    ) {
                        refreshCostChart
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    EngineMetricGroup(
                        title: "Sampling",
                        systemImage: "dot.radiowaves.left.and.right",
                        accent: .teal,
                        metrics: [
                            ("Mode", monitor.performanceMetrics.mode.label),
                            ("Last refresh", engine.refreshCostText),
                            ("Average", engine.averageCostText),
                            ("Next sample", engine.nextRefreshText),
                            ("Scanner lanes", engine.scannerLaneText),
                            ("Deadline", engine.deadlineText)
                        ]
                    )
                    EngineMetricGroup(
                        title: "UI Smoothness",
                        systemImage: "waveform.path",
                        accent: .blue,
                        metrics: [
                            ("Smoothness", engine.smoothnessText),
                            ("Probe cost", engine.scannerCostText),
                            ("Cache", engine.cacheText),
                            ("Expensive calls", engine.expensiveCallText),
                            ("Host pressure", monitor.systemPressure.isKnown ? monitor.systemPressure.level.label : "unknown")
                        ]
                    )
                    EngineMetricGroup(
                        title: "Storage",
                        systemImage: "externaldrive",
                        accent: .purple,
                        metrics: [
                            ("Store phase", "\(Int(monitor.performanceMetrics.lastRefresh.storeMilliseconds.rounded())) ms"),
                            ("Backlog", engine.storeBacklogText),
                            ("Coalescing", engine.storeCoalescingText),
                            ("Forensics", engine.forensicsText),
                            ("Last kill", monitor.storeHealth.lastKillOperationSummary ?? "none")
                        ]
                    )
                    EngineMetricGroup(
                        title: "Self Cost",
                        systemImage: "cpu",
                        accent: monitor.selfUsage.isThrottling ? .orange : .green,
                        metrics: [
                            ("CPU", String(format: "%.1f%% now / %.1f%% avg", monitor.selfUsage.cpuPercent, monitor.selfUsage.averageCPUPercent)),
                            ("Memory", monitor.selfUsage.footprintBytes > 0 ? RadarFormat.bytes(monitor.selfUsage.footprintBytes) : "measuring"),
                            ("Throttle", monitor.selfUsage.isThrottling ? "active" : "off"),
                            ("Pressure", engine.pressureText)
                        ]
                    )
                }

                if let error = monitor.storeError ?? monitor.health.errorMessage {
                    RadarSection(title: "Health") {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private var refreshCostChart: some View {
        let average = refreshHistory.reduce(0) { $0 + $1.milliseconds } / Double(max(1, refreshHistory.count))
        return Chart {
            ForEach(refreshHistory) { sample in
                BarMark(
                    x: .value("Refresh sequence", sample.id),
                    y: .value("Refresh cost in milliseconds", sample.milliseconds),
                    width: .fixed(8)
                )
                .cornerRadius(2)
                .foregroundStyle(
                    sample.milliseconds > average * 2
                        ? Color.orange.gradient
                        : Color.teal.gradient
                )
            }
            RuleMark(y: .value("Average", average))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary)
                .annotation(position: .topTrailing, alignment: .trailing) {
                    Text("avg \(Int(average.rounded())) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let milliseconds = value.as(Double.self) {
                        Text("\(Int(milliseconds)) ms")
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .frame(height: 110)
    }

}

private struct EngineMetricGroup: View {
    let title: String
    let systemImage: String
    let accent: Color
    let metrics: [EngineMetric]

    init(
        title: String,
        systemImage: String,
        accent: Color,
        metrics: [(String, String)]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.metrics = metrics.map(EngineMetric.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(accent)
            Divider()
            ForEach(metrics) { metric in
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(metric.value)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .radarSurface(tint: accent, cornerRadius: 14)
    }
}

private struct EngineMetric: Identifiable {
    let title: String
    let value: String

    var id: String { title }

    init(_ tuple: (String, String)) {
        title = tuple.0
        value = tuple.1
    }
}

struct EngineInspectorView: View {
    let monitor: ProcessMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RadarSection(title: "Sampler") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Engine", monitor.health.engineName)
                        row("Processes", "\(monitor.health.processCount)")
                        row("Families", "\(monitor.health.familyCount)")
                        row("Deadline", monitor.engineDiagnostics.deadlineText)
                        row("Probe cost", monitor.engineDiagnostics.scannerCostText)
                        row("Smoothness", monitor.engineDiagnostics.smoothnessText)
                        row("Cache", monitor.engineDiagnostics.cacheText)
                        row("Updated", monitor.lastSampleDate?.formatted(date: .omitted, time: .standard) ?? "warming")
                    }
                }

                RadarSection(title: "Store") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Backlog", "\(monitor.storeHealth.backlogCount)")
                        row("Actions", "\(monitor.storeHealth.pendingActionCount)")
                        row("Coalescing", monitor.engineDiagnostics.storeCoalescingText)
                        row("Flush cost", "\(Int(monitor.storeHealth.lastFlushMilliseconds.rounded())) ms")
                        row("Context cost", "\(Int(monitor.storeHealth.lastContextMilliseconds.rounded())) ms")
                        row("Settings skipped", "\(monitor.storeHealth.skippedSettingsWriteCount)")
                        row("Last flush", monitor.storeHealth.lastFlushDate?.formatted(date: .omitted, time: .standard) ?? "none")
                        row("Last prune", monitor.storeHealth.lastPruneDate?.formatted(date: .omitted, time: .standard) ?? "none")
                        row("Last kill", monitor.storeHealth.lastKillOperationSummary ?? "none")
                    }
                }

                RadarSection(title: "Diagnostics") {
                    Text(monitor.engineDiagnostics.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .font(.caption)
    }
}
