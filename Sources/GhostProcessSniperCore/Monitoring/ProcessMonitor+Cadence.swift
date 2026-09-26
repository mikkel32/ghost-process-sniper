import Foundation

/// A window that shows live radar data. While any is on screen the radar
/// samples at about one second with realtime budgets.
public enum RadarSurface: Hashable, Sendable {
    case popover
    case console
}

/// Reads temperatures. Injected so tests can see when the SMC is touched.
public protocol ThermalSampling: Sendable {
    func sample(now: Date) async -> ThermalSnapshot
}

extension ThermalSampler: ThermalSampling {}

extension ProcessMonitor {
    var uiVisible: Bool {
        !visibleSurfaces.isEmpty
    }

    /// Showing a surface wakes the loop, so the realtime cadence starts at
    /// once instead of after the hidden sleep (up to 8 s) runs out.
    public func setSurface(_ surface: RadarSurface, visible: Bool) {
        if visible {
            if visibleSurfaces.insert(surface).inserted {
                wake()
            }
        } else {
            visibleSurfaces.remove(surface)
        }
        updateHitchMonitor()
    }

    /// An open, unobscured console window.
    public func setConsoleVisible(_ visible: Bool) {
        setSurface(.console, visible: visible)
    }

    /// The heartbeat wakes the main thread four times a second, and a
    /// hitch nobody can see is not worth that, so it runs only on screen.
    func updateHitchMonitor() {
        if uiVisible, isRunning {
            if !hitchMonitor.isRunning {
                hitchMonitor.start()
            }
        } else {
            hitchMonitor.stop()
        }
    }

    /// Only the popover and console show temperatures, so while hidden they
    /// are read at most this often: enough to keep the trend continuous
    /// (hidden sleeps last at most 8 s plus 15 % slack, under the
    /// observation window's 15 s gap), so it is ready when a panel opens.
    static let hiddenThermalInterval: TimeInterval = 4

    func readsThermals(at now: Date) -> Bool {
        guard !uiVisible, let last = lastThermalReadAt else { return true }
        return !(0..<Self.hiddenThermalInterval).contains(now.timeIntervalSince(last))
    }

    /// Runs one loop tick and returns how long to sleep before the next.
    func runLoopTick(isFirstTick: Bool) async -> TimeInterval {
        wakePending = false
        await refresh(reason: .loop)
        let interval = max(0.25, performanceMetrics.nextRefreshInterval)
        if isFirstTick {
            // CPU percentages need two samples, so take the second soon.
            return min(1, interval)
        }
        return RadarScheduler.selfThrottled(
            interval,
            selfAverageCPUPercent: selfUsage.averageCPUPercent,
            targetIdleCPUPercent: performanceMetrics.budget.targetIdleCPUPercent,
            uiVisible: uiVisible
        )
    }

    /// Hidden sleeps allow 15 % timer slack so the system can batch the
    /// wake-up with others; a visible cadence stays exact. Returns nil when a
    /// wake is already pending. The loop awaits the returned task without
    /// holding the monitor, so a sleep never delays deinit.
    func startSleepUntilNextTick(_ interval: TimeInterval) -> Task<Void, Never>? {
        guard !wakePending else { return nil }
        let tolerance: Duration = uiVisible ? .zero : .seconds(interval * 0.15)
        let sleeper = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(interval), tolerance: tolerance)
        }
        self.sleeper = sleeper
        return sleeper
    }

    /// Runs the next loop tick now: ends a sleep in progress, or skips the
    /// one about to start when a tick is running.
    private func wake() {
        wakePending = true
        sleeper?.cancel()
    }
}
