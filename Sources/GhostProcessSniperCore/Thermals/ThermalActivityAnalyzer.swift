import Foundation

/// Projects the raw process sample onto apps, jobs and known sources; has no intervention APIs.
public enum ThermalActivityAnalyzer {
    /// The refresh worker calls this with the raw sample, before UI filters can hide an app.
    /// Grouping follows the process tree; family membership only provides the navigation
    /// target and never decides which group a process joins.
    public static func project(
        processes: [ProcessMetrics], families: [ProcessFamily], now: Date,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> ThermalActivitySummary {
        var ownership: [ProcessIdentity: String] = [:]
        for family in families {
            for process in family.members {
                if let existing = ownership[process.identity], existing <= family.familyKey { continue }
                ownership[process.identity] = family.familyKey
            }
            if ownership[family.root.identity] == nil { ownership[family.root.identity] = family.familyKey }
        }
        var resolver = ThermalWorkloadResolver(processes: processes)
        let samples = processes.map { process in
            let key = ownership[process.identity]
            let identity = process.identity
            return ThermalActivitySample(identity: identity,
                familyKey: key ?? "process:\(identity.pid):\(identity.startTimeSeconds).\(identity.startTimeMicroseconds)",
                name: process.name, executablePath: process.executablePath,
                cpuPercent: process.cpuPercent, gpuPercent: process.gpuUsagePercent,
                measuredAt: process.cpuMeasurementDate, gpuMeasuredAt: process.gpuMeasurementDate,
                canInspectFamily: key != nil,
                isSystemProcess: process.isSystemProcess,
                assignment: resolver.assignment(for: process))
        }
        return ThermalActivitySummary.build(samples: samples, now: now, processorCount: processorCount)
    }
}
