import Foundation

/// Integer-math replacements for `String(format: "%.0f")` and `"%.1f"`, which
/// dominated per-tick scoring cost. They round exactly as printf does: to the
/// nearest representable result, with exact ties going to the even digit.
extension RadarFormat {
    /// `String(format: "%.0f", value)`.
    public static func fixed0(_ value: Double) -> String {
        fixed(value, decimals: 0)
    }

    /// `String(format: "%.1f", value)`.
    public static func fixed1(_ value: Double) -> String {
        fixed(value, decimals: 1)
    }

    private static func fixed(_ value: Double, decimals: Int) -> String {
        let scale: Double = decimals == 0 ? 1 : 10
        guard value.isFinite, value.magnitude < 1e15 else {
            return String(format: decimals == 0 ? "%.0f" : "%.1f", value)
        }
        let magnitude = value.magnitude
        let scaled = magnitude * scale
        // The product is rounded; a fused multiply-add recovers its exact
        // error, so a product that lands on .5 can be told apart from a
        // value just below or above it.
        let error = (-scaled).addingProduct(magnitude, scale)
        var rounded = scaled.rounded(.toNearestOrEven)
        if scaled - scaled.rounded(.down) == 0.5, error != 0 {
            rounded = error > 0 ? scaled.rounded(.up) : scaled.rounded(.down)
        }
        let units = Int(rounded)
        let sign = value.sign == .minus ? "-" : ""
        if decimals == 0 {
            return "\(sign)\(units)"
        }
        return "\(sign)\(units / 10).\(units % 10)"
    }
}
