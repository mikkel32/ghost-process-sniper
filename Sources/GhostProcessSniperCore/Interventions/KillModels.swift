import Darwin
import Foundation

public enum KillTreePolicy: String, Codable, Sendable {
    case ownedFamily

    public var label: String {
        switch self {
        case .ownedFamily: "Owned family"
        }
    }
}

public enum KillSnapshotPolicy: String, Sendable {
    case preflight
    case confirm
    case verify

    public var label: String {
        switch self {
        case .preflight: "preflight"
        case .confirm: "confirm"
        case .verify: "verify"
        }
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

public struct KillEscalationProfile: Equatable, Sendable {
    public let gracefulSignal: Int32
    public let forcedSignal: Int32
    public let forceKillDelay: TimeInterval

    public static func `default`(
        gracefulSignal: Int32 = SIGTERM,
        forceKillDelay: TimeInterval = 2
    ) -> KillEscalationProfile {
        KillEscalationProfile(
            gracefulSignal: gracefulSignal,
            forcedSignal: SIGKILL,
            forceKillDelay: forceKillDelay
        )
    }

    public init(gracefulSignal: Int32, forcedSignal: Int32, forceKillDelay: TimeInterval) {
        self.gracefulSignal = gracefulSignal
        self.forcedSignal = forcedSignal
        self.forceKillDelay = max(0, forceKillDelay)
    }
}

public struct KillOperationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

public struct KillProcessSnapshot: Equatable, Sendable {
    public let processes: [ProcessMetrics]
    public let sampledAt: Date
    public let policy: KillSnapshotPolicy
    public let elapsedMilliseconds: Double
    public let usedCheapPath: Bool
    public let expensiveCallCount: Int
    public let request: KillSnapshotRequest?
    public let graph: KillProcessGraph?
    public let arena: KillGraphArena?
    public let graphReadCount: Int
    public let heavyMetricReadCount: Int
    public let didHitBudget: Bool
    public let targetConversionCount: Int
    public let cacheStatus: KillSnapshotCacheStatus
    public let skippedOptionalWorkCount: Int

    public init(
        processes: [ProcessMetrics],
        sampledAt: Date = Date(),
        policy: KillSnapshotPolicy = .preflight,
        elapsedMilliseconds: Double = 0,
        usedCheapPath: Bool = false,
        expensiveCallCount: Int = 0,
        request: KillSnapshotRequest? = nil,
        graph: KillProcessGraph? = nil,
        arena: KillGraphArena? = nil,
        graphReadCount: Int = 0,
        heavyMetricReadCount: Int = 0,
        didHitBudget: Bool = false,
        targetConversionCount: Int? = nil,
        cacheStatus: KillSnapshotCacheStatus = .none,
        skippedOptionalWorkCount: Int = 0
    ) {
        self.processes = processes
        self.sampledAt = sampledAt
        self.policy = policy
        self.elapsedMilliseconds = elapsedMilliseconds
        self.usedCheapPath = usedCheapPath
        self.expensiveCallCount = expensiveCallCount
        self.request = request
        self.graph = graph
        self.arena = arena
        self.graphReadCount = graphReadCount
        self.heavyMetricReadCount = heavyMetricReadCount
        self.didHitBudget = didHitBudget
        self.targetConversionCount = targetConversionCount ?? processes.count
        self.cacheStatus = cacheStatus
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
    }

    public func updatingCacheStatus(_ status: KillSnapshotCacheStatus) -> KillProcessSnapshot {
        KillProcessSnapshot(
            processes: processes,
            sampledAt: sampledAt,
            policy: policy,
            elapsedMilliseconds: elapsedMilliseconds,
            usedCheapPath: usedCheapPath,
            expensiveCallCount: expensiveCallCount,
            request: request,
            graph: graph,
            arena: arena,
            graphReadCount: graphReadCount,
            heavyMetricReadCount: heavyMetricReadCount,
            didHitBudget: didHitBudget,
            targetConversionCount: targetConversionCount,
            cacheStatus: status,
            skippedOptionalWorkCount: skippedOptionalWorkCount
        )
    }
}

public struct KillProcessIndex: Sendable {
    public let snapshot: KillProcessSnapshot
    private let byIdentity: [ProcessIdentity: ProcessMetrics]
    private let byPID: [Int32: [ProcessMetrics]]
    private let childrenByPID: [Int32: [ProcessMetrics]]
    private let byIdentityLite: [ProcessIdentity: KillProcessLite]
    private let byPIDLite: [Int32: [KillProcessLite]]
    private let childrenByPIDLite: [Int32: [KillProcessLite]]
    private let arena: KillGraphArena?

    public init(snapshot: KillProcessSnapshot) {
        self.snapshot = snapshot
        self.arena = snapshot.arena
        self.byIdentity = Dictionary(snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        self.byPID = Dictionary(grouping: snapshot.processes, by: \.pid)
        self.childrenByPID = Dictionary(grouping: snapshot.processes, by: \.parentPID)
        let liteProcesses = snapshot.graph?.processes ?? []
        self.byIdentityLite = Dictionary(liteProcesses.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        self.byPIDLite = Dictionary(grouping: liteProcesses, by: \.pid)
        self.childrenByPIDLite = Dictionary(grouping: liteProcesses, by: \.parentPID)
    }

    public func process(for identity: ProcessIdentity) -> ProcessMetrics? {
        if let process = byIdentity[identity] {
            return process
        }
        if let process = arena?.process(for: identity) {
            return process.asProcessMetrics()
        }
        return byIdentityLite[identity]?.asProcessMetrics()
    }

    public func liteProcess(for identity: ProcessIdentity) -> KillProcessLite? {
        if let process = arena?.process(for: identity) {
            return process
        }
        return byIdentityLite[identity] ?? byIdentity[identity].map { KillProcessLite(process: $0) }
    }

    public func hasRecycledPID(for identity: ProcessIdentity) -> Bool {
        if arena?.hasRecycledPID(for: identity) == true {
            return true
        }
        if byPIDLite[identity.pid]?.contains(where: { $0.identity != identity }) == true {
            return true
        }
        return byPID[identity.pid]?.contains { $0.identity != identity } == true
    }

    public func descendants(of rootIdentity: ProcessIdentity) -> [(process: ProcessMetrics, depth: Int)] {
        if let arena {
            return arena.descendants(of: rootIdentity).map { ($0.process.asProcessMetrics(), $0.depth) }
        }
        if !byIdentityLite.isEmpty {
            return descendantsLite(of: rootIdentity).map { ($0.process.asProcessMetrics(), $0.depth) }
        }
        guard let root = byIdentity[rootIdentity] else {
            return []
        }
        var output: [(ProcessMetrics, Int)] = []
        var stack: [(ProcessMetrics, Int)] = [(root, 0)]
        var seen = Set<ProcessIdentity>()
        while let item = stack.popLast() {
            guard seen.insert(item.0.identity).inserted else {
                continue
            }
            output.append(item)
            for child in childrenByPID[item.0.pid, default: []] {
                stack.append((child, item.1 + 1))
            }
        }
        return output
    }

    public func descendantsLite(of rootIdentity: ProcessIdentity) -> [(process: KillProcessLite, depth: Int)] {
        if let arena {
            return arena.descendants(of: rootIdentity).map { ($0.process, $0.depth) }
        }
        guard let root = liteProcess(for: rootIdentity) else {
            return []
        }
        var output: [(KillProcessLite, Int)] = []
        var stack: [(KillProcessLite, Int)] = [(root, 0)]
        var seen = Set<ProcessIdentity>()
        while let item = stack.popLast() {
            guard seen.insert(item.0.identity).inserted else {
                continue
            }
            output.append(item)
            for child in childrenByPIDLite[item.0.pid, default: []] {
                stack.append((child, item.1 + 1))
            }
            if childrenByPIDLite.isEmpty {
                for child in childrenByPID[item.0.pid, default: []] {
                    stack.append((KillProcessLite(process: child), item.1 + 1))
                }
            }
        }
        return output
    }
}

public enum KillTargetState: String, Codable, CaseIterable, Sendable {
    case ready
    case locked
    case stale
    case recycled
    case terminated
    case forceKilled
    case survived
    case exitedBeforeSignal
    case failed

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .locked: "Locked"
        case .stale: "Stale"
        case .recycled: "Recycled"
        case .terminated: "Terminated"
        case .forceKilled: "Force killed"
        case .survived: "Survived"
        case .exitedBeforeSignal: "Exited first"
        case .failed: "Failed"
        }
    }
}

public struct KillTarget: Identifiable, Equatable, Sendable {
    public var id: String {
        "\(identity.pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)-\(state.rawValue)"
    }

    public let identity: ProcessIdentity
    public let parentPID: Int32?
    public let name: String
    public let ownerName: String
    public let depth: Int
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let state: KillTargetState
    public let reason: String
    public let isRoot: Bool

    public var pid: Int32 { identity.pid }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32?,
        name: String,
        ownerName: String,
        depth: Int,
        memoryBytes: UInt64,
        cpuPercent: Double,
        state: KillTargetState,
        reason: String,
        isRoot: Bool
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.name = name
        self.ownerName = ownerName
        self.depth = depth
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.state = state
        self.reason = reason
        self.isRoot = isRoot
    }

    public init(process: ProcessMetrics, depth: Int, state: KillTargetState, reason: String, rootIdentity: ProcessIdentity) {
        self.init(
            identity: process.identity,
            parentPID: process.parentPID,
            name: process.name,
            ownerName: process.ownerName,
            depth: depth,
            memoryBytes: process.memoryForScoringBytes,
            cpuPercent: process.cpuPercent,
            state: state,
            reason: reason,
            isRoot: process.identity == rootIdentity
        )
    }

    public init(process: KillProcessLite, depth: Int, state: KillTargetState, reason: String, rootIdentity: ProcessIdentity) {
        self.init(
            identity: process.identity,
            parentPID: process.parentPID,
            name: process.name,
            ownerName: process.ownerName,
            depth: depth,
            memoryBytes: process.memoryForScoringBytes,
            cpuPercent: process.cpuPercent,
            state: state,
            reason: reason,
            isRoot: process.identity == rootIdentity
        )
    }

    public func updating(state: KillTargetState, reason: String) -> KillTarget {
        KillTarget(
            identity: identity,
            parentPID: parentPID,
            name: name,
            ownerName: ownerName,
            depth: depth,
            memoryBytes: memoryBytes,
            cpuPercent: cpuPercent,
            state: state,
            reason: reason,
            isRoot: isRoot
        )
    }
}

public enum KillReadiness: String, Codable, Comparable, Sendable {
    case ready
    case caution
    case locked

