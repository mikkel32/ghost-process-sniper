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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
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

        self.window = window
        self.session = session
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RadarLogger.ui.info("Opened radar console")
        Task { await monitor.refresh() }
    }

    func refresh() {
        session?.refresh()
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
        window = nil
        session = nil
        RadarLogger.ui.info("Closed radar console")
    }

    private func showIfNeeded() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
