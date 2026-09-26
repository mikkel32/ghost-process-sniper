import Foundation

/// Projects the raw process sample onto apps; has no intervention APIs.
public enum ThermalActivityAnalyzer {
    /// The refresh worker calls this with the raw sample, before UI filters can hide an app.
    /// Family membership only provides optional navigation; it never gates attribution.
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
        let samples = processes.map { process in
            let key = ownership[process.identity]
            let identity = process.identity
            return ThermalActivitySample(identity: identity,
                familyKey: key ?? "process:\(identity.pid):\(identity.startTimeSeconds).\(identity.startTimeMicroseconds)",
                name: process.name, executablePath: process.executablePath,
                cpuPercent: process.cpuPercent, gpuPercent: process.gpuUsagePercent,
                measuredAt: process.cpuMeasurementDate, gpuMeasuredAt: process.gpuMeasurementDate,
                canInspectFamily: key != nil,
                isSystemProcess: process.isSystemProcess)
        }
        return ThermalActivitySummary.build(samples: samples, now: now, processorCount: processorCount)
    }
}
