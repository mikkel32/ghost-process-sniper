import Foundation

/// Watts, durations and data amounts for the Energy page, written with the
/// reader's decimal separator like every other decimal in the app.
public enum EnergyFormat {
    /// "0.4 W", "3.2 W", "18 W".
    public static func watts(_ value: Double) -> String {
        let clamped = max(0, value.isFinite ? value : 0)
        if clamped >= 10 { return "\(Int(clamped.rounded())) W" }
        if clamped > 0, clamped < 0.1 { return "<\u{2009}" + 0.1.formatted(.number.precision(.fractionLength(1))) + " W" }
        return clamped.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    /// "4 Wh", "0.3 Wh".
    public static func wattHours(_ value: Double) -> String {
        let clamped = max(0, value.isFinite ? value : 0)
        if clamped >= 10 { return "\(Int(clamped.rounded())) Wh" }
        return clamped.formatted(.number.precision(.fractionLength(1))) + " Wh"
    }

    /// "45 s", "12 min", "2 h 5 min", "26 h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds.isFinite ? seconds : 0)
        if total < 60 { return "\(Int(total.rounded())) s" }
        let minutes = Int((total / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours >= 10 || rest == 0 { return "\(Int((total / 3_600).rounded())) h" }
        return "\(hours) h \(rest) min"
    }

    /// "900 KB", "12 MB", "4.2 GB".
    public static func bytes(_ value: Double) -> String {
        let clamped = max(0, value.isFinite ? value : 0)
        if clamped >= 1_073_741_824 {
            return (clamped / 1_073_741_824).formatted(.number.precision(.fractionLength(1))) + " GB"
        }
        if clamped >= 1_048_576 { return "\(Int((clamped / 1_048_576).rounded())) MB" }
        return "\(max(0, Int((clamped / 1_024).rounded()))) KB"
    }

    /// "240/s".
    public static func rate(_ perSecond: Double) -> String {
        "\(Int(max(0, perSecond.isFinite ? perSecond : 0).rounded()))/s"
    }
}
