import Foundation

extension ProcessMonitor {
    /// The awaitable quit path. stop() cancels a debounced settings save and
    /// cannot wait for the store, so on its own a change made just before
    /// quitting would be lost and the WAL never checkpointed. A stop still
    /// running finishes first, so its approved force goes out, and every
    /// finished stop is recorded before the store closes.
    public func shutdown() async {
        await activeStopsFinished()
        await postKillTask?.value
        let settingsSavePending = settingsSaveTask != nil
        stop()
        if settingsSavePending {
            await saveSettingsIfLoaded()
        }
        await store?.close()
    }

    /// A stop is between confirm and its report: quitting now would cut
    /// its grace short, skip its force and lose its record.
    public var hasActiveStop: Bool { activeStopCount > 0 }

    /// Marks a stop that runs outside `confirmKill`, such as a batch of
    /// duplicate copies, from before its first signal until it has handed
    /// its reports to `recordKills`. Pair every call with `endStop()`.
    public func beginStop() {
        activeStopCount += 1
    }

    public func endStop() {
        activeStopCount = max(0, activeStopCount - 1)
        guard activeStopCount == 0 else { return }
        let waiters = activeStopWaiters
        activeStopWaiters = []
        waiters.forEach { $0.resume() }
    }

    func activeStopsFinished() async {
        guard hasActiveStop else { return }
        await withCheckedContinuation { activeStopWaiters.append($0) }
    }
}