    public static func < (lhs: KillReadiness, rhs: KillReadiness) -> Bool {
        order(lhs) < order(rhs)
    }

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .caution: "Caution"
        case .locked: "Locked"
        }
    }

    private static func order(_ readiness: KillReadiness) -> Int {
        switch readiness {
        case .locked: 0
        case .caution: 1
        case .ready: 2
        }
    }
}

public struct KillReadinessScore: Equatable, Sendable {
    public let readiness: KillReadiness
    public let reasons: [String]

    public init(readiness: KillReadiness, reasons: [String]) {
        self.readiness = readiness
        self.reasons = reasons
    }
}

public enum KillDecisionEvidenceKind: String, Codable, Sendable {
    case positive
    case caution
    case blocking
    case info
}

public struct KillDecisionEvidence: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)-\(title)-\(detail)" }

    public let kind: KillDecisionEvidenceKind
    public let title: String
    public let detail: String

    public init(kind: KillDecisionEvidenceKind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct KillReclaimEstimate: Codable, Equatable, Sendable {
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let confidence: Double
    public let sourceText: String

    public static let empty = KillReclaimEstimate(
        memoryBytes: 0,
        cpuPercent: 0,
        confidence: 0,
        sourceText: "No reclaim estimate"
    )

    public init(memoryBytes: UInt64, cpuPercent: Double, confidence: Double, sourceText: String) {
        self.memoryBytes = memoryBytes
        self.cpuPercent = max(0, cpuPercent)
        self.confidence = min(1, max(0, confidence))
        self.sourceText = sourceText
    }
}

public struct KillReclaimEstimator: Sendable {
    public init() {}

    public func estimate(plan: KillPlan, targets: [KillTarget]) -> KillReclaimEstimate {
        let targetMemory = targets.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let targetCPU = targets.reduce(0) { $0 + $1.cpuPercent }
        if targetMemory > 0 || targetCPU > 0 {
            return KillReclaimEstimate(
                memoryBytes: targetMemory,
                cpuPercent: targetCPU,
                confidence: 0.82,
                sourceText: "Current owned target footprint"
            )
        }
        if !targets.isEmpty, plan.scope == .ownedFamily, plan.approvedIdentities == nil, let metadata = plan.familyMetadata {
            return KillReclaimEstimate(
                memoryBytes: metadata.memoryBytes,
                cpuPercent: metadata.cpuPercent,
                confidence: 0.58,
                sourceText: "Last radar family totals"
            )
        }
        return .empty
    }

    public func realizedEstimate(from estimate: KillReclaimEstimate, targets: [KillTarget]) -> UInt64 {
        let terminalMemory = targets.reduce(UInt64(0)) { partial, target in
            switch target.state {
            case .terminated, .forceKilled, .exitedBeforeSignal:
                partial + target.memoryBytes
            default:
                partial
            }
        }
        if terminalMemory > 0 {
            return min(estimate.memoryBytes, terminalMemory)
        }
        return targets.contains { $0.state == .survived } ? 0 : estimate.memoryBytes
    }
}

public struct KillConfidenceModel: Sendable {
    public init() {}

    public func evidence(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        reclaim: KillReclaimEstimate
    ) -> [KillDecisionEvidence] {
        var output: [KillDecisionEvidence] = []
        if targets.isEmpty {
            output.append(
                KillDecisionEvidence(
                    kind: .blocking,
                    title: "No owned live targets",
                    detail: "The selected identity tree has no same-user process to signal."
                )
            )
        } else {
            output.append(
                KillDecisionEvidence(
                    kind: .positive,
                    title: "Identity verified",
                    detail: "\(targets.count) owned target\(targets.count == 1 ? "" : "s") matched by PID plus start time."
                )
            )
            output.append(
                KillDecisionEvidence(
                    kind: .positive,
                    title: "Estimated reclaim",
                    detail: "\(RadarFormat.bytes(reclaim.memoryBytes)) and \(Int(reclaim.cpuPercent.rounded()))% CPU from \(reclaim.sourceText.lowercased())."
                )
            )
        }

        if !locked.isEmpty {
            output.append(
                KillDecisionEvidence(
                    kind: .caution,
                    title: "Locked descendants",
                    detail: "\(locked.count) protected or foreign process\(locked.count == 1 ? "" : "es") will stay untouched."
                )
            )
        }
        if !stale.isEmpty || !recycled.isEmpty {
            output.append(
                KillDecisionEvidence(
                    kind: .caution,
                    title: "Tree changed",
                    detail: "\(stale.count) stale and \(recycled.count) recycled PID\(stale.count + recycled.count == 1 ? "" : "s") were excluded."
                )
            )
        }
        if let metadata = plan.familyMetadata {
            if metadata.scoreLevel >= .hot || metadata.forecastState >= .leaking {
                output.append(
                    KillDecisionEvidence(
                        kind: .positive,
                        title: "High-risk family",
                        detail: "\(metadata.devKindLabel) is \(metadata.scoreLevel.label.lowercased()) with forecast \(metadata.forecastState.label.lowercased())."
                    )
                )
            }
            if metadata.isBackgroundOrOrphan {
                output.append(
                    KillDecisionEvidence(
                        kind: .positive,
                        title: "Background candidate",
                        detail: "The root appears orphaned or backgrounded, which raises kill confidence."
                    )
                )
            }
            if metadata.devKindLabel.localizedCaseInsensitiveContains("build") && metadata.scoreLevel < .critical {
                output.append(
                    KillDecisionEvidence(
                        kind: .caution,
                        title: "Active build caution",
                        detail: "This looks like a build tool; inspect before interrupting unless it is stale."
                    )
                )
            }
        }
        return output
    }
}

public struct KillSafetyGate: Sendable {
    public init() {}

    public func readiness(hasTargets: Bool, evidence: [KillDecisionEvidence]) -> KillReadiness {
        guard hasTargets else {
            return .locked
        }
        if evidence.contains(where: { $0.kind == .blocking }) {
            return .locked
        }
        if evidence.contains(where: { $0.kind == .caution }) {
            return .caution
        }
        return .ready
    }
}

public struct KillReadinessScorer: Sendable {
    public init() {}

    public func score(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget]
    ) -> KillReadinessScore {
        var reasons: [String] = []
        guard !targets.isEmpty else {
            return KillReadinessScore(
                readiness: .locked,
                reasons: ["No owned live process identities matched the selected family tree."]
            )
        }

        var readiness: KillReadiness = .ready
        if !locked.isEmpty {
            readiness = .caution
            reasons.append("\(locked.count) protected or foreign process\(locked.count == 1 ? "" : "es") will be skipped.")
        }
        if !stale.isEmpty || !recycled.isEmpty {
            readiness = .caution
            reasons.append("Stale or recycled PIDs were detected and excluded.")
        }
        if let metadata = plan.familyMetadata {
            if metadata.scoreLevel >= .hot || metadata.forecastState >= .leaking {
                reasons.append("\(metadata.displayName) is \(metadata.scoreLevel.label.lowercased()) with score \(Int(metadata.scoreValue.rounded())).")
            }
            if metadata.isBackgroundOrOrphan {
                reasons.append("Root appears backgrounded or orphaned.")
            }
            if metadata.childCount > 0 {
                reasons.append("\(metadata.childCount) owned descendant\(metadata.childCount == 1 ? "" : "s") in the selected family.")
            }
        }
        if reasons.isEmpty {
            reasons.append("All targets are owned, live, and identity-verified.")
        }

        return KillReadinessScore(readiness: readiness, reasons: reasons)
    }
}

