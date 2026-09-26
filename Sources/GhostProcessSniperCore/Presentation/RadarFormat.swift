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

    public static func signedPercent(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(Int(value.rounded()))%"
    }

    public static func leak(_ value: Double) -> String {
        "\(Int(value.rounded())) MB/min"
    }
}

