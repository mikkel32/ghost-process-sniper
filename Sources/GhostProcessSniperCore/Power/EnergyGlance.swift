import Foundation

/// What the menu bar, popover and Overview say about energy, bucketed so it
/// only changes when something a person would notice changes.
public struct EnergyGlance: Equatable, Sendable {
    public let findings: [EnergyFinding]
    public let unexpectedBlockerCount: Int
    public let isDischarging: Bool
    public let isCharging: Bool
    public let chargePercent: Int?
    /// Rounded to five minutes.
    public let minutesRemaining: Int?
    public let drawWatts: Int?
    public let topConsumerName: String?
    /// Rounded to half a watt.
    public let topConsumerWatts: Double?

    public static let empty = EnergyGlance(.empty)

    public init(_ report: EnergyReport) {
        findings = Array(report.findings.prefix(3))
        unexpectedBlockerCount = report.unexpectedBlockers.count
        let battery = report.battery
        isDischarging = battery?.isDischarging ?? false
        isCharging = battery?.isCharging ?? false
        chargePercent = battery?.chargePercent.map { Int($0.rounded()) }
        minutesRemaining = battery?.minutesRemaining.map { Int(($0 / 5).rounded()) * 5 }
        drawWatts = battery?.drawWatts.map { Int($0.rounded()) }
        let top = report.perProcessEnergy
            ? report.consumers.first { $0.isRunning && !$0.isSystem && $0.averageWatts >= 0.5 } : nil
        topConsumerName = top?.displayName
        topConsumerWatts = top.map { ($0.averageWatts * 2).rounded() / 2 }
    }

    public var topFinding: EnergyFinding? { findings.first }

    /// "On battery · 3 h 40 min left · 12 W", or nil on a desktop.
    public var batteryLine: String? {
        var parts: [String] = []
        if isDischarging {
            parts.append(chargePercent.map { "On battery \($0)%" } ?? "On battery")
            if let minutesRemaining, minutesRemaining > 0 {
                parts.append("\(EnergyFormat.duration(Double(minutesRemaining) * 60)) left")
            }
        } else if let chargePercent {
            parts.append(isCharging ? "Charging \(chargePercent)%" : "Plugged in \(chargePercent)%")
        }
        if let drawWatts, drawWatts > 0 { parts.append("drawing \(drawWatts) W") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
