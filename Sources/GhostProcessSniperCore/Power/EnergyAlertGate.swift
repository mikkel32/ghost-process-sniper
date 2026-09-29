import Foundation

/// Decides which energy findings earn a notification: only those that need
/// attention, once each, and the same finding again only after a cooldown,
/// so an app that keeps the Mac awake every night alerts once a night, even
/// across a relaunch: `memory` carries the cooldowns, as hashes, to the next run.
public struct EnergyAlertGate: Sendable {
    public static let cooldown: TimeInterval = 12 * 60 * 60

    private var shown: Set<String> = []
    /// Hashed ids (`AlertMemory.hash`), so it can be saved as it is.
    private var lastAlerted: [String: Date] = [:]

    public init() {}

    /// A gate that starts with what an earlier run alerted.
    public init(memory: AlertMemory, now: Date = Date()) {
        lastAlerted = memory.live(cooldown: Self.cooldown, at: now)
    }

    /// What to keep for the next launch.
    public var memory: AlertMemory { AlertMemory(lastAlerted: lastAlerted) }

    public mutating func alerts(for findings: [EnergyFinding], now: Date) -> [EnergyFinding] {
        lastAlerted = lastAlerted.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        var alerts: [EnergyFinding] = []
        var present: Set<String> = []
        for finding in findings where finding.severity == .attention {
            present.insert(finding.id)
            // A finding that stays on screen alerts once, however long it lasts.
            guard shown.insert(finding.id).inserted else { continue }
            let key = AlertMemory.hash(finding.id)
            if let last = lastAlerted[key], now.timeIntervalSince(last) < Self.cooldown { continue }
            lastAlerted[key] = now
            alerts.append(finding)
        }
        shown.formIntersection(present)
        return alerts
    }
}
