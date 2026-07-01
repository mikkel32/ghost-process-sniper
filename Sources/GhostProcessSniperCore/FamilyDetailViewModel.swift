import Foundation

public struct FamilyForensicsSummary: Equatable, Sendable {
    public let currentDirectory: String
    public let rootDirectory: String
    public let openFileText: String
    public let socketText: String
    public let portsText: String
    public let freshnessText: String
    public let isPartial: Bool
    public let notes: [String]

    public init(family: ProcessFamily) {
        currentDirectory = family.forensics.currentDirectory ?? "unavailable"
        rootDirectory = family.forensics.rootDirectory ?? "unavailable"
        openFileText = family.forensics.openFileCount.map { "\($0)" } ?? "locked"
        socketText = family.forensics.socketCount.map { "\($0)" } ?? "locked"
        portsText = family.forensics.listeningPorts.isEmpty ? "none" : family.forensics.listeningPorts.map(String.init).joined(separator: ", ")
        freshnessText = family.forensicsFreshness?.formatted(date: .omitted, time: .standard) ?? "deferred"
        isPartial = family.forensics.isPartial
        notes = family.forensics.notes
    }
}

public struct FamilyBaselineDelta: Equatable, Sendable {
    public let memoryMultiple: Double?
    public let cpuMultiple: Double?
    public let peakMemoryBytes: UInt64?
    public let incidentCount: Int

    public init(family: ProcessFamily) {
        guard let baseline = family.baseline else {
            memoryMultiple = nil
            cpuMultiple = nil
            peakMemoryBytes = nil
            incidentCount = 0
            return
        }
        memoryMultiple = baseline.memoryMultiple(for: family.totalPhysicalFootprintBytes)
        cpuMultiple = baseline.cpuMultiple(for: family.totalCPUPercent)
        peakMemoryBytes = baseline.peakMemoryBytes
        incidentCount = baseline.incidentCount
    }
}

public struct FamilyDetailViewModel: Identifiable, Equatable, Sendable {
    public var id: String { familyKey }

    public let familyKey: String
    public let signature: ProcessSignature
    public let displayName: String
    public let commandLine: String
    public let rootPID: Int32
    public let level: GhostLevel
    public let score: Double
    public let components: [GhostScoreComponent]
    public let suggestions: [RadarActionSuggestion]
    public let memoryBytes: UInt64
    public let residentBytes: UInt64
    public let cpuPercent: Double
    public let gpuPercent: Double
    public let leakVelocity: Double
    public let cpuSlope: Double
    public let childCount: Int
    public let devConfidence: Double
    public let processCount: Int
    public let isKillable: Bool
    public let protectedPIDs: [Int32]
    public let baselineDelta: FamilyBaselineDelta
    public let forensics: FamilyForensicsSummary
    public let members: [ProcessMetrics]
    public let trendPoints: [Double]
    public let lastScoredAt: Date?

    public init(family: ProcessFamily) {
        familyKey = family.familyKey
        signature = family.signature
        displayName = family.displayName
        commandLine = family.root.commandLine
        rootPID = family.root.pid
        level = family.score.level
        score = family.score.value
        components = family.score.components.sorted { $0.impact > $1.impact }
        suggestions = family.suggestions
        memoryBytes = family.totalPhysicalFootprintBytes
        residentBytes = family.totalResidentMemoryBytes
        cpuPercent = family.totalCPUPercent
        gpuPercent = family.totalGPUPercent
        leakVelocity = family.trend.memoryVelocityMegabytesPerMinute
        cpuSlope = family.trend.cpuSlopePerMinute
        childCount = family.childCount
        devConfidence = family.devConfidence
        processCount = family.members.count
        isKillable = family.isKillable
        protectedPIDs = family.protectedPIDs
        baselineDelta = FamilyBaselineDelta(family: family)
        forensics = FamilyForensicsSummary(family: family)
        members = family.members
        trendPoints = family.trend.memoryPoints
        lastScoredAt = family.lastScoredAt
    }
}
