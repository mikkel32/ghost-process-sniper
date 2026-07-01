import Foundation
import Darwin

public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeSeconds: UInt64, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
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
    public let forensics: ProcessForensics

    public var pid: Int32 { identity.pid }
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
        forensics: ProcessForensics = .unavailable(reason: "not sampled")
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
        self.forensics = forensics
    }
}

public struct ProcessSignature: Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let canonicalPath: String
    public let commandFingerprint: String

    public init(displayName: String, canonicalPath: String, commandLine: String) {
        let normalizedCommand = ProcessSignature.normalizedCommand(commandLine)
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.commandFingerprint = ProcessSignature.fingerprint(normalizedCommand)
        self.id = [
            displayName.lowercased(),
            canonicalPath.lowercased(),
            commandFingerprint
        ].joined(separator: "|")
    }

    public init(id: String, displayName: String, canonicalPath: String, commandFingerprint: String) {
        self.id = id
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.commandFingerprint = commandFingerprint
    }

    public static func from(root: ProcessMetrics) -> ProcessSignature {
        let path = root.executablePath.isEmpty ? root.name : root.executablePath
        return ProcessSignature(
            displayName: root.name,
            canonicalPath: path,
            commandLine: root.commandLine
        )
    }

    private static func normalizedCommand(_ command: String) -> String {
        command
            .split(whereSeparator: \.isWhitespace)
            .map { piece in
                let text = String(piece)
                if text.hasPrefix("/var/folders/") || text.hasPrefix("/private/var/folders/") {
                    return "<tmp>"
                }
                if text.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                    return "<num>"
                }
                return text
            }
            .prefix(12)
            .joined(separator: " ")
            .lowercased()
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public struct ProcessForensics: Codable, Equatable, Sendable {
    public let currentDirectory: String?
    public let rootDirectory: String?
    public let openFileCount: Int?
    public let socketCount: Int?
    public let listeningPorts: [Int]
    public let isPartial: Bool
    public let notes: [String]

    public static func unavailable(reason: String) -> ProcessForensics {
        ProcessForensics(
            currentDirectory: nil,
            rootDirectory: nil,
            openFileCount: nil,
            socketCount: nil,
            listeningPorts: [],
            isPartial: true,
            notes: [reason]
        )
    }

    public init(
        currentDirectory: String?,
        rootDirectory: String?,
        openFileCount: Int?,
        socketCount: Int?,
        listeningPorts: [Int],
        isPartial: Bool,
        notes: [String]
    ) {
        self.currentDirectory = currentDirectory
        self.rootDirectory = rootDirectory
        self.openFileCount = openFileCount
        self.socketCount = socketCount
        self.listeningPorts = listeningPorts
        self.isPartial = isPartial
        self.notes = notes
    }
}