public struct KillAttempt: Identifiable, Equatable, Sendable {
    public var id: String { "\(pid)-\(signal)-\(stage)" }

    public let pid: Int32
    public let signal: Int32
    public let signalName: String
    public let stage: String
    public let succeeded: Bool
    public let message: String

    public init(pid: Int32, signal: Int32, stage: String, succeeded: Bool, message: String = "") {
        self.pid = pid
        self.signal = signal
        self.signalName = KillAttempt.name(for: signal)
        self.stage = stage
        self.succeeded = succeeded
        self.message = message
    }

    private static func name(for signal: Int32) -> String {
        switch signal {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        default: "Signal \(signal)"
        }
    }
}

public enum KillLiveState: String, Codable, Sendable {
    case live
    case exited
    case recycled
    case locked
    case unknown
}

public struct KillVerificationPass: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(stage)-\(Int(elapsedMilliseconds.rounded()))-\(sampledAt.timeIntervalSince1970)" }

    public let stage: String
    public let sampledAt: Date
    public let sampleMilliseconds: Double
    public let elapsedMilliseconds: Double
    public let livePIDs: [Int32]
    public let recycledPIDs: [Int32]
    public let exitedPIDs: [Int32]

    public init(
        stage: String,
        sampledAt: Date = Date(),
        sampleMilliseconds: Double = 0,
        elapsedMilliseconds: Double = 0,
        livePIDs: [Int32],
        recycledPIDs: [Int32],
        exitedPIDs: [Int32]
    ) {
        self.stage = stage
        self.sampledAt = sampledAt
        self.sampleMilliseconds = sampleMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.livePIDs = livePIDs.sorted()
        self.recycledPIDs = recycledPIDs.sorted()
        self.exitedPIDs = exitedPIDs.sorted()
    }
}

