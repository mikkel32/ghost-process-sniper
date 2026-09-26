import AppKit
import GhostProcessSniperCore
import SwiftUI
import UserNotifications

/// The root body reads only `monitor.settings`; live values such as the
/// performance mode are read by the small views that show them, so a
/// refresh does not re-evaluate the whole tab host.
struct SettingsView: View {
    let monitor: ProcessMonitor

    @State private var selectedSection: SettingsSection = .protection
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var notificationStatus: UNAuthorizationStatus?

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(monitor: monitor)

            Divider()

            TabView(selection: $selectedSection) {
                Tab("Protection", systemImage: "shield.checkered", value: .protection) {
                    ProtectionSettingsTab(monitor: monitor)
                }

                Tab("Alerts", systemImage: "bell.badge", value: .alerts) {
                    AlertsSettingsTab(
                        monitor: monitor,
                        notificationStatus: notificationStatus,
                        notificationsAvailable: notificationCenterAvailable,
                        requestNotifications: { await requestNotifications() },
                        openNotificationSettings: openNotificationSettings
                    )
                }

                Tab("Performance", systemImage: "gauge.with.dots.needle.67percent", value: .performance) {
                    PerformanceSettingsTab(monitor: monitor)
                }

                Tab("System", systemImage: "gearshape.2", value: .system) {
                    SystemSettingsTab(
                        monitor: monitor,
                        launchAtLogin: $launchAtLogin,
                        launchAtLoginError: $launchAtLoginError
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(width: 700, height: 600)
        .tint(RadarTheme.brand)
        .background {
            LinearGradient(
                colors: [RadarTheme.brand.opacity(0.08), RadarTheme.canvas, RadarTheme.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .task {
            await refreshNotificationStatus()
        }
        .onChange(of: monitor.settings) { _, _ in
            monitor.saveSettingsDebounced()
        }
    }

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
            return
        }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private enum SettingsSection: String, Hashable {
    case protection
    case alerts
    case performance
    case system
}

private struct SettingsHeader: View {
    let monitor: ProcessMonitor

    var body: some View {
        let profile = monitor.resolvedThresholdProfile
        HStack(spacing: 14) {
            RadarBrandMark(level: .quiet, size: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("GHOST PROCESS SNIPER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.25)
                    .foregroundStyle(RadarTheme.brand)
                Text(profile.title)
                    .font(.title2.weight(.semibold))
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                SettingsBadge(
                    title: profile.isAdaptive ? "ADAPTIVE" : "CUSTOM",
                    systemImage: profile.isAdaptive ? "wand.and.stars" : "slider.horizontal.3",
                    color: profile.isAdaptive ? RadarTheme.brand : .orange
                )
                Text("\(monitor.summary.familyCount) families · \(monitor.performanceMetrics.mode.label)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
