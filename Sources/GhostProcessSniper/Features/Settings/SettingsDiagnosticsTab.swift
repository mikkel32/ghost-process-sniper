import AppKit
import GhostProcessSniperCore
import SwiftUI

/// Engine telemetry for bug reports, kept out of the everyday console.
struct DiagnosticsSettingsTab: View {
    let monitor: ProcessMonitor

    @State private var copied = false

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Diagnostics",
                subtitle: monitor.engineDiagnostics.statusLine,
                systemImage: "stethoscope",
                accent: .teal
            ) {
                HStack(spacing: 10) {
                    SettingsMetricTile(title: "Last refresh", value: monitor.engineDiagnostics.refreshCostText, systemImage: "timer")
                    SettingsMetricTile(title: "Average", value: monitor.engineDiagnostics.averageCostText, systemImage: "chart.bar")
                    SettingsMetricTile(title: "Self CPU", value: String(format: "%.1f%%", monitor.selfUsage.averageCPUPercent), systemImage: "cpu")
                }

                VStack(spacing: 7) {
                    SettingsDiagnosticRow("Last sample", monitor.lastSampleDate?.formatted(date: .omitted, time: .standard) ?? "warming")
                    SettingsDiagnosticRow("Last stop", monitor.storeHealth.lastKillOperationSummary ?? "none")
                    SettingsDiagnosticRow("Self memory", monitor.selfUsage.footprintBytes > 0 ? RadarFormat.bytes(monitor.selfUsage.footprintBytes) : "measuring")
                    SettingsDiagnosticRow("Self throttle", monitor.selfUsage.isThrottling ? "active" : "off")
                    SettingsDiagnosticRow("Store phase", "\(Int(monitor.performanceMetrics.lastRefresh.storeMilliseconds.rounded())) ms")
                    SettingsDiagnosticRow("Store backlog", monitor.engineDiagnostics.storeBacklogText)
                    SettingsDiagnosticRow("Host pressure", monitor.systemPressure.isKnown ? monitor.systemPressure.level.label : "unknown")
                }
                .font(.callout)

                if let error = monitor.storeError ?? monitor.health.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.clipboard") {
                        Task {
                            let report = await monitor.exportDiagnosticsReport()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                            copied = true
                            // Back to the plain label so the next copy shows fresh feedback.
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    }
                    .help("Copy the full engine report for a bug report")
                }
            }
        }
    }
}
