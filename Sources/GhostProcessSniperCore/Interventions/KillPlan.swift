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
    /// When the user approved the preview. Children born after it that
    /// descend from an approved process stop with it; older ones were
    /// shown in the preview, or deliberately left out of it.
    public let approvedAt: Date?
    /// The phases and waits the user approved in the preview. Confirm runs
    /// them as they are; it only ever lengthens the first wait.
    public let approvedProfile: KillStrategyProfile?
    /// Forces the survivors of an earlier, held stop; it teaches the
    /// learning tables nothing new.
    public let isForceFollowUp: Bool
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
        approvedAt: Date? = nil,
        approvedProfile: KillStrategyProfile? = nil,
        isForceFollowUp: Bool = false,
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
        self.approvedAt = approvedAt
        self.approvedProfile = approvedProfile
        self.isForceFollowUp = isForceFollowUp
        self.workload = workload
        self.strategyCalibrations = strategyCalibrations
        self.launchdStop = launchdStop
    }

    public func binding(
        to identities: [ProcessIdentity],
        expiresAt: Date,
        profile: KillStrategyProfile? = nil,
        approvedAt: Date = Date(),
        launchdStop: KillLaunchdStop = .none
    ) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 approvedIdentities: Set(identities), approvalExpiresAt: expiresAt, approvedAt: approvedAt,
                 approvedProfile: profile, workload: workload, strategyCalibrations: strategyCalibrations,
                 launchdStop: launchdStop)
    }

    /// The approved plan with the user's choice for the root's launchd job.
    public func stoppingLaunchdJob(_ stop: KillLaunchdStop) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 approvedIdentities: approvedIdentities, approvalExpiresAt: approvalExpiresAt, approvedAt: approvedAt,
                 approvedProfile: approvedProfile, isForceFollowUp: isForceFollowUp, workload: workload,
                 strategyCalibrations: strategyCalibrations, launchdStop: stop)
    }

    /// The same plan with the root's launchd job attached to its workload.
    public func withLaunchdJob(_ job: LaunchdJob) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 approvedIdentities: approvedIdentities, approvalExpiresAt: approvalExpiresAt, approvedAt: approvedAt,
                 approvedProfile: approvedProfile, isForceFollowUp: isForceFollowUp, workload: workload?.withLaunchdJob(job),
                 strategyCalibrations: strategyCalibrations, launchdStop: launchdStop)
    }

    /// A plan that sends SIGKILL now to what a held stop reported still
    /// running, and to nothing else. Nil when nothing survived. The launchd
    /// job, if any, was already booted out by the held stop.
    public func forcingSurvivors(of report: KillReport, now: Date = Date()) -> KillPlan? {
        let survivors = report.targetResults.filter { $0.state == .survived }.map(\.identity)
        guard !survivors.isEmpty else { return nil }
        return KillPlan(rootIdentity: rootIdentity, targetIdentities: survivors, protectedPIDs: protectedPIDs,
                        displayName: displayName, gracefulSignal: gracefulSignal, scope: scope,
                        createdAt: now, familyMetadata: familyMetadata, killHistory: killHistory,
                        approvedIdentities: Set(survivors), approvalExpiresAt: now.addingTimeInterval(30), approvedAt: now,
                        approvedProfile: .forceNow, isForceFollowUp: true, workload: workload,
                        strategyCalibrations: strategyCalibrations)
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
