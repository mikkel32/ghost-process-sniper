import Foundation

/// The words at the top of the Energy page: what the battery is doing, what
/// the Mac draws, and the charger. Decided here, not in the view, so the
/// header cannot say two things that contradict each other unnoticed.
public struct EnergyHeadline: Equatable, Sendable {
    public let title: String
    /// "Your Mac is drawing 26 W", and that the battery covers the rest when the charger is too small.
    public let drawSentence: String?
    /// "apps and jobs account for 3.4 W of it (17%)", or nil when the comparison would not be valid.
    public let attributionSentence: String?
    /// "Charger 65 W": the adapter's rating, which does not move with load.
    public let chargerTag: String?

    public init(_ report: EnergyReport) {
        let battery = report.battery
        title = Self.title(battery)
        drawSentence = Self.drawSentence(battery, draw: report.macWatts)
        attributionSentence = EnergyAttribution(mac: report.macWatts, measured: report.measuredWatts,
                                                perProcessEnergy: report.perProcessEnergy)?.sentence
        chargerTag = battery?.adapterRatedWatts.map { "Charger \(EnergyFormat.watts($0))" }
    }

    private static func title(_ battery: BatteryOutlook?) -> String {
        guard let battery else { return "Energy use" }
        if battery.isDischarging {
            if let minutes = battery.minutesRemaining {
                return "About \(EnergyFormat.duration(minutes * 60)) of battery left"
            }
            return battery.chargePercent.map { "On battery · \(Int($0.rounded()))%" } ?? "On battery"
        }
        guard let charge = battery.chargePercent else {
            return battery.drawWatts.map { "Drawing \(EnergyFormat.watts($0))" } ?? "Energy use"
        }
        let percent = Int(charge.rounded())
        return switch battery.powerState {
        case .charging: "Charging · \(percent)%"
        case .drainingOnPower: "Draining while plugged in · \(percent)%"
        default: "Plugged in, not charging · \(percent)%"
        }
    }

    private static func drawSentence(_ battery: BatteryOutlook?, draw: Double?) -> String? {
        let drawing = draw.map { "Your Mac is drawing \(EnergyFormat.watts($0))" }
        guard battery?.powerState == .drainingOnPower else { return drawing }
        // No watts for the split: the draw is an average and the flow is one reading.
        let short = "the charger can\u{2019}t keep up, so the battery covers the rest"
        return drawing.map { "\($0); \(short)" } ?? "The charger can\u{2019}t keep up, so the battery covers the rest"
    }
}
