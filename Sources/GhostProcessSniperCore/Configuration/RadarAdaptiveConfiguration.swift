import Foundation

public enum RadarDetectionMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case custom

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .automatic:
            "Learns each family and adapts the safety rails to this Mac and current pressure."
        case .custom:
            "Uses the exact memory, CPU, and leak limits you choose."
        }
    }

    public var systemImage: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .custom: "slider.horizontal.3"
        }
    }
}

public enum RadarSensitivity: String, Codable, CaseIterable, Sendable {
    case relaxed
    case balanced
    case proactive

    public var label: String {
        switch self {
        case .relaxed: "Relaxed"
        case .balanced: "Balanced"
        case .proactive: "Proactive"
        }
    }

    public var detail: String {
        switch self {
        case .relaxed:
            "Fewer interruptions. Best when large builds, models, and local services are normal."
        case .balanced:
            "Recommended. Catches meaningful drift without reacting to ordinary development bursts."
        case .proactive:
            "Earlier warnings for leaks, runaway CPU, and forgotten background tools."
        }
    }

    public var systemImage: String {
        switch self {
        case .relaxed: "leaf"
        case .balanced: "scale.3d"
        case .proactive: "bolt.badge.clock"
        }
    }
}

public struct ResolvedThresholdProfile: Equatable, Sendable {
    public let effectiveSettings: ThresholdSettings
    public let title: String
    public let summary: String
    public let detail: String
    public let memoryThresholdText: String
    public let cpuThresholdText: String
    public let leakThresholdText: String
    public let isAdaptive: Bool

    public init(
        effectiveSettings: ThresholdSettings,
        title: String,
        summary: String,
        detail: String,
        memoryThresholdText: String,
        cpuThresholdText: String,
        leakThresholdText: String,
        isAdaptive: Bool
    ) {
        self.effectiveSettings = effectiveSettings
        self.title = title
        self.summary = summary
        self.detail = detail
        self.memoryThresholdText = memoryThresholdText
        self.cpuThresholdText = cpuThresholdText
        self.leakThresholdText = leakThresholdText
        self.isAdaptive = isAdaptive
    }
}

public extension ThresholdSettings {
    func resolvedProfile(
        systemPressure: SystemMemoryPressure = .unknown,
        physicalMemoryBytes: UInt64? = nil
    ) -> ResolvedThresholdProfile {
        guard detectionMode == .automatic else {
            return ResolvedThresholdProfile(
                effectiveSettings: self,
                title: "Custom protection",
                summary: "Exact limits are active",
                detail: "The engine still learns normal behavior per family, but your limits remain fixed.",
                memoryThresholdText: RadarFormat.bytes(memoryBytes),
                cpuThresholdText: "\(Int(cpuPercent.rounded()))%",
                leakThresholdText: "\(Int(leakVelocityMegabytesPerMinute.rounded())) MB/min",
                isAdaptive: false
            )
        }

        let hostMemory = max(
            4 * Self.gibibyte,
            systemPressure.totalBytes > 0
                ? systemPressure.totalBytes
                : (physicalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory)
        )
        let parameters = sensitivity.parameters
        var memoryThreshold = Self.clamp(
            Double(hostMemory) * parameters.memoryFraction,
            lower: parameters.minimumMemoryBytes,
            upper: parameters.maximumMemoryBytes
        )
        var cpuThreshold = parameters.cpuThreshold
        var leakThreshold = parameters.leakThreshold

        let pressureScale: Double = switch systemPressure.level {
        case .nominal: 1
        case .elevated: 0.90
        case .warning: 0.75
        case .critical: 0.60
        }
        memoryThreshold *= pressureScale
        leakThreshold *= max(0.62, pressureScale)
        if systemPressure.level >= .warning {
            cpuThreshold *= 0.92
        }

        if systemPressure.isKnown, systemPressure.level >= .warning {
            let availabilityAwareCeiling = max(
                512 * Self.mebibyte,
                Double(systemPressure.availableBytes) * 0.75
            )
            memoryThreshold = min(memoryThreshold, availabilityAwareCeiling)
        }

        let quantizedMemory = UInt64(
            max(
                512 * Self.mebibyte,
                (memoryThreshold / (64 * Self.mebibyte)).rounded() * (64 * Self.mebibyte)
            )
        )
        cpuThreshold = max(45, (cpuThreshold / 5).rounded() * 5)
        leakThreshold = max(40, (leakThreshold / 10).rounded() * 10)

        var effective = self
        effective.memoryBytes = quantizedMemory
        effective.cpuPercent = cpuThreshold
        effective.leakVelocityMegabytesPerMinute = leakThreshold

        let hostMemoryText = RadarFormat.bytes(hostMemory)
        let pressureDetail: String
        if systemPressure.isKnown, systemPressure.level > .nominal {
            pressureDetail = " Limits are temporarily tightened because memory pressure is \(systemPressure.level.label.lowercased())."
        } else {
            pressureDetail = " Limits will tighten automatically if host memory pressure rises."
        }

        return ResolvedThresholdProfile(
            effectiveSettings: effective,
            title: "Smart protection",
            summary: "\(sensitivity.label) tuning for a \(hostMemoryText) Mac",
            detail: "Per-family baselines handle normal variation; these adaptive limits catch unusually large or fast behavior.\(pressureDetail)",
            memoryThresholdText: RadarFormat.bytes(quantizedMemory),
            cpuThresholdText: "\(Int(cpuThreshold.rounded()))%",
            leakThresholdText: "\(Int(leakThreshold.rounded())) MB/min",
            isAdaptive: true
        )
    }

