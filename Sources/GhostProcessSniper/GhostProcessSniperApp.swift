import AppKit
import GhostProcessSniperCore
import SwiftUI

@main
struct GhostProcessSniperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(monitor: appDelegate.coordinator.monitor)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = MenuBarCoordinator()
    private let metricKitSubscriber = RadarMetricKitSubscriber()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        metricKitSubscriber.start()
        coordinator.start()
        if ProcessInfo.processInfo.arguments.contains("--console") {
            coordinator.openConsole()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        metricKitSubscriber.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
