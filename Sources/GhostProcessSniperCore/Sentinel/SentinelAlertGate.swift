import Foundation

/// Decides which findings and startup items earn a notification.
///
/// A finding is one process instance, so a program that restarts or runs
/// many workers would otherwise alert once per process. Alerts are keyed by
/// what was found (the program, its strongest evidence and severity) and
/// held back for a day; a finding that turns dangerous alerts again. Memory
/// stays bounded: IDs are pruned to the current report, keys to the cooldown.
public struct SentinelAlertGate: Sendable {
    public static let cooldown: TimeInterval = 24 * 60 * 60

    public struct Alerts: Sendable {
        public var findings: [SentinelFinding] = []
        public var startupItems: [LaunchItem] = []
    }

    private var seenIDs: Set<String> = []
    private var lastAlerted: [String: Date] = [:]

    public init() {}

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
        var alerts = Alerts()
        var present = Set<String>()
        for finding in report.findings {
            // Per severity, so a finding that turns dangerous is news again.
            let id = "finding:\(finding.id)|\(finding.severity.rawValue)"
            present.insert(id)
            guard finding.isRunning || finding.severity == .dangerous, finding.severity >= .suspicious,
                  admit(id, key: Self.key(for: finding), now: now)
            else { continue }
            alerts.findings.append(finding)
        }
        for item in report.launchItems {
            let id = "startup:" + item.id
            present.insert(id)
            guard item.isNew, admit(id, key: "startup|" + item.plistPath, now: now) else { continue }
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

    private mutating func admit(_ id: String, key: String, now: Date) -> Bool {
        guard seenIDs.insert(id).inserted else { return false }
        if let last = lastAlerted[key], now.timeIntervalSince(last) < Self.cooldown { return false }
        lastAlerted[key] = now
        return true
    }
}
