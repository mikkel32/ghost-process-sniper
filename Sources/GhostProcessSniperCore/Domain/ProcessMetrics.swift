import Foundation
import Darwin

public enum ProcessMeasurementStatus: Equatable, Sendable {
    case fresh
    case cached(Date)
    case unavailable
}

public struct ProcessMetrics: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { identity }

    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let ownerName: String
    public let name: String
    public let executablePath: String
    public let commandLine: String
    public let residentMemoryBytes: UInt64
    public let physicalFootprintBytes: UInt64
    public let virtualMemoryBytes: UInt64
    public let cpuPercent: Double
    public let gpuUsagePercent: Double
    public let totalProcessorSeconds: TimeInterval
    public let threadCount: Int
    public let isSystemProcess: Bool
    public let sampledAt: Date
    public let measurementStatus: ProcessMeasurementStatus
    public let cpuMeasurementStatus: ProcessMeasurementStatus
    public let gpuMeasurementStatus: ProcessMeasurementStatus
    public let forensics: ProcessForensics
    /// Process group, session, terminal and run state; `.unknown` when the
    /// sampler did not read them.
    public let session: ProcessSessionInfo
    /// Energy, idle wake-ups and disk writes from the usage read.
    public let power: ProcessPowerUsage

    public var measurementDate: Date? {
        date(for: measurementStatus)
    }

    public var cpuMeasurementDate: Date? { date(for: cpuMeasurementStatus) }
    public var gpuMeasurementDate: Date? { date(for: gpuMeasurementStatus) }

    private func date(for status: ProcessMeasurementStatus) -> Date? {
        switch status {
        case .fresh: sampledAt
        case .cached(let date): date
        case .unavailable: nil
        }
    }

    public var pid: Int32 { identity.pid }
    public var processGroupID: Int32? { session.processGroupID }
    public var sessionID: Int32? { session.sessionID }
    public var controllingTerminal: UInt32? { session.controllingTerminal }
    public var terminalForegroundGroupID: Int32? { session.terminalForegroundGroupID }
    public var runState: ProcessRunState { session.runState }
    /// Exited but not yet reaped by its parent: it holds no memory or CPU
    /// and cannot be killed; only the parent can clear it.
    public var isZombie: Bool { session.runState == .zombie }
    public var memoryForScoringBytes: UInt64 { max(physicalFootprintBytes, residentMemoryBytes) }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        ownerName: String,
        name: String,
        executablePath: String,
        commandLine: String,
        residentMemoryBytes: UInt64,
        physicalFootprintBytes: UInt64,
        virtualMemoryBytes: UInt64,
        cpuPercent: Double,
        gpuUsagePercent: Double = 0,
        totalProcessorSeconds: TimeInterval,
        threadCount: Int,
        isSystemProcess: Bool,
        sampledAt: Date,
        forensics: ProcessForensics = .unavailable(reason: "not sampled"),
        measurementStatus: ProcessMeasurementStatus = .fresh,
        cpuMeasurementStatus: ProcessMeasurementStatus? = nil,
        gpuMeasurementStatus: ProcessMeasurementStatus? = nil,
        session: ProcessSessionInfo = .unknown,
        power: ProcessPowerUsage = .unmeasured
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.ownerName = ownerName
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.residentMemoryBytes = residentMemoryBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.virtualMemoryBytes = virtualMemoryBytes
        self.cpuPercent = cpuPercent
        self.gpuUsagePercent = max(0, gpuUsagePercent)
        self.totalProcessorSeconds = totalProcessorSeconds
        self.threadCount = threadCount
        self.isSystemProcess = isSystemProcess
        self.sampledAt = sampledAt
        self.measurementStatus = measurementStatus
        self.cpuMeasurementStatus = cpuMeasurementStatus ?? measurementStatus
        self.gpuMeasurementStatus = gpuMeasurementStatus ?? measurementStatus
        self.forensics = forensics
        self.session = session
        self.power = power
    }
}
