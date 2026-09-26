import AppKit
import GhostProcessSniperCore
import SwiftUI

/// Settings run through AppKit like the console. macOS refuses the private
/// showSettingsWindow: action for SwiftUI Settings scenes, and SettingsLink
/// cannot bring this accessory app to the front.
@MainActor
final class SettingsWindowController: NSObject {
    private static let frameName = "GhostProcessSniper.Settings"
    private var window: NSWindow?

    func show(monitor: ProcessMonitor) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor))
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        RadarLogger.ui.info("Opened settings")
    }
}
