import Foundation
import Darwin

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
    /// Measurement coverage at build time.
    public let coverage: FamilyMeasurementCoverage

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
        hardwareSignals: [HardwareOffenderSignal] = [],
        coverage: FamilyMeasurementCoverage? = nil
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
        self.coverage = coverage ?? FamilyMeasurementCoverage(members: members, root: root, at: lastScoredAt ?? root.sampledAt)
    }

    public func killPlan(
        killHistory: KillHistorySummary? = nil,
        workload: KillWorkloadProfile? = nil,
        strategyCalibrations: [KillStrategy: KillCalibrationSnapshot] = [:]
    ) -> KillPlan {
        KillPlan(
            rootIdentity: root.identity,
            targetIdentities: ownedIdentities,
            protectedPIDs: protectedPIDs,
            displayName: displayName,
            familyMetadata: KillFamilyMetadata(family: self),
            killHistory: killHistory,
            workload: workload ?? KillWorkloadProfile(family: self, sample: []),
            strategyCalibrations: strategyCalibrations
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
            hardwareSignals: hardwareSignals ?? self.hardwareSignals,
            coverage: coverage
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

