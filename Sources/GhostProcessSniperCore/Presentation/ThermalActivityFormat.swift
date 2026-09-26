import Foundation

public enum ThermalActivityFormat {
    public static func percent(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        if value > 0 && value < 0.1 { return "<0.1%" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}
