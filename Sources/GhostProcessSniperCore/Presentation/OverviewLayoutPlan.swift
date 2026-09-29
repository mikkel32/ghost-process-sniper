import Foundation

public enum OverviewSectionID: Hashable, Sendable {
    case verdict, queues, metrics, thermals, analytics
}

public enum OverviewThermalBand: Sendable {
    case normal, elevated
}

/// Decides when the thermal panel earns the second slot on the Overview.
/// Apple silicon routinely runs at 80-95 °C under ordinary load, so a single
/// hot reading is not enough: the OS must report serious throttling, or a
/// very hot (90 °C+) reading must hold for 30 s. It drops back only after a
/// minute of calm, so the layout does not jump on every reading.
public struct OverviewThermalBandTracker: Sendable {
    public static let sustainedVeryHotSeconds: TimeInterval = 30
    public static let calmSeconds: TimeInterval = 60
    /// Longer than any refresh interval: the console was hidden, so earlier
    /// readings say nothing about what happened in between.
    static let maximumGap: TimeInterval = 15

    public private(set) var band: OverviewThermalBand = .normal
    private var veryHotSince: Date?
    private var calmSince: Date?
    private var lastUpdate: Date?

    public init() {}

    public mutating func update(
        thermalState: ThermalDiagnosis.State,
        temperature: ThermalTemperatureAssessment,
        at now: Date
    ) -> OverviewThermalBand {
        if let lastUpdate, now.timeIntervalSince(lastUpdate) > Self.maximumGap {
            veryHotSince = nil
            calmSince = nil
        }
        lastUpdate = now

        let isVeryHot = temperature.band == .veryHot
        veryHotSince = isVeryHot ? (veryHotSince ?? now) : nil
        let veryHotSeconds = max(
            veryHotSince.map { now.timeIntervalSince($0) } ?? 0,
            isVeryHot ? temperature.trajectory.veryHotSeconds : 0
        )
        let throttling = thermalState == .serious || thermalState == .critical
        if throttling || veryHotSeconds >= Self.sustainedVeryHotSeconds {
            band = .elevated
            calmSince = nil
            return band
        }
        guard band == .elevated else { return band }

        // Throttling returned above, so only the temperature can still hold it up.
        guard temperature.band.rawValue <= ThermalTemperatureBand.hot.rawValue else {
            calmSince = nil
            return band
        }
        let since = calmSince ?? now
        calmSince = since
        if now.timeIntervalSince(since) >= Self.calmSeconds {
            band = .normal
            calmSince = nil
        }
        return band
    }
}

public enum OverviewQueueLayout: Sendable {
    /// The Risk Queue and Warming Up side by side.
    case pair
    /// Both are empty: one slim strip says so instead of two empty cards.
    case allClear
}

/// Decides when the two queues collapse into the all-clear strip. Any row
/// brings the cards back at once, but a family hovering around Hot would
/// move the whole page (the Live Radar sits right under the queues) on
/// every flip, so they only give way after thirty seconds of unbroken calm.
public struct OverviewQueueTracker: Sendable {
    public static let calmSeconds: TimeInterval = 30
    /// Longer than any refresh interval: the console was hidden, so earlier
    /// updates say nothing about how long the queues have been empty.
    static let maximumGap: TimeInterval = 15

    /// Starts as the strip, so a calm console never shows two empty cards
    /// while it waits for the first scan.
    public private(set) var layout: OverviewQueueLayout = .allClear
    private var calmSince: Date?
    private var lastUpdate: Date?

    public init() {}

    public mutating func update(riskCount: Int, warmingCount: Int, hasSampled: Bool, at now: Date) -> OverviewQueueLayout {
        if let lastUpdate, now.timeIntervalSince(lastUpdate) > Self.maximumGap { calmSince = nil }
        lastUpdate = now

        // Before the first scan the queues are unknown, not empty.
        guard hasSampled else {
            calmSince = nil
            layout = .allClear
            return layout
        }
        guard riskCount == 0, warmingCount == 0 else {
            calmSince = nil
            layout = .pair
            return layout
        }
        guard layout == .pair else { return layout }
        let since = calmSince ?? now
        calmSince = since
        if now.timeIntervalSince(since) >= Self.calmSeconds {
            layout = .allClear
            calmSince = nil
        }
        return layout
    }
}

public enum OverviewLayoutPlan {
    /// The verdict and the queues stay above the fold, the Live Radar right
    /// after them; thermals move up to second only while the Mac is
    /// genuinely hot.
    public static func sections(thermal: OverviewThermalBand) -> [OverviewSectionID] {
        switch thermal {
        case .normal: [.verdict, .queues, .analytics, .metrics, .thermals]
        case .elevated: [.verdict, .thermals, .queues, .analytics, .metrics]
        }
    }
}
