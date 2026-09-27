import Foundation

/// Presentation-only policy. Disabling motion never disables monitoring.
public enum RadarMotionPolicy {
    /// Motion runs only while someone can see it, and never with Reduce Motion.
    public static func runsContinuousMotion(
        reduceMotion: Bool, inViewport: Bool, windowVisible: Bool, applicationActive: Bool
    ) -> Bool {
        !reduceMotion && inViewport && windowVisible && applicationActive
    }

    /// nil: the display's own rate. In Low Power Mode a stepped 10 frames a
    /// second, a small share of the compositing: some Macs are always in
    /// Low Power Mode, and a sweep that never runs there is never seen.
    public static func sweepFramesPerSecond(lowPower: Bool) -> Float? {
        lowPower ? 10 : nil
    }
}