public struct KillOutcomeClassifier: Sendable {
    public init() {}

    public func classify(target: KillTarget, report: KillReport) -> KillTarget {
        if report.survivorPIDs.contains(target.pid) {
            return target.updating(state: .survived, reason: "Still alive after verification")
        }
        if report.forcedPIDs.contains(target.pid) {
            return target.updating(state: .forceKilled, reason: "Required SIGKILL")
        }
        if report.recycledPIDs.contains(target.pid) {
            return target.updating(state: .recycled, reason: "PID changed identity during kill")
        }
        if report.exitedBeforeSignalPIDs.contains(target.pid) {
            return target.updating(state: .exitedBeforeSignal, reason: "Exited before the signal landed")
        }
        if report.gracefulPIDs.contains(target.pid) {
            return target.updating(state: .terminated, reason: "Accepted graceful termination")
        }
        if report.deniedPIDs.contains(target.pid) {
            return target.updating(state: .locked, reason: "Signal denied")
        }
        if report.stalePIDs.contains(target.pid) {
            return target.updating(state: .stale, reason: "Identity disappeared")
        }
        return target.updating(state: .failed, reason: "No terminal status")
    }
}

public struct KillExecutionTimeline: Equatable, Sendable {
    public let preflightMilliseconds: Double
    public let signalMilliseconds: Double
    public let verificationMilliseconds: Double
    public let totalMilliseconds: Double

