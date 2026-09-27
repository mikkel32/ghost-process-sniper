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
