import GhostProcessSniperCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var monitor: ProcessMonitor

    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var notificationStatus = "Not checked"

    var body: some View {
        TabView {
            RadarSettingsTab(monitor: monitor)
                .tabItem { Label("Radar", systemImage: "scope") }
            AlertsSettingsTab(
                monitor: monitor,
                notificationStatus: notificationStatus,
                requestNotifications: { await requestNotifications() }
            )
            .tabItem { Label("Alerts", systemImage: "bell") }
            PerformanceSettingsTab(monitor: monitor)
                .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.67percent") }
            SystemSettingsTab(
                launchAtLogin: $launchAtLogin,
                launchAtLoginError: $launchAtLoginError
            )
            .tabItem { Label("System", systemImage: "gearshape.2") }
        }
        .frame(width: 560, height: 450)
        .padding(18)
        .task {
            launchAtLogin = LaunchAtLoginController.isEnabled
            await refreshNotificationStatus()
        }
        .onChange(of: monitor.settings) { _, _ in
            monitor.saveSettingsDebounced()
        }
    }

    // UNUserNotificationCenter raises an exception in unbundled dev builds.
    private var notificationCenterAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func requestNotifications() async {
        guard notificationCenterAvailable else {
            return
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshNotificationStatus()
    }

    private func refreshNotificationStatus() async {
        guard notificationCenterAvailable else {
            notificationStatus = "Unavailable in unbundled build"
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            notificationStatus = switch settings.authorizationStatus {
            case .authorized: "Allowed"
            case .denied: "Denied"
            case .notDetermined: "Not asked"
            case .provisional: "Provisional"
            case .ephemeral: "Ephemeral"
            @unknown default: "Unknown"
            }
        }
    }
}

private struct RadarSettingsTab: View {
    @Bindable var monitor: ProcessMonitor

    var body: some View {
        Form {
            Section("Scope") {
                Picker("Radar mode", selection: $monitor.settings.radarMode) {
                    ForEach(RadarMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Group process families", isOn: $monitor.settings.groupFamilies)
                LabeledContent("Current families", value: "\(monitor.summary.familyCount)")
            }

            Section("Thresholds") {
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
                SettingsSlider(title: "CPU", value: $monitor.settings.cpuPercent, range: 10...400, step: 10, display: "\(Int(monitor.settings.cpuPercent))%")
                SettingsSlider(title: "Leak", value: $monitor.settings.leakVelocityMegabytesPerMinute, range: 20...1000, step: 20, display: "\(Int(monitor.settings.leakVelocityMegabytesPerMinute)) MB/min")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertsSettingsTab: View {
    @Bindable var monitor: ProcessMonitor
    let notificationStatus: String
    let requestNotifications: () async -> Void

    var body: some View {
        Form {
            Section("Notifications") {
                HStack {
                    Text("Authorization")
                    Spacer()
                    Text(notificationStatus)
                        .foregroundStyle(.secondary)
                    Button("Allow") {
                        Task { await requestNotifications() }
                    }
                }
            }

            Section("Kill Flow") {
                SettingsSlider(
                    title: "Force delay",
                    value: $monitor.settings.forceKillDelay,
                    range: 0.5...8,
                    step: 0.5,
                    display: String(format: "%.1fs", monitor.settings.forceKillDelay)
                )
                LabeledContent("Policy", value: "Preview required")
                LabeledContent("Automatic kill", value: "Disabled")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceSettingsTab: View {
    @Bindable var monitor: ProcessMonitor

    var body: some View {
        Form {
            Section("Cadence") {
                Picker("Mode", selection: $monitor.settings.performanceMode) {
                    ForEach(RadarPerformanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                SettingsSlider(
                    title: "Refresh",
                    value: $monitor.settings.refreshInterval,
                    range: 0.5...5,
                    step: 0.5,
                    display: String(format: "%.1fs", monitor.settings.refreshInterval)
                )
            }

            Section("Engine") {
                metric("Last refresh", monitor.engineDiagnostics.refreshCostText)
                metric("Average", monitor.engineDiagnostics.averageCostText)
                metric("Next sample", monitor.engineDiagnostics.nextRefreshText)
                metric("Forensics", monitor.engineDiagnostics.forensicsText)
                metric("Scanner lanes", monitor.engineDiagnostics.scannerLaneText)
                metric("Deadline", monitor.engineDiagnostics.deadlineText)
                metric("Probe cost", monitor.engineDiagnostics.scannerCostText)
                metric("Smoothness", monitor.engineDiagnostics.smoothnessText)
                metric("Cache", monitor.engineDiagnostics.cacheText)
                metric("Expensive calls", monitor.engineDiagnostics.expensiveCallText)
                metric("Store backlog", monitor.engineDiagnostics.storeBacklogText)
                metric("Store coalescing", monitor.engineDiagnostics.storeCoalescingText)
                metric("Pressure", monitor.engineDiagnostics.pressureText)
            }
        }
        .formStyle(.grouped)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } label: {
            Text(title)
        }
    }
}

private struct SystemSettingsTab: View {
    @Binding var launchAtLogin: Bool
    @Binding var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                try LaunchAtLoginController.setEnabled(newValue)
                                launchAtLogin = LaunchAtLoginController.isEnabled
                                launchAtLoginError = nil
                            } catch {
                                launchAtLogin = LaunchAtLoginController.isEnabled
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                    )
                )

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Safety Boundary") {
                LabeledContent("Privileged helper", value: "Not installed")
                LabeledContent("Endpoint Security", value: "Future architecture only")
                LabeledContent("Automatic cleanup", value: "Off")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text(title)
                    .frame(width: 82, alignment: .leading)
                Slider(value: value, in: range, step: step)
                Text(display)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
        }
    }
}
