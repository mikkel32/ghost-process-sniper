import AppKit
import GhostProcessSniperCore
import SwiftUI
import UserNotifications

/// The sheet a first-ever launch opens over the console. Ghost has no Dock
/// icon, so it says where the app lives, and offers the two things a newcomer
/// would otherwise meet out of context: the macOS notification prompt (which
/// the first alert raises unannounced) and the login item. Neither is
/// required. The launch records that it was shown before the window opens, so
/// however this closes, it never comes back.
struct RadarWelcomeView: View {
    /// Asks the console to open the Quick Guide once this sheet has closed.
    let takeTour: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// nil until read, and in unbundled builds that have no notification center.
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var launchAtLogin = false
    @State private var needsLoginApproval = false
    @State private var launchAtLoginError: String?

    private var notificationCenterAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                RadarBrandMark(level: .quiet, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Ghost Process Sniper")
                        .font(.title2.weight(.bold))
                    Text("Ghost lives in your menu bar, and closing this window keeps it running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                setupRow(icon: "bell.badge", title: "Notifications", detail: notificationDetail) {
                    notificationControl
                }
                if WelcomePolicy.offersLaunchAtLogin(bundleURL: Bundle.main.bundleURL) {
                    launchAtLoginRow
                } else {
                    setupRow(
                        icon: "power",
                        title: "Open at login",
                        detail: "Move Ghost Process Sniper to your Applications folder first, then turn this on in Settings."
                    ) {}
                }
            }

            Text("You can change both later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Take the Tour") {
                    takeTour()
                    dismiss()
                }
                .controlSize(.large)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
        .tint(RadarTheme.brand)
        .task {
            await refreshNotificationStatus()
            readLaunchAtLoginStatus()
        }
        // Both are answered outside this window (a system prompt, System
        // Settings), so pick the answer up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLaunchAtLoginStatus()
            Task { await refreshNotificationStatus() }
        }
    }

    // MARK: Notifications

    private var notificationDetail: String {
        switch notificationStatus {
        case .denied:
            "macOS is blocking Ghost's alerts. Allow them in System Settings › Notifications."
        default:
            "A banner when a process needs attention, even with the console closed."
        }
    }

    @ViewBuilder private var notificationControl: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("On", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        case .denied:
            Button("Open Settings") { openNotificationSettings() }
        case .notDetermined:
            Button("Allow") { Task { await requestNotifications() } }
                .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
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

    // MARK: Open at login

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            setupRow(
                icon: "power",
                title: "Open at login",
                detail: "Start Ghost when you sign in, so it keeps watching after a restart."
            ) {
                // A closure, not the method: passing it directly crashes the Swift 6.3 compiler.
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { updateLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
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
                .padding(.leading, 54)
            }
            if let launchAtLoginError {
                Label(launchAtLoginError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 54)
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
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

    // MARK: Layout

    private func setupRow<Control: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(RadarTheme.brand)
                .frame(width: 40, height: 40)
                .background(RadarTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
