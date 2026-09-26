import Foundation

public enum ThermalActivitySort: String, CaseIterable, Identifiable, Sendable {
    case activity = "Combined"
    case cpu = "CPU"
    case gpu = "GPU"

    public var id: String { rawValue }
}

public enum ThermalActivityCoverage: Equatable, Sendable {
    /// Every sampled process is projected, independent of radar family filters.
    case processInventory
}

/// A bounded inspection snapshot. These identities never authorize an intervention.
public struct ThermalProcessEvidence: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let name: String
    public let cpuPercent: Double
    public let gpuPercent: Double
    public let measuredAt: Date
    public let cpuMeasuredAt: Date?
    public let gpuMeasuredAt: Date?
}

/// Recent observed work can remain relevant while a sensor cools. It is not a heat share.
public struct ThermalRecentContributor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let familyKey: String
    public let peakCPUCapacityPercent: Double
    public let peakGPUPercent: Double
    public let firstActiveAt: Date
    public let lastActiveAt: Date
    public let activeSampleCount: Int
    public let isSystemProcess: Bool

    public var activeSpanSeconds: TimeInterval {
        max(0, lastActiveAt.timeIntervalSince(firstActiveAt))
    }
}

public extension ThermalContributor {
    var isSubstantial: Bool {
        cpuPercent >= 80 || cpuCapacityPercent >= 10 || gpuPercent >= 15
    }

    func cpuCapacityPercent(at now: Date) -> Double? {
        guard let cpuMeasuredAt,
              (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(cpuMeasuredAt)) else { return nil }
        return cpuCapacityPercent
    }

    func gpuActivityPercent(at now: Date) -> Double? {
        guard let gpuMeasuredAt,
              (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(gpuMeasuredAt)) else { return nil }
        return gpuPercent
    }

    func observedActivity(at now: Date) -> Double? {
        let cpu = cpuCapacityPercent(at: now)
        let gpu = gpuActivityPercent(at: now)
        guard cpu != nil || gpu != nil else { return nil }
        return max(cpu ?? 0, gpu ?? 0)
    }

    func isSubstantial(at now: Date) -> Bool {
        let cpu = cpuCapacityPercent(at: now)
        let gpu = gpuActivityPercent(at: now)
        return (cpu != nil && (cpuPercent >= 80 || (cpu ?? 0) >= 10)) || (gpu ?? 0) >= 15
    }

    var suggestedAction: String {
        suggestedAction(at: measuredAt)
    }

    func suggestedAction(at now: Date) -> String {
        if isSystemProcess {
            return "This is a macOS service. Review related app activity first; this panel does not recommend stopping system services."
        }
        if let gpu = gpuActivityPercent(at: now), gpu > (cpuCapacityPercent(at: now) ?? 0), gpu >= 5 {
            return "Check for rendering, video, games, or other graphics work in this app. Pause an optional task and compare the next readings."
        }
        return "Check whether this app is doing work you expect. Pause an optional task or close an unused window, then compare the next readings."
    }
}
