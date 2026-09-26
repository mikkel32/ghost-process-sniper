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
    /// Outcome posteriors per strategy, for this family and its kind, so a
    /// strategy is only tuned by its own history.
    public let strategyCalibrations: KillOutcomeHistory
    /// Whether confirming boots the root's launchd job out instead of
    /// signalling a process launchd would restart.
    public let launchdStop: KillLaunchdStop

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
        strategyCalibrations: KillOutcomeHistory = .empty,
        launchdStop: KillLaunchdStop = .none
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
        self.launchdStop = launchdStop
    }

    public func binding(
        to identities: [ProcessIdentity],
        expiresAt: Date,
        strategy: KillStrategy? = nil,
        launchdStop: KillLaunchdStop = .none
    ) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 approvedIdentities: Set(identities), approvalExpiresAt: expiresAt,
                 approvedStrategy: strategy, workload: workload, strategyCalibrations: strategyCalibrations,
                 launchdStop: launchdStop)
    }

    /// The same plan with the root's launchd job attached to its workload.
    public func withLaunchdJob(_ job: LaunchdJob) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 approvedIdentities: approvedIdentities, approvalExpiresAt: approvalExpiresAt,
                 approvedStrategy: approvedStrategy, workload: workload?.withLaunchdJob(job),
                 strategyCalibrations: strategyCalibrations, launchdStop: launchdStop)
    }

    public func targetingOnly(_ process: ProcessMetrics) -> KillPlan {
        targetingOnly(process.identity, name: process.name)
    }

    public func targetingOnly(_ identity: ProcessIdentity, name: String) -> KillPlan {
        KillPlan(rootIdentity: identity, targetIdentities: [identity], protectedPIDs: protectedPIDs,
                 displayName: name, gracefulSignal: gracefulSignal, scope: .singleRoot,
                 familyMetadata: familyMetadata, killHistory: killHistory,
                 workload: workload?.restricted(to: identity.pid), strategyCalibrations: strategyCalibrations)
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
    /// The forecast's own words for why the family matters now.
    public let forecastReason: String

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
        forecastReason: String = ""
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
        self.forecastReason = forecastReason
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
            forecastReason: family.forecast.whyNow
        )
    }
}
