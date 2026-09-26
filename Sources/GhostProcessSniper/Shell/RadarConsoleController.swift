import AppKit
import GhostProcessSniperCore
import SwiftUI

@MainActor
final class RadarConsoleController: NSObject, NSWindowDelegate {
    private static let frameName = "GhostProcessSniper.RadarConsole"
    private var window: NSWindow?
    // Kept across closes, so a reopened console keeps its place, query and histories.
    private var session: RadarConsoleSession?
    private var monitor: ProcessMonitor?

    func show(monitor: ProcessMonitor, killer: ProcessKiller, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            monitor.setConsoleVisible(true)
            return
        }

        let session = self.session ?? RadarConsoleSession(monitor: monitor, killer: killer, openSettings: openSettings)
        if let key = session.state.focusedSelection.familyKey, session.family(forKey: key) == nil {
            session.state.focusedSelection = .overview
        }
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
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
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
        NSApp.activate()
        monitor.setConsoleVisible(true)
        RadarLogger.ui.info("Opened radar console")
    }

    /// Stop needs a selected family with processes you own; snooze and
    /// ignore need any selected family. Menu validation is rare, so the
    /// answer is computed fresh rather than read from presentation state.
    func canActOnSelection(stop: Bool) -> Bool {
        guard let session, session.state.focusedSelection.familyKey != nil else {
            return false
        }
        return stop ? session.selectedFamily?.ownedIdentities.isEmpty == false : true
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

    func prepareKill(familyKey: String) {
        showIfNeeded()
        session?.focus(.family(familyKey))
        session?.prepareKill(familyKey: familyKey)
    }

    func prepareKillSelected() {
        showIfNeeded()
        session?.prepareKillSelected()
    }

    // A minimized or fully covered console is not a visible surface: the
    // engine drops to its background cadence and the session stops presenting.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        monitor?.setConsoleVisible(false)
        session?.setVisible(false)
        // A stop preview left open must not resurface on the next open.
        session?.pendingKill = nil
        window = nil
        RadarLogger.ui.info("Closed radar console")
    }

    private func updateVisibility() {
        guard let window else {
            return
        }
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        monitor?.setConsoleVisible(visible)
        session?.setVisible(visible)
    }

    private func showIfNeeded() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
