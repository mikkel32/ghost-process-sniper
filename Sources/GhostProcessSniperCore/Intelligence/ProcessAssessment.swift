import Foundation

extension ProcessFamily {
    /// The oldest component determines the freshness of a sum. Missing members
    /// cannot be silently counted as zero or treated as new trend evidence.
    public var measurementDate: Date? {
        let dates = members.compactMap(\.measurementDate)
        guard !members.isEmpty, dates.count == members.count else { return nil }
        return dates.min()
    }

    public func hasRecentMeasurements(at date: Date, maximumAge: TimeInterval = 15) -> Bool {
        guard let measuredAt = measurementDate else { return false }
        return (0...maximumAge).contains(date.timeIntervalSince(measuredAt))
    }
}

extension GhostLevel {
    public var actionLabel: String {
        switch self {
        case .quiet: "Stable"
        case .watch: "Observe"
        case .hot: "Review"
        case .critical: "Urgent"
        }
    }
}

/// Describes observed resource use, never an invented per-process temperature.
public struct ProcessAssessment: Equatable, Sendable {
    public let cause: String
    public let evidence: String
    public let recommendation: String
    public let measurementText: String
    public let status: String
    public let systemImage: String

    public init(family: ProcessFamily) {
        let complete = family.hasRecentMeasurements(at: family.lastScoredAt ?? family.root.sampledAt)
        let memory = RadarFormat.bytes(family.totalPhysicalFootprintBytes)
        let cpu = RadarFormat.percent(family.totalCPUPercent)
        let gpu = RadarFormat.percent(family.totalGPUPercent)
        let duration = Int(family.trend.observedSeconds.rounded())
        measurementText = complete ? (duration >= 15 ? "Observed for \(duration)s" : "Building history") : "Partial or stale measurements"
        status = complete ? family.score.level.actionLabel : "Measuring"
        if !complete {
            cause = "Waiting for a complete reading"
            evidence = "Some process metrics are missing or older than 15 seconds. They are excluded from growth detection."
            recommendation = "Let the next scan confirm the resource use before deciding."
            systemImage = "clock"
        } else if family.hasCredibleLeak, family.trend.hasSustainedHistory {
            cause = "Sustained memory growth"
            evidence = "\(memory) in use; growing \(RadarFormat.leak(family.trend.memoryVelocityMegabytesPerMinute))."
            recommendation = "Inspect the growing member and its work before previewing a stop."
            systemImage = "chart.line.uptrend.xyaxis"
        } else if family.totalCPUPercent >= 80 {
            cause = "CPU activity"
            evidence = "\(cpu) CPU across \(family.members.count) processes. 100% means one logical CPU."
            recommendation = "Check whether a build, task, or foreground app is doing expected work."
            systemImage = "cpu"
        } else if family.totalGPUPercent >= 40 {
            cause = "GPU activity"
            evidence = "\(gpu) reported GPU activity; \(memory) tracked memory."
            recommendation = "Inspect rendering or compute work. Hardware temperature is shown separately."
            systemImage = "square.stack.3d.up"
        } else if family.totalPhysicalFootprintBytes >= 512 * 1_048_576 {
            cause = "Memory footprint"
            evidence = "\(memory) tracked footprint, \(cpu) CPU. Size alone does not prove a leak."
            recommendation = "Review the largest member; stop only work you no longer need."
            systemImage = "memorychip"
        } else if family.score.level >= .watch {
            cause = "Activity to review"
            evidence = family.score.heat.evidence.first ?? "\(memory) memory and \(cpu) CPU in the current scan."
            recommendation = "Review current measurements and the process tree."
            systemImage = "waveform.path"
        } else {
            cause = "Within observed limits"
            evidence = "\(memory) memory and \(cpu) CPU. No confirmed resource problem."
            recommendation = "Keep running. No stop is suggested from these readings."
            systemImage = "checkmark.circle"
        }
    }
}
