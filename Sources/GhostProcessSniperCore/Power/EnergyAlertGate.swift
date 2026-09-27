import Foundation

/// Decides which energy findings earn a notification: only those that need
/// attention, once each, and the same finding again only after a cooldown,
/// so an app that keeps the Mac awake every night alerts once a night.
public struct EnergyAlertGate: Sendable {
    public static let cooldown: TimeInterval = 12 * 60 * 60

    private var shown: Set<String> = []
    private var lastAlerted: [String: Date] = [:]

    public init() {}

    public mutating func alerts(for findings: [EnergyFinding], now: Date) -> [EnergyFinding] {
        lastAlerted = lastAlerted.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        var alerts: [EnergyFinding] = []
        var present: Set<String> = []
        for finding in findings where finding.severity == .attention {
            present.insert(finding.id)
            // A finding that stays on screen alerts once, however long it lasts.
            guard shown.insert(finding.id).inserted else { continue }
            if let last = lastAlerted[finding.id], now.timeIntervalSince(last) < Self.cooldown { continue }
            lastAlerted[finding.id] = now
            alerts.append(finding)
        }
        shown.formIntersection(present)
        return alerts
    }
}
