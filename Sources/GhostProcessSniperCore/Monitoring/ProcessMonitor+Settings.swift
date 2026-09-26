import Foundation

extension ProcessMonitor {
    /// Until the stored settings have loaded, `settings` holds the defaults
    /// plus any edits, so saving it would put the defaults back over every
    /// stored value. A save therefore loads (and merges) first, and is
    /// dropped when that fails; the edit stays in memory and is merged and
    /// saved when a later tick's load succeeds.
    public func saveSettingsDebounced(delay: TimeInterval = 0.45) {
        settingsSaveTask?.cancel()
        settingsSaveTask = DebouncedTask.schedule(delay: delay) { [weak self] in
            await self?.saveSettingsIfLoaded()
        }
    }

    func saveSettingsIfLoaded() async {
        guard await loadPersistedSettingsIfNeeded() else {
            return
        }
        try? await store?.saveSettings(settings)
    }

    /// Callers arriving while a load runs share it. Returns whether the
    /// stored settings are loaded.
    @discardableResult
    func loadPersistedSettingsIfNeeded() async -> Bool {
        if didLoadPersistedSettings {
            return true
        }
        if let settingsLoad {
            return await settingsLoad.value
        }
        // The task clears itself: a caller resuming late must not leave a
        // finished, failed load for the next caller to join.
        let load = Task {
            let loaded = await self.loadPersistedSettings()
            self.settingsLoad = nil
            return loaded
        }
        settingsLoad = load
        return await load.value
    }

    private func loadPersistedSettings() async -> Bool {
        guard let store else {
            didLoadPersistedSettings = true
            await loadStoredRulesAndIncidents()
            return true
        }
        do {
            let stored = try await store.loadSettings(defaults: settingsBeforeLoad)
            // The first open can take seconds after an upgrade; an edit made
            // meanwhile must not be reverted.
            let merged = settings.edits(since: settingsBeforeLoad, appliedTo: stored)
            if merged != settings {
                settings = merged
            }
            didLoadPersistedSettings = true
            if merged != stored {
                try? await store.saveSettings(merged)
            }
        } catch {
            let message = error.localizedDescription
            if storeError != message {
                storeError = message
            }
            return false
        }
        await loadStoredRulesAndIncidents()
        return true
    }
}

extension ThresholdSettings {
    /// `stored` with every field that `self` changed relative to `base`.
    func edits(since base: ThresholdSettings, appliedTo stored: ThresholdSettings) -> ThresholdSettings {
        var merged = stored
        func carry<Value: Equatable>(_ field: WritableKeyPath<ThresholdSettings, Value>) {
            if self[keyPath: field] != base[keyPath: field] {
                merged[keyPath: field] = self[keyPath: field]
            }
        }
        carry(\.memoryBytes)
        carry(\.cpuPercent)
        carry(\.leakVelocityMegabytesPerMinute)
        carry(\.refreshInterval)
        carry(\.forceKillDelay)
        carry(\.radarMode)
        carry(\.groupFamilies)
        carry(\.performanceMode)
        carry(\.detectionMode)
        carry(\.sensitivity)
        carry(\.adaptivePerformance)
        return merged
    }
}
