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
        .commands {
            CommandMenu("Radar") {
                Button("Overview") { appDelegate.coordinator.openSection(.overview) }
                    .keyboardShortcut("1")
                Button("All Processes") { appDelegate.coordinator.openSection(.processes) }
                    .keyboardShortcut("2")
                Button("Duplicates") { appDelegate.coordinator.openSection(.duplicates) }
                    .keyboardShortcut("3")
                Button("Incidents") { appDelegate.coordinator.openSection(.incidents) }
                    .keyboardShortcut("4")
                Button("Rules") { appDelegate.coordinator.openSection(.rules) }
                    .keyboardShortcut("5")
                Divider()
                Button("Find Processes") { appDelegate.coordinator.findProcesses() }
                    .keyboardShortcut("f")
                Button("Open Console") { appDelegate.coordinator.openConsole() }
                    .keyboardShortcut("o")
            }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.openConsole()
        return true
    }
}
