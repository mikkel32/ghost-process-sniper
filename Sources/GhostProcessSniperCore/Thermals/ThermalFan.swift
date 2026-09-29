import Foundation

/// One fan's speed as AppleSMC reports it. Display-only context for a
/// temperature: fans never feed the review band, the headline or the Overview's
/// promotion of the thermal panel, which stay driven by macOS pressure and heat.
public struct ThermalFan: Equatable, Sendable {
    /// Below this a fan is stopped or ticking over, which is what macOS does at light load.
    public static let idleBelowRPM = 100.0

    public let rpm: Double
    /// Nil when this Mac does not report a usable maximum.
    public let maximumRPM: Double?

    public init(rpm: Double, maximumRPM: Double?) {
        self.rpm = rpm
        self.maximumRPM = maximumRPM
    }

    /// Share of the fan's maximum, kept within 0...1 because a fan may overshoot
    /// its listed maximum a little.
    public var fraction: Double? {
        guard let maximumRPM, maximumRPM > 0 else { return nil }
        return min(1, max(0, rpm / maximumRPM))
    }

    /// One line for all fans: "Fans idle" when every fan is, otherwise the
    /// fastest fan ("up to" when there are several). Nil without fans, so a
    /// fanless Mac shows nothing. The number follows the reader's locale.
    public static func summary(_ fans: [ThermalFan], locale: Locale = .autoupdatingCurrent) -> String? {
        guard let fastest = fans.max(by: { $0.rpm < $1.rpm }) else { return nil }
        guard fastest.rpm >= idleBelowRPM else { return "Fans idle" }
        let speed = fastest.rpm.formatted(.number.precision(.fractionLength(0)).locale(locale))
        var text = (fans.count > 1 ? "Fans up to " : "Fans ") + speed + " rpm"
        if let fraction = fastest.fraction { text += " (\(RadarFormat.percent(fraction * 100)) of max)" }
        return text
    }
}
