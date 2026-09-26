import AppKit
import GhostProcessSniperCore
import SwiftUI

@main
struct GhostProcessSniperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menus come from MenuBarCoordinator's NSMenu and Settings from
        // SettingsWindowController; this scene is only a fallback.
        Settings {
            SettingsView(monitor: appDelegate.coordinator.monitor)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = MenuBarCoordinator()
    // The notification center holds its delegate weakly.
    private var notificationRouter: NotificationRouter?
    private var isTerminating = false
    private var didReplyToTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unbundled dev builds have no notification center.
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let router = NotificationRouter(coordinator: coordinator)
        router.install()
        notificationRouter = router
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
        if ProcessInfo.processInfo.arguments.contains("--console") {
            coordinator.openConsole()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }
        isTerminating = true
        Task {
            await coordinator.shutdown()
            replyToTermination()
        }
        Task {
            // A stuck disk must never hold up quitting.
            try? await Task.sleep(for: .seconds(1))
            replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !didReplyToTermination else {
            return
        }
        didReplyToTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.openConsole()
        return true
    }
}
