import AppKit
import Charts
import GhostProcessSniperCore
import SwiftUI

struct EngineConsoleView: View {
    @Bindable var monitor: ProcessMonitor
    var refreshHistory: [Double] = []
    var onCopyDiagnostics: (() -> Void)?

    private var engine: EngineDiagnosticsViewModel {
        monitor.engineDiagnostics
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Engine")
                            .font(.largeTitle.weight(.semibold))
                        Text(engine.statusLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                        )
                    ) {
                        refreshCostChart
                    }
                }

                RadarSection(title: "Performance") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
                        metric("Mode", monitor.performanceMetrics.mode.label)
                        metric("Pressure", engine.pressureText)
                        metric("Average", engine.averageCostText)
                        metric("Refresh", engine.refreshCostText)
                        metric("Next", engine.nextRefreshText)
                        metric("Sample", "\(Int(monitor.performanceMetrics.lastRefresh.sampleMilliseconds.rounded())) ms")
                        metric("Build", "\(Int(monitor.performanceMetrics.lastRefresh.buildMilliseconds.rounded())) ms")
                        metric("Score", "\(Int(monitor.performanceMetrics.lastRefresh.scoreMilliseconds.rounded())) ms")
                        metric("Store", "\(Int(monitor.performanceMetrics.lastRefresh.storeMilliseconds.rounded())) ms")
                        metric("Forensics", engine.forensicsText)
                        metric("Scanner lanes", engine.scannerLaneText)
                        metric("Deadline", engine.deadlineText)
                        metric("Probe cost", engine.scannerCostText)
                        metric("Smoothness", engine.smoothnessText)
                        metric("Cache", engine.cacheText)
                        metric("Expensive calls", engine.expensiveCallText)
                        metric("Store backlog", engine.storeBacklogText)
                        metric("Store coalescing", engine.storeCoalescingText)
                        metric("Host pressure", monitor.systemPressure.isKnown ? "\(monitor.systemPressure.level.label) — \(monitor.systemPressure.summaryText)" : "unknown")
                        metric("Self CPU", String(format: "%.1f%% now / %.1f%% average", monitor.selfUsage.cpuPercent, monitor.selfUsage.averageCPUPercent))
                        metric("Self memory", monitor.selfUsage.footprintBytes > 0 ? RadarFormat.bytes(monitor.selfUsage.footprintBytes) : "measuring")
                        metric("Self throttle", monitor.selfUsage.isThrottling ? "active — cadence stretched" : "off")
                        metric("Last kill", monitor.storeHealth.lastKillOperationSummary ?? "none")
                    }
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
        let average = refreshHistory.reduce(0, +) / Double(max(1, refreshHistory.count))
        return Chart {
            ForEach(Array(refreshHistory.enumerated()), id: \.offset) { sample in
                BarMark(
                    x: .value("Refresh", sample.offset),
                    y: .value("ms", sample.element)
                )
                .cornerRadius(2)
                .foregroundStyle(
                    sample.element > average * 2
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

    private func metric(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct EngineInspectorView: View {
    @Bindable var monitor: ProcessMonitor

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
                        row("Updated", monitor.health.lastSampleDate?.formatted(date: .omitted, time: .standard) ?? "warming")
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
