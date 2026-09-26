import Foundation

extension ProcessMonitor {
    /// Records stops that ran outside `confirmKill`, such as a batch of
    /// duplicate copies, then refreshes once. They queue behind any other
    /// stop's follow-ups, and the next plan waits for them.
    public func recordKills(_ stops: [(family: ProcessFamily, report: KillReport)]) {
        guard !stops.isEmpty else { return }
        enqueuePostKill { monitor in
            for stop in stops {
                await monitor.recordKill(report: stop.report, family: stop.family)
            }
            await monitor.refresh()
        }
    }

    /// Runs a stop's follow-ups (recording, the radar refresh) after every
    /// earlier stop's, so `killPlan(for:)` and `shutdown()`, which await
    /// only the latest task, wait for all of them.
    func enqueuePostKill(_ work: @escaping @Sendable @MainActor (ProcessMonitor) async -> Void) {
        let previous = postKillTask
        postKillTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }
}