    public static let empty = KillExecutionTimeline(
        preflightMilliseconds: 0,
        signalMilliseconds: 0,
        verificationMilliseconds: 0,
        totalMilliseconds: 0
    )

    public init(
        preflightMilliseconds: Double,
        signalMilliseconds: Double,
        verificationMilliseconds: Double,
        totalMilliseconds: Double
    ) {
        self.preflightMilliseconds = preflightMilliseconds
        self.signalMilliseconds = signalMilliseconds
        self.verificationMilliseconds = verificationMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

public struct KillPreview: Equatable, Sendable {
    public let displayName: String
    public let rootPID: Int32
    public let targetIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let deniedPIDs: [Int32]
    public let stalePIDs: [Int32]
    public let recycledPIDs: [Int32]
    public let forceKillDelay: TimeInterval
    public let targets: [KillTarget]
    public let lockedTargets: [KillTarget]
    public let staleTargets: [KillTarget]
    public let recycledTargets: [KillTarget]
    public let readiness: KillReadiness
    public let readinessReasons: [String]
    public let estimatedMemoryReclaimBytes: UInt64
    public let estimatedCPUReclaimPercent: Double
    public let preflightMilliseconds: Double
    public let usedCheapSnapshot: Bool
    public let reclaimEstimate: KillReclaimEstimate
    public let decisionEvidence: [KillDecisionEvidence]
    public let forcePolicyText: String
    public let scopePreview: KillScopePreview
    public let strategyRecommendation: KillStrategyRecommendation
    public let targetDiff: KillTargetDiff
    public let previewReportText: String
    public let decisionScore: KillDecisionScore
    public let whyKillEvidence: [KillDecisionFactor]
    public let whyWaitEvidence: [KillDecisionFactor]
    public let targetConversionCount: Int
    public let cacheStatus: KillSnapshotCacheStatus
    public let strategyProfile: KillStrategyProfile
    public let performanceReport: KillPerformanceReport
    public let strategySimulation: KillStrategySimulation
    public let watcherAvailable: Bool
    public let arenaStats: KillGraphArenaStats
    public let calibratedGracefulSuccess: Double
    public let calibratedForceProbability: Double
    public let calibratedSurvivorRisk: Double
    public let recommendedGraceSeconds: TimeInterval
    public let verificationPlanText: String

    public var targetPIDs: [Int32] {
        targetIdentities.map(\.pid)
    }

    public var expectedGracefulSuccess: Double {
        calibratedGracefulSuccess
    }

    public var forceProbability: Double {
        calibratedForceProbability
    }

    public var survivorRisk: Double {
        calibratedSurvivorRisk
    }

    public var canKill: Bool {
        !targetIdentities.isEmpty && readiness != .locked
    }

    public var riskSummary: String {
        if !canKill {
            return "No owned live processes match this kill plan."
        }
        if readiness == .caution {
            let skipped = Set(protectedPIDs + deniedPIDs + stalePIDs + recycledPIDs).count
            return "\(targetPIDs.count) owned target\(targetPIDs.count == 1 ? "" : "s"), \(skipped) locked or stale skipped."
        }
        return "\(targetPIDs.count) owned target\(targetPIDs.count == 1 ? "" : "s") ready."
    }

    public init(
        displayName: String,
        rootPID: Int32,
        targetIdentities: [ProcessIdentity],
        protectedPIDs: [Int32],
        deniedPIDs: [Int32],
        stalePIDs: [Int32],
        recycledPIDs: [Int32],
        forceKillDelay: TimeInterval,
        targets: [KillTarget] = [],
        lockedTargets: [KillTarget] = [],
        staleTargets: [KillTarget] = [],
        recycledTargets: [KillTarget] = [],
        readiness: KillReadiness = .ready,
        readinessReasons: [String] = [],
        estimatedMemoryReclaimBytes: UInt64 = 0,
        estimatedCPUReclaimPercent: Double = 0,
        preflightMilliseconds: Double = 0,
        usedCheapSnapshot: Bool = false,
        reclaimEstimate: KillReclaimEstimate = .empty,
        decisionEvidence: [KillDecisionEvidence] = [],
        forcePolicyText: String = "SIGTERM, verify, then SIGKILL surviving same-identity targets",
        scopePreview: KillScopePreview = .empty,
        strategyRecommendation: KillStrategyRecommendation = .standard,
        targetDiff: KillTargetDiff = .empty,
        previewReportText: String = "",
        decisionScore: KillDecisionScore = .empty,
        whyKillEvidence: [KillDecisionFactor] = [],
        whyWaitEvidence: [KillDecisionFactor] = [],
        targetConversionCount: Int = 0,
        cacheStatus: KillSnapshotCacheStatus = .none,
        strategyProfile: KillStrategyProfile = .standard,
        performanceReport: KillPerformanceReport = .empty,
        strategySimulation: KillStrategySimulation = .standard,
        watcherAvailable: Bool = false,
        arenaStats: KillGraphArenaStats = .empty,
        calibratedGracefulSuccess: Double? = nil,
        calibratedForceProbability: Double? = nil,
        calibratedSurvivorRisk: Double? = nil,
        recommendedGraceSeconds: TimeInterval? = nil,
        verificationPlanText: String = "Confirm uses a complete arena; pre-force and final verification use target-only reads unless watcher drift asks for a fresh arena."
    ) {
        self.displayName = displayName
        self.rootPID = rootPID
        self.targetIdentities = targetIdentities
        self.protectedPIDs = protectedPIDs
        self.deniedPIDs = deniedPIDs
        self.stalePIDs = stalePIDs
        self.recycledPIDs = recycledPIDs
        self.forceKillDelay = forceKillDelay
        self.targets = targets
        self.lockedTargets = lockedTargets
        self.staleTargets = staleTargets
        self.recycledTargets = recycledTargets
        self.readiness = readiness
        self.readinessReasons = readinessReasons
        self.estimatedMemoryReclaimBytes = estimatedMemoryReclaimBytes
        self.estimatedCPUReclaimPercent = estimatedCPUReclaimPercent
        self.preflightMilliseconds = preflightMilliseconds
        self.usedCheapSnapshot = usedCheapSnapshot
        self.reclaimEstimate = reclaimEstimate
        self.decisionEvidence = decisionEvidence
        self.forcePolicyText = forcePolicyText
        self.scopePreview = scopePreview
        self.strategyRecommendation = strategyRecommendation
        self.targetDiff = targetDiff
        self.decisionScore = decisionScore
        self.whyKillEvidence = whyKillEvidence
        self.whyWaitEvidence = whyWaitEvidence
        self.targetConversionCount = targetConversionCount
        self.cacheStatus = cacheStatus
        self.strategyProfile = strategyProfile
        self.performanceReport = performanceReport
        self.strategySimulation = strategySimulation
        self.watcherAvailable = watcherAvailable
        self.arenaStats = arenaStats
        self.calibratedGracefulSuccess = min(1, max(0, calibratedGracefulSuccess ?? strategySimulation.expectedGracefulSuccess))
        self.calibratedForceProbability = min(1, max(0, calibratedForceProbability ?? strategySimulation.forceProbability))
        self.calibratedSurvivorRisk = min(1, max(0, calibratedSurvivorRisk ?? strategySimulation.survivorRisk))
        self.recommendedGraceSeconds = max(0, recommendedGraceSeconds ?? strategyProfile.verificationSchedule.graceSeconds)
        self.verificationPlanText = verificationPlanText
        self.previewReportText = previewReportText.isEmpty ? Self.makePreviewReport(
            displayName: displayName,
            readiness: readiness,
            targets: targets,
            lockedTargets: lockedTargets,
            staleTargets: staleTargets,
            recycledTargets: recycledTargets,
            reclaimEstimate: reclaimEstimate,
            strategy: strategyRecommendation,
            scope: scopePreview,
            recommendedGraceSeconds: max(0, recommendedGraceSeconds ?? strategyProfile.verificationSchedule.graceSeconds),
            verificationPlanText: verificationPlanText
        ) : previewReportText
    }

    private static func makePreviewReport(
        displayName: String,
        readiness: KillReadiness,
        targets: [KillTarget],
        lockedTargets: [KillTarget],
        staleTargets: [KillTarget],
        recycledTargets: [KillTarget],
        reclaimEstimate: KillReclaimEstimate,
        strategy: KillStrategyRecommendation,
        scope: KillScopePreview,
        recommendedGraceSeconds: TimeInterval,
        verificationPlanText: String
    ) -> String {
        [
            "Ghost Process Sniper Kill Preview",
            "Family: \(displayName)",
            "Readiness: \(readiness.label)",
            "Strategy: \(strategy.strategy.label) (\(Int((strategy.confidence * 100).rounded()))%)",
            "Recommended grace: \(String(format: "%.2f", recommendedGraceSeconds))s",
            "Verification: \(verificationPlanText)",
            "Scope: \(scope.scope.label) - \(scope.summary)",
            "Will signal: \(targets.map { String($0.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Will skip: \((lockedTargets + staleTargets + recycledTargets).map { String($0.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Nearby: \(scope.nearbyCandidates.map { String($0.identity.pid) }.joined(separator: ", ").ifEmpty("none"))",
            "Estimated reclaim: \(RadarFormat.bytes(reclaimEstimate.memoryBytes)), \(Int(reclaimEstimate.cpuPercent.rounded()))% CPU"
        ].joined(separator: "\n")
    }
}

public struct KillOperationRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: KillOperationID
    public let signatureID: String?
    public let displayName: String
    public let rootPID: Int32
    public let summary: String
    public let estimatedMemoryReclaimBytes: UInt64
    public let realizedMemoryReclaimBytes: UInt64
    public let gracefulCount: Int
    public let forcedCount: Int
    public let survivorCount: Int
    public let lockedCount: Int
    public let staleCount: Int
    public let recycledCount: Int
    public let durationMilliseconds: Double
    public let createdAt: Date
    public let strategy: KillStrategy
    public let scope: KillScope

    public init(
        id: KillOperationID,
        signatureID: String?,
        displayName: String,
        rootPID: Int32,
        summary: String,
        estimatedMemoryReclaimBytes: UInt64,
        realizedMemoryReclaimBytes: UInt64,
        gracefulCount: Int,
        forcedCount: Int,
        survivorCount: Int,
        lockedCount: Int,
        staleCount: Int,
        recycledCount: Int,
        durationMilliseconds: Double,
        createdAt: Date,
        strategy: KillStrategy = .standard,
        scope: KillScope = .ownedFamily
    ) {
        self.id = id
        self.signatureID = signatureID
        self.displayName = displayName
        self.rootPID = rootPID
        self.summary = summary
        self.estimatedMemoryReclaimBytes = estimatedMemoryReclaimBytes
        self.realizedMemoryReclaimBytes = realizedMemoryReclaimBytes
        self.gracefulCount = gracefulCount
        self.forcedCount = forcedCount
        self.survivorCount = survivorCount
        self.lockedCount = lockedCount
        self.staleCount = staleCount
        self.recycledCount = recycledCount
        self.durationMilliseconds = durationMilliseconds
        self.createdAt = createdAt
        self.strategy = strategy
        self.scope = scope
    }

    public init(report: KillReport, family: ProcessFamily?, createdAt: Date = Date()) {
        self.init(
            id: report.operationID,
            signatureID: family?.signature.id,
            displayName: report.displayName,
            rootPID: report.rootPID,
            summary: report.summary,
            estimatedMemoryReclaimBytes: report.estimatedMemoryReclaimBytes,
            realizedMemoryReclaimBytes: report.realizedMemoryReclaimBytes,
            gracefulCount: report.gracefulPIDs.count,
            forcedCount: report.forcedPIDs.count,
            survivorCount: report.survivorPIDs.count,
            lockedCount: report.deniedPIDs.count,
            staleCount: report.stalePIDs.count,
            recycledCount: report.recycledPIDs.count,
            durationMilliseconds: report.timeline.totalMilliseconds,
            createdAt: createdAt,
            strategy: report.strategyUsed,
            scope: report.scopeUsed
        )
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
