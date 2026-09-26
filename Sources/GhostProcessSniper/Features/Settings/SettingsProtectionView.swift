import GhostProcessSniperCore
import SwiftUI

struct ProtectionSettingsTab: View {
    @Bindable var monitor: ProcessMonitor

    private var profile: ResolvedThresholdProfile {
        monitor.resolvedThresholdProfile
    }

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Protection style",
                subtitle: "Choose the outcome; the engine handles the numbers.",
                systemImage: "wand.and.stars",
                accent: RadarTheme.brand
            ) {
                HStack(spacing: 10) {
                    ForEach(RadarDetectionMode.allCases, id: \.self) { mode in
                        SettingsChoiceCard(
                            title: mode.label,
                            detail: mode.detail,
                            systemImage: mode.systemImage,
                            isSelected: monitor.settings.detectionMode == mode,
                            accent: mode == .automatic ? RadarTheme.brand : .orange
                        ) {
                            monitor.settings.detectionMode = mode
                        }
                    }
                }

                if monitor.settings.detectionMode == .automatic {
                    Divider()

                    LabeledContent("Sensitivity") {
                        Picker("Sensitivity", selection: $monitor.settings.sensitivity) {
                            ForEach(RadarSensitivity.allCases, id: \.self) { sensitivity in
                                Text(sensitivity.label).tag(sensitivity)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 330)
                    }

                    Label(monitor.settings.sensitivity.detail, systemImage: monitor.settings.sensitivity.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: "What to watch",
                subtitle: "Start focused; widen the radar only when you need it.",
                systemImage: "scope",
                accent: .purple
            ) {
                Picker("Process scope", selection: $monitor.settings.radarMode) {
                    ForEach(RadarMode.allCases, id: \.self) { mode in
                        Text(mode.userLabel).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Label(monitor.settings.radarMode.detail, systemImage: monitor.settings.radarMode.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(
                title: "Current safety rails",
                subtitle: profile.isAdaptive ? "Recalculated from this Mac and live pressure." : "Your exact custom limits.",
                systemImage: "shield.lefthalf.filled",
                accent: profile.isAdaptive ? RadarTheme.brand : .orange
            ) {
                HStack(spacing: 10) {
                    SettingsMetricTile(
                        title: "Memory",
                        value: profile.memoryThresholdText,
                        systemImage: "memorychip"
                    )
                    SettingsMetricTile(
                        title: "CPU",
                        value: profile.cpuThresholdText,
                        systemImage: "cpu"
                    )
                    SettingsMetricTile(
                        title: "Growth",
                        value: profile.leakThresholdText,
                        systemImage: "chart.line.uptrend.xyaxis"
                    )
                }

                if profile.isAdaptive {
                    Text(profile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Divider()
                    customThresholdControls
                }

                DisclosureGroup("Advanced detection behavior") {
                    Toggle("Keep related child processes together", isOn: $monitor.settings.groupFamilies)
                        .help("Groups helpers, workers, and child processes into one family so totals and actions stay understandable.")
                    Text("Grouping is recommended: one app or development session appears as one item instead of many PIDs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private var customThresholdControls: some View {
        VStack(spacing: 12) {
            SettingsSlider(
                title: "Memory",
                value: Binding(
                    get: { monitor.settings.memoryGigabytes },
                    set: { monitor.settings.memoryGigabytes = $0 }
                ),
                range: 0.5...32,
                step: 0.5,
                display: String(format: "%.1f GB", monitor.settings.memoryGigabytes)
            )
            SettingsSlider(
                title: "CPU",
                value: $monitor.settings.cpuPercent,
                range: 40...400,
                step: 5,
                display: "\(Int(monitor.settings.cpuPercent))%"
            )
            SettingsSlider(
                title: "Growth",
                value: $monitor.settings.leakVelocityMegabytesPerMinute,
                range: 20...1000,
                step: 10,
                display: "\(Int(monitor.settings.leakVelocityMegabytesPerMinute)) MB/min"
            )
        }
    }
}
