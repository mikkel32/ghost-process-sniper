import AppKit
import GhostProcessSniperCore
import SwiftUI

@MainActor
final class RadarConsoleController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var session: RadarConsoleSession?

    func show(monitor: ProcessMonitor, killer: ProcessKiller) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let session = RadarConsoleSession(monitor: monitor, killer: killer)
        let rootView = RadarConsoleView(session: session)
        let hosting = NSHostingController(rootView: rootView)
        // The console owns its window dimensions. A lazy process list must not
        // turn its changing ideal height into an oversized window constraint.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Process Sniper"
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.contentViewController = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.setFrameAutosaveName("GhostProcessSniper.RadarConsole")
        window.center()
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            var frame = window.frame
            frame.size.width = min(frame.width, visibleFrame.width)
            frame.size.height = min(frame.height, visibleFrame.height)
            frame.origin.x = max(visibleFrame.minX, min(frame.minX, visibleFrame.maxX - frame.width))
            frame.origin.y = max(visibleFrame.minY, min(frame.minY, visibleFrame.maxY - frame.height))
            window.setFrame(frame, display: false)
        }

        self.window = window
        self.session = session
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RadarLogger.ui.info("Opened radar console")
    }

    @discardableResult
    func refresh() -> Bool {
        guard let session else {
            return false
        }
        session.refresh()
        return true
    }

    func toggleInspector() {
        showIfNeeded()
        session?.toggleInspector()
    }

    func copyReport() {
        showIfNeeded()
        session?.copyReport()
    }

    func copyDiagnostics() {
        showIfNeeded()
        session?.copyDiagnostics()
    }

    func find() {
        showIfNeeded()
        session?.requestSearchFocus()
    }

    func focusFamily(_ signatureID: String) {
        showIfNeeded()
        session?.focus(.family(signatureID))
    }

    func focusSection(_ selection: RadarFocusedSelection) {
        showIfNeeded()
        session?.focus(selection)
    }

    func nextFamily() {
        showIfNeeded()
        session?.nextFamily()
    }

    func previousFamily() {
        showIfNeeded()
        session?.previousFamily()
    }

    func snoozeSelected() {
        showIfNeeded()
        session?.snoozeSelected()
    }

    func ignoreSelected() {
        showIfNeeded()
        session?.ignoreSelected()
    }

    func prepareKillSelected() {
        showIfNeeded()
        session?.prepareKillSelected()
    }

    func windowWillClose(_ notification: Notification) {
        session?.stopPresentation()
        window = nil
        session = nil
        RadarLogger.ui.info("Closed radar console")
    }

    private func showIfNeeded() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
