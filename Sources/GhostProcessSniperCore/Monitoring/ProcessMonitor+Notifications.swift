import Foundation

extension ProcessMonitor {
    /// Notifies beside the refresh, never inside it: a notifier can wait on
    /// the user (a permission prompt), and the radar, Scan now, stop
    /// previews and quitting must not wait with it. While a pass runs only
    /// the newest model waits; older ones are stale by the time it ends.
    /// Process alerts the user turned off in Settings stop here, before the
    /// notifier (which asks for permission) is involved at all.
    func scheduleNotification(for model: RadarModel) {
        guard settings.notifications.families else { return }
        pendingNotification = model
        guard notifyTask == nil else { return }
        notifyTask = Task { [weak self, notifier] in
            while let next = self?.takePendingNotification() {
                await notifier.process(model: next)
            }
        }
    }

    private func takePendingNotification() -> RadarModel? {
        guard let next = pendingNotification else {
            notifyTask = nil
            return nil
        }
        pendingNotification = nil
        return next
    }
}
