import Foundation

extension ProcessMonitor {
    public func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
    }

    /// An open, unobscured console gets the popover's cadence and rich reads,
    /// and a fresh sample as soon as it appears.
    public func setConsoleVisible(_ visible: Bool) {
        guard visible != consoleVisible else { return }
        consoleVisible = visible
        if visible {
            Task { await refresh() }
        }
    }
}
