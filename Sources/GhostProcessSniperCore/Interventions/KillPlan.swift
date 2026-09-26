import Foundation
import Darwin

public struct KillPlan: Equatable, Sendable {
    public let rootIdentity: ProcessIdentity
    public let targetIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let displayName: String
    public let gracefulSignal: Int32
    public let scope: KillScope
    public let createdAt: Date
    public let familyMetadata: KillFamilyMetadata?
    public let killHistory: KillHistorySummary?
    public let approvedIdentities: Set<ProcessIdentity>?
    public let approvalExpiresAt: Date?
    public let approvedStrategy: KillStrategy?
    /// Names, paths, command lines, ports and supervisors, for risk-aware stops.
    public let workload: KillWorkloadProfile?
    /// Local outcomes per strategy, so a strategy is only tuned by its own history.
    public let strategyCalibrations: [KillStrategy: KillCalibrationSnapshot]

    public init(
        rootIdentity: ProcessIdentity,
        targetIdentities: [ProcessIdentity],
        protectedPIDs: [Int32],
        displayName: String,
        gracefulSignal: Int32 = SIGTERM,
        scope: KillScope = .ownedFamily,
        createdAt: Date = Date(),
        familyMetadata: KillFamilyMetadata? = nil,
        killHistory: KillHistorySummary? = nil,
        approvedIdentities: Set<ProcessIdentity>? = nil,
        approvalExpiresAt: Date? = nil,
        approvedStrategy: KillStrategy? = nil,
        workload: KillWorkloadProfile? = nil,
        strategyCalibrations: [KillStrategy: KillCalibrationSnapshot] = [:]
    ) {
        self.rootIdentity = rootIdentity
        self.targetIdentities = targetIdentities
        self.protectedPIDs = protectedPIDs
        self.displayName = displayName
        self.gracefulSignal = gracefulSignal
        self.scope = scope
        self.createdAt = createdAt
        self.familyMetadata = familyMetadata
        self.killHistory = killHistory
        self.approvedIdentities = approvedIdentities
        self.approvalExpiresAt = approvalExpiresAt
        self.approvedStrategy = approvedStrategy
        self.workload = workload
        self.strategyCalibrations = strategyCalibrations
    }

    /// History for the strategy about to run; never another strategy's.
    public func calibration(for strategy: KillStrategy) -> KillCalibrationSnapshot {
        strategyCalibrations[strategy] ?? .empty
    }

    public func binding(to identities: [ProcessIdentity], expiresAt: Date, strategy: KillStrategy? = nil) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 approvedIdentities: Set(identities), approvalExpiresAt: expiresAt,
                 approvedStrategy: strategy, workload: workload, strategyCalibrations: strategyCalibrations)
    }

    public func targetingOnly(_ process: ProcessMetrics) -> KillPlan {
        KillPlan(rootIdentity: process.identity, targetIdentities: [process.identity], protectedPIDs: protectedPIDs,
                 displayName: process.name, gracefulSignal: gracefulSignal, scope: .singleRoot,
                 familyMetadata: familyMetadata, killHistory: killHistory,
                 workload: workload?.restricted(to: process.pid), strategyCalibrations: strategyCalibrations)
    }
}

public struct KillFamilyMetadata: Equatable, Sendable {
    public let signatureID: String
    public let displayName: String
    public let scoreValue: Double
    public let scoreLevel: GhostLevel
    public let forecastState: ForecastState
    public let devKindLabel: String
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let childCount: Int
    public let isBackgroundOrOrphan: Bool

    public init(
        signatureID: String,
        displayName: String,
        scoreValue: Double,
        scoreLevel: GhostLevel,
        forecastState: ForecastState,
        devKindLabel: String,
        memoryBytes: UInt64,
        cpuPercent: Double,
        childCount: Int,
        isBackgroundOrOrphan: Bool
    ) {
        self.signatureID = signatureID
        self.displayName = displayName
        self.scoreValue = scoreValue
        self.scoreLevel = scoreLevel
        self.forecastState = forecastState
        self.devKindLabel = devKindLabel
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.childCount = childCount
        self.isBackgroundOrOrphan = isBackgroundOrOrphan
    }

    public init(family: ProcessFamily) {
        self.init(
            signatureID: family.signature.id,
            displayName: family.displayName,
            scoreValue: family.score.value,
            scoreLevel: family.score.level,
            forecastState: family.forecast.state,
            devKindLabel: family.classification?.kind.label ?? "Process family",
            memoryBytes: family.totalPhysicalFootprintBytes,
            cpuPercent: family.totalCPUPercent,
            childCount: family.childCount,
            isBackgroundOrOrphan: family.root.parentPID == 1
        )
    }
}
