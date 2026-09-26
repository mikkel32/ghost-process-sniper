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
    /// Decayed accumulated activity (CPU capacity or reported GPU, whichever is higher)
    /// as of `sustainedLoadAt`. Recent readings weigh more, like chip temperature does.
    public let sustainedLoadPercent: Double
    public let sustainedLoadAt: Date

    public var activeSpanSeconds: TimeInterval {
        max(0, lastActiveAt.timeIntervalSince(firstActiveAt))
    }

    /// The load keeps decaying between readings; it never grows without a new one.
    public func sustainedLoad(at now: Date) -> Double {
        guard (0...ThermalActivityHistory.maximumAge).contains(now.timeIntervalSince(lastActiveAt)) else { return 0 }
        return sustainedLoadPercent * exp(-max(0, now.timeIntervalSince(sustainedLoadAt)) / ThermalActivityHistory.loadTimeConstant)
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

    /// Every later instant at which one of this group's readings stops counting as current.
    func expiryDates(after now: Date) -> [Date] {
        var dates = [cpuMeasuredAt, gpuMeasuredAt, measuredAt]
        for process in processes { dates += [process.cpuMeasuredAt, process.gpuMeasuredAt] }
        return Set(dates.compactMap { $0?.addingTimeInterval(ThermalActivitySummary.maximumAge) }.filter { $0 > now })
            .sorted()
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
        if let knownSource { return knownSource.advice }
        if isSystemProcess {
            return "This is a macOS service. Review related app activity first; this panel does not recommend stopping system services."
        }
        if kind == .job {
            let origin = hostAppName.map { " in \($0)" } ?? ""
            return "This is a command-line job\(origin) with \(processCount) sampled \(processCount == 1 ? "process" : "processes"). Check whether it is work you expect; let it finish, or stop it where it was started if it can wait, then compare the next readings."
        }
        if let gpu = gpuActivityPercent(at: now), gpu > (cpuCapacityPercent(at: now) ?? 0), gpu >= 5 {
            return "Check for rendering, video, games, or other graphics work in this app. Pause an optional task and compare the next readings."
        }
        return "Check whether this app is doing work you expect. Pause an optional task or close an unused window, then compare the next readings."
    }

    /// A short line describing what the row groups.
    var workloadSummary: String {
        if let knownSource {
            let parts = knownSource.label.components(separatedBy: " — ")
            return parts.count > 1 ? parts[1] : "macOS background work"
        }
        if isSystemProcess { return "macOS service" }
        let count = "\(processCount) \(processCount == 1 ? "process" : "processes")"
        guard kind == .job else { return count }
        return hostAppName.map { "Command-line job in \($0) · \(count)" } ?? "Command-line job · \(count)"
    }

    /// Why these processes were grouped together.
    var workloadExplanation: String {
        if let knownSource { return knownSource.cause }
        let count = "\(processCount) sampled \(processCount == 1 ? "process" : "processes")"
        guard kind == .job else { return "\(count) \(processCount == 1 ? "belongs" : "belong") to this app or service." }
        let origin = hostAppName.map { " started in \($0)" } ?? ""
        return "\(count) \(processCount == 1 ? "belongs" : "belong") to this command-line job\(origin), grouped under the process that started it."
    }
}
