import Foundation

public struct ThresholdSettings: Codable, Equatable, Sendable {
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var leakVelocityMegabytesPerMinute: Double
    public var sustainedSeconds: TimeInterval
    public var refreshInterval: TimeInterval
    public var forceKillDelay: TimeInterval
    public var radarMode: RadarMode
    public var groupFamilies: Bool
    public var performanceMode: RadarPerformanceMode
    public var detectionMode: RadarDetectionMode
    public var sensitivity: RadarSensitivity
    public var adaptivePerformance: Bool

    /// Compatibility profile used by tests, imported settings, and callers
    /// that intentionally set exact thresholds.
    public static let aggressive = ThresholdSettings(
        memoryBytes: 1_073_741_824,
        cpuPercent: 80,
        leakVelocityMegabytesPerMinute: 120,
        sustainedSeconds: 5,
        refreshInterval: 1,
        forceKillDelay: 2,
        radarMode: .dev,
        groupFamilies: true,
        performanceMode: .balanced,
        detectionMode: .custom,
        sensitivity: .balanced,
        adaptivePerformance: false
    )

    /// Friendly default for new installs. Raw thresholds remain available as
    /// safety rails, but the engine resolves them from host capacity and
    /// memory pressure before every scan.
    public static let smart = ThresholdSettings(
        memoryBytes: 1_073_741_824,
        cpuPercent: 90,
        leakVelocityMegabytesPerMinute: 130,
        sustainedSeconds: 5,
        refreshInterval: 1,
        forceKillDelay: 2,
        radarMode: .dev,
        groupFamilies: true,
        performanceMode: .balanced,
        detectionMode: .automatic,
        sensitivity: .balanced,
        adaptivePerformance: true
    )

    public init(
        memoryBytes: UInt64,
        cpuPercent: Double,
        leakVelocityMegabytesPerMinute: Double,
        sustainedSeconds: TimeInterval,
        refreshInterval: TimeInterval,
        forceKillDelay: TimeInterval,
        radarMode: RadarMode,
        groupFamilies: Bool,
        performanceMode: RadarPerformanceMode = .balanced,
        detectionMode: RadarDetectionMode = .custom,
        sensitivity: RadarSensitivity = .balanced,
        adaptivePerformance: Bool = false
    ) {
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.leakVelocityMegabytesPerMinute = leakVelocityMegabytesPerMinute
        self.sustainedSeconds = sustainedSeconds
        self.refreshInterval = refreshInterval
        self.forceKillDelay = forceKillDelay
        self.radarMode = radarMode
        self.groupFamilies = groupFamilies
        self.performanceMode = performanceMode
        self.detectionMode = detectionMode
        self.sensitivity = sensitivity
        self.adaptivePerformance = adaptivePerformance
    }

    private enum CodingKeys: String, CodingKey {
        case memoryBytes
        case cpuPercent
        case leakVelocityMegabytesPerMinute
        case sustainedSeconds
        case refreshInterval
        case forceKillDelay
        case radarMode
        case groupFamilies
        case performanceMode
        case detectionMode
        case sensitivity
        case adaptivePerformance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThresholdSettings.aggressive
        memoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? defaults.memoryBytes
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? defaults.cpuPercent
        leakVelocityMegabytesPerMinute = try container.decodeIfPresent(Double.self, forKey: .leakVelocityMegabytesPerMinute) ?? defaults.leakVelocityMegabytesPerMinute
        sustainedSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .sustainedSeconds) ?? defaults.sustainedSeconds
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        forceKillDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .forceKillDelay) ?? defaults.forceKillDelay
        radarMode = try container.decodeIfPresent(RadarMode.self, forKey: .radarMode) ?? defaults.radarMode
        groupFamilies = try container.decodeIfPresent(Bool.self, forKey: .groupFamilies) ?? defaults.groupFamilies
        performanceMode = try container.decodeIfPresent(RadarPerformanceMode.self, forKey: .performanceMode) ?? .balanced
        // Legacy settings were explicitly configured by the user, so retain
        // their exact behavior instead of silently converting them to smart.
        detectionMode = try container.decodeIfPresent(RadarDetectionMode.self, forKey: .detectionMode) ?? .custom
        sensitivity = try container.decodeIfPresent(RadarSensitivity.self, forKey: .sensitivity) ?? .balanced
        adaptivePerformance = try container.decodeIfPresent(Bool.self, forKey: .adaptivePerformance) ?? false
    }

    public var memoryGigabytes: Double {
        get { Double(memoryBytes) / 1_073_741_824 }
        set { memoryBytes = UInt64(max(0.1, newValue) * 1_073_741_824) }
    }
}
