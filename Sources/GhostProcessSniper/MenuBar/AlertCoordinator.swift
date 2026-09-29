import Foundation
import GhostProcessSniperCore

/// Runs the Sentinel and Energy alert gates over each published state and
/// hands what earned a notification to the notifier. The gates' cooldowns are
/// saved as they change, so an update or login does not announce again what
/// the last run already did.
@MainActor
final class AlertCoordinator {
    private let monitor: ProcessMonitor
    private let notifier: UserNotificationRadarNotifier
    private let memory: AlertMemoryStore
    private var sentinelAlerts: SentinelAlertGate
    private var energyAlerts: EnergyAlertGate
    private var lastSentinelRevision: UInt64 = 0
    /// After an alert could not be posted, the same report is offered again,
    /// but not on every scan.
    private var sentinelRetryAt = Date.distantPast
    private static let retryInterval: TimeInterval = 20
    private var lastEnergyGlance = EnergyGlance.empty

    init(monitor: ProcessMonitor, notifier: UserNotificationRadarNotifier, memory: AlertMemoryStore = .standard) {
        self.monitor = monitor
        self.notifier = notifier
        self.memory = memory
        sentinelAlerts = SentinelAlertGate(memory: memory.load(.sentinel))
        energyAlerts = EnergyAlertGate(memory: memory.load(.energy))
    }

    /// One notification per energy finding that needs attention, such as an
    /// idle app keeping the Mac awake for hours; the glance changes rarely,
    /// so most publishes return at the first comparison.
    func handleEnergyChange() {
        let glance = monitor.energyGlance
        guard glance != lastEnergyGlance else { return }
        lastEnergyGlance = glance
        let alerts = energyAlerts.alerts(for: monitor.energy.findings, now: Date())
        guard !alerts.isEmpty else { return }
        memory.save(energyAlerts.memory, for: .energy)
        // The gate has counted them either way, so switching this on later replays nothing.
        guard monitor.settings.notifications.energy else { return }
        for finding in alerts {
            let notifier = notifier
            Task { await notifier.notify(energy: finding) }
        }
    }

    /// One notification per new suspicious or dangerous thing, as far as the
    /// user's security choice allows. Returns nil while the report is the one
    /// already handled, otherwise whether a new dangerous finding should pulse
    /// the menu-bar icon (which follows the report, not the choice).
    func handleSentinelChange() -> Bool? {
        let report = monitor.sentinel
        let now = Date()
        guard report.revision != lastSentinelRevision, now >= sentinelRetryAt else { return nil }
        lastSentinelRevision = report.revision
        let alerts = sentinelAlerts.alerts(for: report, now: now)
        if !alerts.findings.isEmpty || !alerts.startupItems.isEmpty {
            memory.save(sentinelAlerts.memory, for: .sentinel)
        }
        let allowed = alerts.filtered(by: monitor.settings.notifications.security)
        for finding in allowed.findings {
            let notifier = notifier
            Task { [weak self] in
                if await !notifier.notify(sentinel: finding) { self?.retract(finding) }
            }
        }
        for item in allowed.startupItems {
            let notifier = notifier
            Task { [weak self] in
                if await !notifier.notify(startupItem: item) { self?.retract(item) }
            }
        }
        return alerts.findings.contains { $0.severity == .dangerous }
    }

    /// The notifier could not post it (permission not answered yet, or a
    /// failed post): the gate offers it again with the next report, so an
    /// alert consumed before the user allowed notifications is not lost.
    private func retract(_ finding: SentinelFinding) {
        sentinelAlerts.retract(finding)
        memory.save(sentinelAlerts.memory, for: .sentinel)
        retryUnsettledAlerts()
    }

    private func retract(_ item: LaunchItem) {
        sentinelAlerts.retract(item)
        memory.save(sentinelAlerts.memory, for: .sentinel)
        retryUnsettledAlerts()
    }

    private func retryUnsettledAlerts() {
        lastSentinelRevision = 0
        sentinelRetryAt = Date().addingTimeInterval(Self.retryInterval)
    }
}
