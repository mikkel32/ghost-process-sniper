import Foundation

/// Presentation-only policy. Disabling motion never disables monitoring.
public enum RadarMotionPolicy {
    public static func runsContinuousMotion(
        reduceMotion: Bool, lowPower: Bool, inViewport: Bool,
        windowVisible: Bool, applicationActive: Bool
    ) -> Bool {
        !reduceMotion && !lowPower && inViewport && windowVisible && applicationActive
    }
}

public enum RadarScopeGeometry {
    public static func angle(for key: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Double(hash % 3600) / 3600 * 2 * .pi
    }

    public static func position(key: String, urgency: Double, width: Double, height: Double) -> CGPoint {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let radius = max(0, min(width, height) / 2 - 16)
        let fraction = urgency.isFinite ? min(1, max(0, urgency / 100)) : 0
        let distance = radius * (0.16 + (1 - fraction) * 0.74)
        let bearing = angle(for: key)
        return CGPoint(x: width / 2 + cos(bearing) * distance, y: height / 2 + sin(bearing) * distance)
    }
}
