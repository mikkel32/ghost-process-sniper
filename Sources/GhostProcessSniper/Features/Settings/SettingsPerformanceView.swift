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

                LiveEngineTiles(monitor: monitor)

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

            EngineHealthCard(monitor: monitor)
        }
    }
}

/// Live engine readings change every refresh; keeping them out of the tab's
/// body keeps the Picker and Slider above from re-evaluating each tick.
private struct LiveEngineTiles: View {
    let monitor: ProcessMonitor

    var body: some View {
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
    }
}

private struct EngineHealthCard: View {
    let monitor: ProcessMonitor

    var body: some View {
        let diagnostics = monitor.engineDiagnostics
        SettingsCard(
            title: "Engine health",
            subtitle: diagnostics.statusLine,
            systemImage: "stethoscope",
            accent: .teal
        ) {
            HStack(spacing: 10) {
                SettingsMetricTile(title: "Average", value: diagnostics.averageCostText, systemImage: "chart.bar")
                SettingsMetricTile(title: "Pressure", value: diagnostics.pressureText, systemImage: "thermometer.medium")
                SettingsMetricTile(title: "Backlog", value: diagnostics.storeBacklogText, systemImage: "tray.full")
            }

            DisclosureGroup("Technical diagnostics") {
                VStack(spacing: 7) {
                    SettingsDiagnosticRow("Forensics", diagnostics.forensicsText)
                    SettingsDiagnosticRow("Scanner lanes", diagnostics.scannerLaneText)
                    SettingsDiagnosticRow("Deadline", diagnostics.deadlineText)
                    SettingsDiagnosticRow("Probe cost", diagnostics.scannerCostText)
                    SettingsDiagnosticRow("Smoothness", diagnostics.smoothnessText)
                    SettingsDiagnosticRow("Cache", diagnostics.cacheText)
                    SettingsDiagnosticRow("Store coalescing", diagnostics.storeCoalescingText)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }
}
