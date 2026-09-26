import AppKit
import GhostProcessSniperCore
import ServiceManagement
import SwiftUI

struct SystemSettingsTab: View {
    let monitor: ProcessMonitor
    @Binding var launchAtLogin: Bool
    @Binding var launchAtLoginError: String?
    @State private var isConfirmingRestore = false
    @State private var needsLoginApproval = false

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Startup",
                subtitle: "Keep protection available without opening a normal app window.",
                systemImage: "power",
                accent: .green
            ) {
                Toggle(
                    "Launch Ghost Process Sniper at login",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            updateLaunchAtLogin(newValue)
                        }
                    )
                )
                .toggleStyle(.switch)

                if needsLoginApproval {
                    HStack(spacing: 10) {
                        Label("Waiting for your approval in System Settings › General › Login Items", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open Login Items") {
                            LaunchAtLoginController.openLoginItemsSettings()
                        }
                    }
                }

                if let launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(
                title: "Safety boundary",
                subtitle: "The app stays useful without quietly expanding its authority.",
                systemImage: "lock.shield",
                accent: .purple
            ) {
                SettingsSafetyRow(
                    title: "Your processes only",
                    detail: "Protected and differently owned processes are excluded from kill targets.",
                    systemImage: "person.crop.circle",
                    status: "Enforced"
                )
                Divider()
                SettingsSafetyRow(
                    title: "No privileged helper",
                    detail: "The current architecture does not install a root service or Endpoint Security extension.",
                    systemImage: "lock",
                    status: "Local"
                )
                Divider()
                SettingsSafetyRow(
                    title: "Manual final action",
                    detail: "Detection and recommendations are automatic; intervention remains yours.",
                    systemImage: "hand.tap",
                    status: "Required"
                )
            }

            SettingsCard(
                title: "Restore defaults",
                subtitle: "Return to the recommended adaptive setup in one click.",
                systemImage: "arrow.counterclockwise",
                accent: .orange
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Smart protection · Balanced sensitivity")
                            .font(.headline)
                        Text("Developer tools scope, grouped families, adaptive performance, and the safe kill flow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore Smart Defaults") {
                        isConfirmingRestore = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .confirmationDialog(
            "Restore Smart Defaults?",
            isPresented: $isConfirmingRestore
        ) {
            Button("Restore Defaults", role: .destructive) {
                monitor.settings = .smart
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces custom thresholds, scope, and performance choices with the recommended adaptive setup.")
        }
        .onAppear(perform: readLaunchAtLoginStatus)
        // The approval happens in System Settings; pick it up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLaunchAtLoginStatus()
        }
    }

    private func updateLaunchAtLogin(_ newValue: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(newValue)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        readLaunchAtLoginStatus()
    }

    private func readLaunchAtLoginStatus() {
        let status = LaunchAtLoginController.status
        // A registration waiting for approval is still the user's choice, so
        // the switch stays on and the row explains what is pending.
        launchAtLogin = status == .enabled || status == .requiresApproval
        needsLoginApproval = status == .requiresApproval
    }
}
