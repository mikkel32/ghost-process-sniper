import Foundation

public enum RadarFormat {
    public static func bytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
        return "\(max(1, Int(Double(bytes) / 1_048_576))) MB"
    }

    public static func signedBytes(_ bytes: Int64) -> String {
        let sign = bytes >= 0 ? "+" : "-"
        return "\(sign)\(Self.bytes(UInt64(abs(bytes))))"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "75.5°C", written with the reader's decimal separator ("75,5°C"), the
    /// same everywhere a temperature appears.
    public static func celsius(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "°C"
    }

    public static func signedPercent(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(Int(value.rounded()))%"
    }

    /// "2 s", "1.5 s", "12 s".
    public static func seconds(_ value: TimeInterval) -> String {
        let clamped = max(0, value)
        if clamped >= 10 || clamped == clamped.rounded() { return "\(Int(clamped.rounded())) s" }
        return String(format: "%.1f s", clamped)
    }

    /// A count on a badge: nothing for zero, and "99+" past two digits so the
    /// badge stays narrow.
    public static func badge(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    public static func leak(_ value: Double) -> String {
        "\(Int(value.rounded())) MB/min"
    }
}

