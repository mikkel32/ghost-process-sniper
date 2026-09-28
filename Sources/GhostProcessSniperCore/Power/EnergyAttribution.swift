import Foundation

/// How much of the Mac's draw the measured apps and jobs account for.
///
/// Process energy is what macOS attributes to each process's CPU work, so the
/// share is a floor: the display, graphics, storage and radios make up the
/// rest. The two figures must cover the same window (both five-minute means),
/// and when the apps come out above the whole Mac the comparison is not valid
/// and nothing is said.
public struct EnergyAttribution: Equatable, Sendable {
    /// Whole percent, kept between 1 and 99: a measured app is never "nothing" and never "everything".
    public let sharePercent: Int
    /// What the display, graphics and the rest of the Mac draw beside the apps.
    public let restWatts: Double
    /// "apps and jobs account for 3.4 W of it (17%)".
    public let sentence: String

    public init?(mac: Double?, measured: Double, perProcessEnergy: Bool) {
        guard perProcessEnergy, let mac, mac.isFinite, mac > 0, measured.isFinite, measured > 0,
              measured <= mac else { return nil }
        sharePercent = min(99, max(1, Int((measured / mac * 100).rounded())))
        restWatts = mac - measured
        // A literal percent sign: a formatted percentage inside a sentence differs by locale ("17 %").
        sentence = "apps and jobs account for \(EnergyFormat.watts(measured)) of it (\(sharePercent)%)"
    }
}
