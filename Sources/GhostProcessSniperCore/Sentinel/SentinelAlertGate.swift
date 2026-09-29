import Foundation

/// Decides which findings and startup items earn a notification.
///
/// A finding is one process instance, so a program that restarts or runs
/// many workers would otherwise alert once per process. Alerts are keyed by
/// what was found (the program, its strongest evidence and severity) and
/// held back for a day; a finding that turns dangerous alerts again. Memory
/// stays bounded: IDs are pruned to the current report, keys to the cooldown.
///
/// The cooldowns outlive a relaunch (`memory`), so an update or login does
/// not announce again what the last run already did; only hashes are kept.
/// A dangerous alert is the exception: it waits a day within a run but
/// never because of an earlier one, since that one may have been dropped
/// (notifications were off) and this is the alert that must not stay silent.
public struct SentinelAlertGate: Sendable {
    public static let cooldown: TimeInterval = 24 * 60 * 60

    public struct Alerts: Sendable {
        public var findings: [SentinelFinding] = []
        public var startupItems: [LaunchItem] = []

        /// What the user's choice lets notify. The gate has already counted
        /// everything as alerted, so a level chosen later replays no backlog,
        /// and a finding that turns dangerous is a new one. A dangerous
        /// finding or item always passes.
        public func filtered(by level: SecurityAlertLevel) -> Alerts {
            guard level == .dangerousOnly else { return self }
            return Alerts(findings: findings.filter { $0.severity == .dangerous },
                          startupItems: startupItems.filter { $0.severity == .dangerous })
        }
    }

    private var seenIDs: Set<String> = []
    /// Hashed keys (`AlertMemory.hash`), so it can be saved as it is.
    private var lastAlerted: [String: Date] = [:]
    /// Dangerous alerts, held for the cooldown within this run only.
    private var lastDangerAlerted: [String: Date] = [:]

    public init() {}

    /// A gate that starts with what an earlier run alerted.
    public init(memory: AlertMemory, now: Date = Date()) {
        lastAlerted = memory.live(cooldown: Self.cooldown, at: now)
    }

    /// What to keep for the next launch.
    public var memory: AlertMemory { AlertMemory(lastAlerted: lastAlerted) }

    /// Findings and items already considered; for tests.
    var rememberedIDCount: Int { seenIDs.count }

    /// New suspicious or dangerous running findings, and startup items that
    /// appeared while Ghost was running, not alerted before. A dangerous
    /// finding alerts even when its process has already exited: the spawn
    /// watcher exists to catch commands that finish before the next scan, and
    /// a one-shot stealer is over by the time anyone looks. An exited
    /// suspicious one stays a card on the Security page.
    public mutating func alerts(for report: SentinelReport, now: Date) -> Alerts {
        lastAlerted = lastAlerted.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        lastDangerAlerted = lastDangerAlerted.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        var alerts = Alerts()
        var present = Set<String>()
        for finding in report.findings {
            // Per severity, so a finding that turns dangerous is news again.
            let id = "finding:\(finding.id)|\(finding.severity.rawValue)"
            present.insert(id)
            guard finding.isRunning || finding.severity == .dangerous, finding.severity >= .suspicious,
                  admit(id, key: Self.key(for: finding), dangerous: finding.severity == .dangerous, now: now)
            else { continue }
            alerts.findings.append(finding)
        }
        for item in report.launchItems {
            let id = "startup:" + item.id
            present.insert(id)
            guard item.isNew, admit(id, key: "startup|" + item.plistPath, dangerous: item.severity == .dangerous, now: now)
            else { continue }
            alerts.startupItems.append(item)
        }
        seenIDs.formIntersection(present)
        return alerts
    }

    /// The program, what matched and how bad it is: the same program flagged
    /// for the same reason is one thing, however many times it starts.
    static func key(for finding: SentinelFinding) -> String {
        let rule = finding.signals.first { $0.severity == finding.severity }?.kind.rawValue ?? ""
        return "\(finding.executablePath)|\(rule)|\(finding.severity.rawValue)"
    }

    private mutating func admit(_ id: String, key: String, dangerous: Bool, now: Date) -> Bool {
        guard seenIDs.insert(id).inserted else { return false }
        let key = AlertMemory.hash(key)
        let last = dangerous ? lastDangerAlerted[key] : lastAlerted[key]
        if let last, now.timeIntervalSince(last) < Self.cooldown { return false }
        if dangerous { lastDangerAlerted[key] = now } else { lastAlerted[key] = now }
        return true
    }
}
