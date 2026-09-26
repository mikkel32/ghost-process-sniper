import GhostProcessSniperCore
import SwiftUI

struct PerformanceSettingsTab: View {
    @Bindable var monitor: ProcessMonitor

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Automatic performance",
                subtitle: "Spend resources only when the situation deserves it.",
                systemImage: "gauge.with.dots.needle.67percent",
                accent: RadarTheme.brand
            ) {
                Toggle(isOn: $monitor.settings.adaptivePerformance) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Adapt scanning speed")
                            .font(.headline)
                        Text("Realtime while investigating, balanced in the background, and calmer under thermal pressure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: 10) {
                    SettingsMetricTile(
                        title: "Active mode",
                        value: monitor.performanceMetrics.mode.label,
                        systemImage: monitor.performanceMetrics.mode.systemImage
                    )
                    SettingsMetricTile(
                        title: "Next sample",
                        value: monitor.engineDiagnostics.nextRefreshText,
                        systemImage: "clock.arrow.2.circlepath"
                    )
                    SettingsMetricTile(
                        title: "Last refresh",
                        value: monitor.engineDiagnostics.refreshCostText,
                        systemImage: "timer"
                    )
                }

                if !monitor.settings.adaptivePerformance {
                    Divider()
                    Picker("Performance mode", selection: $monitor.settings.performanceMode) {
                        ForEach(RadarPerformanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(monitor.settings.performanceMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SettingsSlider(
                        title: "Refresh",
                        value: $monitor.settings.refreshInterval,
                        range: 0.5...5,
                        step: 0.5,
                        display: String(format: "%.1f sec", monitor.settings.refreshInterval)
                    )
                }
            }

            SettingsCard(
                title: "Engine health",
                subtitle: monitor.engineDiagnostics.statusLine,
                systemImage: "stethoscope",
                accent: .teal
            ) {
                HStack(spacing: 10) {
                    SettingsMetricTile(title: "Average", value: monitor.engineDiagnostics.averageCostText, systemImage: "chart.bar")
                    SettingsMetricTile(title: "Pressure", value: monitor.engineDiagnostics.pressureText, systemImage: "thermometer.medium")
                    SettingsMetricTile(title: "Backlog", value: monitor.engineDiagnostics.storeBacklogText, systemImage: "tray.full")
                }

                DisclosureGroup("Technical diagnostics") {
                    VStack(spacing: 7) {
                        SettingsDiagnosticRow("Forensics", monitor.engineDiagnostics.forensicsText)
                        SettingsDiagnosticRow("Scanner lanes", monitor.engineDiagnostics.scannerLaneText)
                        SettingsDiagnosticRow("Deadline", monitor.engineDiagnostics.deadlineText)
                        SettingsDiagnosticRow("Probe cost", monitor.engineDiagnostics.scannerCostText)
                        SettingsDiagnosticRow("Smoothness", monitor.engineDiagnostics.smoothnessText)
                        SettingsDiagnosticRow("Cache", monitor.engineDiagnostics.cacheText)
                        SettingsDiagnosticRow("Store coalescing", monitor.engineDiagnostics.storeCoalescingText)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
    }
}