public struct ProcessFamily: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { root.identity }
    public var familyKey: String {
        "\(signature.id)|pid:\(root.identity.pid)|start:\(root.identity.startTimeSeconds).\(root.identity.startTimeMicroseconds)"
    }

    public let root: ProcessMetrics
    public let members: [ProcessMetrics]
    public let totalResidentMemoryBytes: UInt64
    public let totalPhysicalFootprintBytes: UInt64
    public let totalCPUPercent: Double
    public let totalGPUPercent: Double
    public let devConfidence: Double
    public let commandHints: [String]
    public let trend: TrendMetrics
    public let score: GhostScore
    public let ownedIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let signature: ProcessSignature
    public let baseline: FamilyBaseline?
    public let forensics: ProcessForensics
    public let suggestions: [RadarActionSuggestion]
    public let alertState: AlertState
    public let recentIncidentCount: Int
    public let forecast: RiskForecast
    public let signatureVersion: UInt64
    public let metricsVersion: UInt64
    public let forensicsFreshness: Date?
    public let lastScoredAt: Date?
    public let classification: DevClassification?
    public let duplicateCluster: DuplicateProcessCluster?
    public let hardwareSignals: [HardwareOffenderSignal]

    public var displayName: String { root.name }
    public var childCount: Int { max(0, members.count - 1) }
    public var isKillable: Bool { !ownedIdentities.isEmpty && protectedPIDs.isEmpty }

    public init(
        root: ProcessMetrics,
        members: [ProcessMetrics],
        totalResidentMemoryBytes: UInt64,
        totalPhysicalFootprintBytes: UInt64,
        totalCPUPercent: Double,
        totalGPUPercent: Double = 0,
        devConfidence: Double,
        commandHints: [String],
        trend: TrendMetrics,
        score: GhostScore,
        ownedIdentities: [ProcessIdentity],
        protectedPIDs: [Int32],
        signature: ProcessSignature? = nil,
        baseline: FamilyBaseline? = nil,
        forensics: ProcessForensics? = nil,
        suggestions: [RadarActionSuggestion] = [],
        alertState: AlertState = .normal,
        recentIncidentCount: Int = 0,
        forecast: RiskForecast = .quiet,
        signatureVersion: UInt64 = 0,
        metricsVersion: UInt64 = 0,
        forensicsFreshness: Date? = nil,
        lastScoredAt: Date? = nil,
        classification: DevClassification? = nil,
        duplicateCluster: DuplicateProcessCluster? = nil,
        hardwareSignals: [HardwareOffenderSignal] = []
    ) {
        self.root = root
        self.members = members
        self.totalResidentMemoryBytes = totalResidentMemoryBytes
        self.totalPhysicalFootprintBytes = totalPhysicalFootprintBytes
        self.totalCPUPercent = totalCPUPercent
        self.totalGPUPercent = max(0, totalGPUPercent)
        self.devConfidence = devConfidence
        self.commandHints = commandHints
        self.trend = trend
        self.score = score
        self.ownedIdentities = ownedIdentities
        self.protectedPIDs = protectedPIDs
        self.signature = signature ?? ProcessSignature.from(root: root)
        self.baseline = baseline
        self.forensics = forensics ?? ProcessFamily.aggregateForensics(from: members)
        self.suggestions = suggestions
        self.alertState = alertState
        self.recentIncidentCount = recentIncidentCount
        self.forecast = forecast
        self.signatureVersion = signatureVersion
        self.metricsVersion = metricsVersion
        self.forensicsFreshness = forensicsFreshness
        self.lastScoredAt = lastScoredAt
        self.classification = classification
        self.duplicateCluster = duplicateCluster
        self.hardwareSignals = hardwareSignals
    }

    public func killPlan(
        killHistory: KillHistorySummary? = nil,
        killCalibration: KillCalibrationSnapshot? = nil
    ) -> KillPlan {
        KillPlan(
            rootIdentity: root.identity,
            targetIdentities: ownedIdentities,
            protectedPIDs: protectedPIDs,
            displayName: displayName,
            familyMetadata: KillFamilyMetadata(family: self),
            killHistory: killHistory,
            killCalibration: killCalibration
        )
    }

    public func enriched(
        score: GhostScore? = nil,
        baseline: FamilyBaseline? = nil,
        suggestions: [RadarActionSuggestion]? = nil,
        alertState: AlertState? = nil,
        recentIncidentCount: Int? = nil,
        forecast: RiskForecast? = nil,
        signatureVersion: UInt64? = nil,
        metricsVersion: UInt64? = nil,
        forensicsFreshness: Date? = nil,
        lastScoredAt: Date? = nil,
        classification: DevClassification? = nil,
        duplicateCluster: DuplicateProcessCluster? = nil,
        hardwareSignals: [HardwareOffenderSignal]? = nil
    ) -> ProcessFamily {
        ProcessFamily(
            root: root,
            members: members,
            totalResidentMemoryBytes: totalResidentMemoryBytes,
            totalPhysicalFootprintBytes: totalPhysicalFootprintBytes,
            totalCPUPercent: totalCPUPercent,
            totalGPUPercent: totalGPUPercent,
            devConfidence: devConfidence,
            commandHints: commandHints,
            trend: trend,
            score: score ?? self.score,
            ownedIdentities: ownedIdentities,
            protectedPIDs: protectedPIDs,
            signature: signature,
            baseline: baseline ?? self.baseline,
            forensics: forensics,
            suggestions: suggestions ?? self.suggestions,
            alertState: alertState ?? self.alertState,
            recentIncidentCount: recentIncidentCount ?? self.recentIncidentCount,
            forecast: forecast ?? self.forecast,
            signatureVersion: signatureVersion ?? self.signatureVersion,
            metricsVersion: metricsVersion ?? self.metricsVersion,
            forensicsFreshness: forensicsFreshness ?? self.forensicsFreshness,
            lastScoredAt: lastScoredAt ?? self.lastScoredAt,
            classification: classification ?? self.classification,
            duplicateCluster: duplicateCluster ?? self.duplicateCluster,
            hardwareSignals: hardwareSignals ?? self.hardwareSignals
        )
    }

    private static func aggregateForensics(from members: [ProcessMetrics]) -> ProcessForensics {
        let root = members.first?.forensics
        let openFiles = members.compactMap(\.forensics.openFileCount).reduce(0, +)
        let sockets = members.compactMap(\.forensics.socketCount).reduce(0, +)
        let ports = members.flatMap(\.forensics.listeningPorts)
        let notes = members.flatMap(\.forensics.notes)
        return ProcessForensics(
            currentDirectory: root?.currentDirectory,
            rootDirectory: root?.rootDirectory,
            openFileCount: openFiles > 0 ? openFiles : nil,
            socketCount: sockets > 0 ? sockets : nil,
            listeningPorts: Array(Set(ports)).sorted().prefix(8).map { $0 },
            isPartial: members.contains { $0.forensics.isPartial },
            notes: Array(Set(notes)).sorted().prefix(5).map { $0 }
        )
    }
}

public struct KillPlan: Equatable, Sendable {
    public let rootIdentity: ProcessIdentity
    public let targetIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let displayName: String
    public let gracefulSignal: Int32
    public let treePolicy: KillTreePolicy
    public let scope: KillScope
    public let createdAt: Date
    public let familyMetadata: KillFamilyMetadata?
    public let killHistory: KillHistorySummary?
    public let killCalibration: KillCalibrationSnapshot?

    public init(
        rootIdentity: ProcessIdentity,
        targetIdentities: [ProcessIdentity],
        protectedPIDs: [Int32],
        displayName: String,
        gracefulSignal: Int32 = SIGTERM,
        treePolicy: KillTreePolicy = .ownedFamily,
        scope: KillScope = .ownedFamily,
        createdAt: Date = Date(),
        familyMetadata: KillFamilyMetadata? = nil,
        killHistory: KillHistorySummary? = nil,
        killCalibration: KillCalibrationSnapshot? = nil
    ) {
        self.rootIdentity = rootIdentity
        self.targetIdentities = targetIdentities
        self.protectedPIDs = protectedPIDs
        self.displayName = displayName
        self.gracefulSignal = gracefulSignal
        self.treePolicy = treePolicy
        self.scope = scope
        self.createdAt = createdAt
        self.familyMetadata = familyMetadata
        self.killHistory = killHistory
        self.killCalibration = killCalibration
    }
}
