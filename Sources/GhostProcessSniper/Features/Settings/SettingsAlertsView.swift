import GhostProcessSniperCore
import SwiftUI

struct AlertsSettingsTab: View {
    @Bindable var monitor: ProcessMonitor
    let notificationStatus: String
    let requestNotifications: () async -> Void
    let openNotificationSettings: () -> Void

    private var notificationsAllowed: Bool {
        notificationStatus == "Allowed" || notificationStatus == "Provisional"
    }

    private var notificationsDenied: Bool {
        notificationStatus == "Denied"
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
                        Text("macOS status: \(notificationStatus)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !notificationsAllowed {
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
                Text("After a normal quit signal, the app waits this long before offering the force step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
