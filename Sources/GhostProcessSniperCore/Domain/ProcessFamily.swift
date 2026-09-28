import Foundation
import Darwin

public struct ProcessFamily: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { root.identity }
    /// Built once: every cache, hysteresis and version map looks it up.
    public let familyKey: String

    public let root: ProcessMetrics
    public let members: [ProcessMetrics]
    public let totalResidentMemoryBytes: UInt64
    public let totalPhysicalFootprintBytes: UInt64
    public let totalCPUPercent: Double
    public let totalGPUPercent: Double
    public let devConfidence: Double
    public let commandHints: [String]
    public let trend: TrendMetrics
    public private(set) var score: GhostScore
    public let ownedIdentities: [ProcessIdentity]
    /// Same-user members outside the root's own process tree, in the family
    /// because macOS holds the root's app responsible for them: a browser's
    /// tab, graphics and network processes, which launchd started. They exit
    /// with the app, so the family's stop plan leaves them out, but each can
    /// be stopped alone.
    public let linkedIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let signature: ProcessSignature
    public private(set) var baseline: FamilyBaseline?
    public let forensics: ProcessForensics
    public private(set) var suggestions: [RadarActionSuggestion]
    public private(set) var alertState: AlertState
    public private(set) var recentIncidentCount: Int
    public private(set) var forecast: RiskForecast
    public private(set) var signatureVersion: UInt64
    public private(set) var metricsVersion: UInt64
    public private(set) var forensicsFreshness: Date?
    public private(set) var lastScoredAt: Date?
    public private(set) var classification: DevClassification?
    public private(set) var duplicateCluster: DuplicateProcessCluster?
    public private(set) var hardwareSignals: [HardwareOffenderSignal]
    /// Measurement coverage at build time.
    public let coverage: FamilyMeasurementCoverage
    /// The family whose member launched this family's root, e.g. the editor
    /// behind a language server. Nil for independent families.
    public private(set) var parentFamilyKey: String?
    /// CPU minutes and last activity from the activity ledger; empty for
    /// families built without history.
    public let cpuActivity: FamilyCPUActivity
    /// The builder's forgotten-process judgment; nil for hand-built
    /// families, which are judged on demand (see forgottenAssessment).
    public let forgotten: ForgottenAssessment?
    /// Exited children the root never reaped.
    public let zombieChildCount: Int
    /// Growth over the last ninety minutes, from the members' minute buckets.
    public let longTermTrend: LongTermTrend
    /// Which members the growth comes from, largest share first.
    public private(set) var growth: [MemberGrowth]

    /// The one member most of the growth comes from, on a clean trend.
    public var culprit: MemberGrowth? {
        growth.first.flatMap { $0.isCulprit ? $0 : nil }
    }

    public var displayName: String { root.name }
    public var childCount: Int { max(0, members.count - 1) }
    public var isKillable: Bool { !ownedIdentities.isEmpty && protectedPIDs.isEmpty }

    /// Whether one member may be previewed and stopped by itself: the family's
    /// own processes, and the helpers linked in by their app.
    public func canStopIndividually(_ identity: ProcessIdentity) -> Bool {
        ownedIdentities.contains(identity) || linkedIdentities.contains(identity)
    }

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
        linkedIdentities: [ProcessIdentity] = [],
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
        coverage: FamilyMeasurementCoverage? = nil,
        parentFamilyKey: String? = nil,
        cpuActivity: FamilyCPUActivity = .empty,
        forgotten: ForgottenAssessment? = nil,
        zombieChildCount: Int? = nil,
        longTermTrend: LongTermTrend = .none,
        growth: [MemberGrowth] = []
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
        self.linkedIdentities = linkedIdentities
        self.protectedPIDs = protectedPIDs
        let signature = signature ?? ProcessSignature.from(root: root)
        self.signature = signature
        self.familyKey = Self.key(signature: signature, root: root.identity)
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
        self.parentFamilyKey = parentFamilyKey
        self.cpuActivity = cpuActivity
        self.forgotten = forgotten
        self.zombieChildCount = zombieChildCount ?? members.filter { $0.isZombie && $0.identity != root.identity }.count
        self.longTermTrend = longTermTrend
        self.growth = growth
    }

    /// The forgotten-process judgment: the builder's, or one made now from
    /// what the family carries (no session liveness or directory checks).
    public var forgottenAssessment: ForgottenAssessment {
        if let forgotten { return forgotten }
        return ForgottenProcessAssessor.assess(
            root: root,
            context: LaunchContextResolver.resolve(root: root, livePIDs: Set(members.map(\.pid))),
            activity: cpuActivity,
            forensics: forensics,
            workingDirectoryMissing: false,
            now: lastScoredAt ?? root.sampledAt
        )
    }

    /// One concrete instance of a signature: the signature plus the root.
    public static func key(signature: ProcessSignature, root: ProcessIdentity) -> String {
        "\(signature.id)|pid:\(root.pid)|start:\(root.startTimeSeconds).\(root.startTimeMicroseconds)"
    }

    mutating func attribute(growth: [MemberGrowth]) {
        self.growth = growth
    }

    public func killPlan(
        killHistory: KillHistorySummary? = nil,
        workload: KillWorkloadProfile? = nil,
        strategyCalibrations: KillOutcomeHistory = .empty
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
        // A copy keeps the measured totals, forensics, coverage and key.
        var copy = self
        if let score { copy.score = score }
        if let baseline { copy.baseline = baseline }
        if let suggestions { copy.suggestions = suggestions }
        if let alertState { copy.alertState = alertState }
        if let recentIncidentCount { copy.recentIncidentCount = recentIncidentCount }
        if let forecast { copy.forecast = forecast }
        if let signatureVersion { copy.signatureVersion = signatureVersion }
        if let metricsVersion { copy.metricsVersion = metricsVersion }
        if let forensicsFreshness { copy.forensicsFreshness = forensicsFreshness }
        if let lastScoredAt { copy.lastScoredAt = lastScoredAt }
        if let classification { copy.classification = classification }
        if let duplicateCluster { copy.duplicateCluster = duplicateCluster }
        if let hardwareSignals { copy.hardwareSignals = hardwareSignals }
        return copy
    }

    static func aggregateForensics(from members: [ProcessMetrics]) -> ProcessForensics {
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

