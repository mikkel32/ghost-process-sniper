import GhostProcessSniperCore
import SwiftUI
import UserNotifications

struct AlertsSettingsTab: View {
    @Bindable var monitor: ProcessMonitor
    /// nil until checked, or in unbundled builds that have no notification center.
    let notificationStatus: UNAuthorizationStatus?
    let notificationsAvailable: Bool
    let requestNotifications: () async -> Void
    let openNotificationSettings: () -> Void

    private var notificationsAllowed: Bool {
        notificationStatus == .authorized || notificationStatus == .provisional
    }

    private var notificationsDenied: Bool {
        notificationStatus == .denied
    }

    private var statusText: String {
        guard notificationsAvailable else {
            return "Unavailable in unbundled build"
        }
        guard let notificationStatus else {
            return "Not checked"
        }
        return switch notificationStatus {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        @unknown default: "Unknown"
        }
    }

    private func alertToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Notifications",
                subtitle: "Get a useful signal when the radar has a credible reason to interrupt you.",
                systemImage: "bell.badge",
                accent: notificationsAllowed ? .green : .orange
            ) {
                HStack(spacing: 12) {
                    Image(systemName: notificationsAllowed ? "checkmark.circle.fill" : "bell.slash")
                        .font(.title2)
                        .foregroundStyle(notificationsAllowed ? Color.green : Color.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(notificationsAllowed ? "Notifications are ready" : "Notifications need attention")
                            .font(.headline)
                        Text("macOS status: \(statusText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if notificationsAvailable, !notificationsAllowed {
                        Button(notificationsDenied ? "Open System Settings" : "Enable Notifications") {
                            if notificationsDenied {
                                openNotificationSettings()
                            } else {
                                Task { await requestNotifications() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text("The rule engine decides when a finding is important enough to notify; quiet and merely noisy processes stay in the console.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(
                title: "What can notify you",
                subtitle: "macOS has one switch for all of Ghost; choose here which alerts may interrupt you.",
                systemImage: "switch.2",
                accent: RadarTheme.brand
            ) {
                alertToggle(
                    "Process alerts",
                    detail: "An app or job that turns Hot or Critical. Each alerts once, again if it gets worse, and as a reminder after 12 hours.",
                    isOn: $monitor.settings.notifications.families
                )
                Divider()
                alertToggle(
                    "Energy alerts",
                    detail: "An app that keeps the Mac awake, wakes it constantly, writes heavily to disk or drains the battery, at most once every 12 hours.",
                    isOn: $monitor.settings.notifications.energy
                )
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Security alerts")
                        .font(.headline)
                    Picker("Security alerts", selection: $monitor.settings.notifications.security) {
                        ForEach(SecurityAlertLevel.allCases, id: \.self) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Text("Dangerous security findings always notify. Whatever you choose here, the Security page, the menu-bar icon and the console still show everything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(
                title: "Safe intervention",
                subtitle: "Actions remain deliberate even when detection is automatic.",
                systemImage: "hand.raised.fill",
                accent: .red
            ) {
                SettingsSafetyRow(
                    title: "Preview before stopping",
                    detail: "You see the exact process tree and protected PIDs before anything changes.",
                    systemImage: "doc.text.magnifyingglass",
                    status: "Always on"
                )
                Divider()
                SettingsSafetyRow(
                    title: "Automatic killing",
                    detail: "The intelligence recommends actions, but never silently kills a process.",
                    systemImage: "person.crop.circle.badge.checkmark",
                    status: "Off"
                )
                Divider()
                SettingsSlider(
                    title: "Grace period",
                    value: $monitor.settings.forceKillDelay,
                    range: 0.5...8,
                    step: 0.5,
                    display: String(format: "%.1f sec", monitor.settings.forceKillDelay)
                )
                Text("How long a normal process gets to exit before Ghost offers to force it. Dev servers and runaways are stopped faster; apps, databases and container runtimes automatically get longer (8–15 s).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
