import Foundation
import Darwin

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
    public let approvedIdentities: Set<ProcessIdentity>?
    public let approvalExpiresAt: Date?
    public let approvedStrategy: KillStrategy?

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
        killCalibration: KillCalibrationSnapshot? = nil,
        approvedIdentities: Set<ProcessIdentity>? = nil,
        approvalExpiresAt: Date? = nil,
        approvedStrategy: KillStrategy? = nil
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
        self.approvedIdentities = approvedIdentities
        self.approvalExpiresAt = approvalExpiresAt
        self.approvedStrategy = approvedStrategy
    }

    public func binding(to identities: [ProcessIdentity], expiresAt: Date, strategy: KillStrategy? = nil) -> KillPlan {
        KillPlan(rootIdentity: rootIdentity, targetIdentities: targetIdentities, protectedPIDs: protectedPIDs,
                 displayName: displayName, gracefulSignal: gracefulSignal, treePolicy: treePolicy, scope: scope,
                 createdAt: createdAt, familyMetadata: familyMetadata, killHistory: killHistory,
                 killCalibration: killCalibration, approvedIdentities: Set(identities), approvalExpiresAt: expiresAt,
                 approvedStrategy: strategy)
    }

    public func targetingOnly(_ process: ProcessMetrics) -> KillPlan {
        KillPlan(rootIdentity: process.identity, targetIdentities: [process.identity], protectedPIDs: protectedPIDs,
                 displayName: process.name, gracefulSignal: gracefulSignal, scope: .singleRoot,
                 familyMetadata: familyMetadata, killHistory: killHistory, killCalibration: killCalibration)
    }
}