    /// Realtime budgets only while someone is looking; power and heat pick
    /// the lighter budgets otherwise. An explicit mode always wins.
    func resolvedPerformanceMode(_ context: RadarSchedulingContext) -> RadarPerformanceMode {
        guard adaptivePerformance else {
            return performanceMode
        }
        if context.uiVisible {
            return .realtime
        }
        if context.power.lowPowerMode || context.power.onBattery {
            return .batterySaver
        }
        if context.thermalPressure >= .serious, context.summaryLevel < .hot {
            return .batterySaver
        }
        return .balanced
    }

    private static let mebibyte = 1_048_576.0
    private static let gibibyte = 1_073_741_824 as UInt64

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}

private extension RadarSensitivity {
    struct Parameters {
        let memoryFraction: Double
        let minimumMemoryBytes: Double
        let maximumMemoryBytes: Double
        let cpuThreshold: Double
        let leakThreshold: Double
    }

    var parameters: Parameters {
        let gibibyte = 1_073_741_824.0
        return switch self {
        case .relaxed:
            Parameters(
                memoryFraction: 0.12,
                minimumMemoryBytes: 1.5 * gibibyte,
                maximumMemoryBytes: 6 * gibibyte,
                cpuThreshold: 125,
                leakThreshold: 220
            )
        case .balanced:
            Parameters(
                memoryFraction: 0.08,
                minimumMemoryBytes: 1 * gibibyte,
                maximumMemoryBytes: 4 * gibibyte,
                cpuThreshold: 90,
                leakThreshold: 130
            )
        case .proactive:
            Parameters(
                memoryFraction: 0.055,
                minimumMemoryBytes: 0.625 * gibibyte,
                maximumMemoryBytes: 2.5 * gibibyte,
                cpuThreshold: 65,
                leakThreshold: 80
            )
        }
    }
}

public extension RadarMode {
    var userLabel: String {
        switch self {
        case .dev: "Developer tools"
        case .heavy: "Heavy apps"
        case .all: "All user apps"
        }
    }

    var detail: String {
        switch self {
        case .dev: "Focuses on servers, runtimes, build tools, and local AI workloads."
        case .heavy: "Also includes any app using a meaningful share of CPU, GPU, or memory."
        case .all: "Shows almost every non-system process. Best for deep troubleshooting."
        }
    }

    var systemImage: String {
        switch self {
        case .dev: "hammer"
        case .heavy: "gauge.with.dots.needle.67percent"
        case .all: "square.stack.3d.up"
        }
    }
}

public extension RadarPerformanceMode {
    var detail: String {
        switch self {
        case .batterySaver: "Uses fewer rich probes and a calmer background cadence."
        case .balanced: "Keeps the radar responsive without wasting CPU."
        case .realtime: "Prioritizes the fastest feedback while you investigate an issue."
        }
    }

    var systemImage: String {
        switch self {
        case .batterySaver: "leaf"
        case .balanced: "scale.3d"
        case .realtime: "bolt"
        }
    }
}
