import Foundation

extension ProcessMonitor {
    /// The awaitable quit path. stop() cancels a debounced settings save and
    /// cannot wait for the store, so on its own a change made just before
    /// quitting would be lost and the WAL never checkpointed.
    public func shutdown() async {
        let settingsSavePending = settingsSaveTask != nil
        stop()
        if settingsSavePending {
            try? await store?.saveSettings(settings)
        }
        await store?.close()
    }
}
