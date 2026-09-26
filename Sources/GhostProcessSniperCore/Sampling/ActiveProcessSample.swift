import Foundation

/// Intermediate probe record assembled before telemetry and GPU readings arrive.
struct ActiveProcessSample {
    let identity: ProcessIdentity
    let measurementStatus: ProcessMeasurementStatus
    let cpuMeasurementStatus: ProcessMeasurementStatus
    let parentPID: Int32
    let userID: UInt32
    let residentMemoryBytes: UInt64
    let physicalFootprintBytes: UInt64
    let virtualMemoryBytes: UInt64
    let threadCount: Int
    let isSystemProcess: Bool
    let probeFingerprint: UInt64
    let totalProcessorSeconds: TimeInterval
    let cpu: Double
    let isPriority: Bool
    var telemetry: ProcessTelemetryCache.Entry?
    var forensics: ProcessForensics?
}
