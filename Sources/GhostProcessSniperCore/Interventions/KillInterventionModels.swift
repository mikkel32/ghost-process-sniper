import Darwin
import Foundation

public struct KillSnapshotCachePolicy: Equatable, Sendable {
    public let allowsRead: Bool
    public let allowsWrite: Bool
    public let ttlSeconds: TimeInterval

    public static let disabled = KillSnapshotCachePolicy(allowsRead: false, allowsWrite: false, ttlSeconds: 0)
    public static let preview = KillSnapshotCachePolicy(allowsRead: true, allowsWrite: true, ttlSeconds: 0.85)

    public init(allowsRead: Bool, allowsWrite: Bool, ttlSeconds: TimeInterval) {
        self.allowsRead = allowsRead
        self.allowsWrite = allowsWrite
        self.ttlSeconds = max(0, ttlSeconds)
    }
}

public enum KillSnapshotCacheStatus: String, Codable, Sendable {
    case none
    case hit
    case miss
    case bypassed
    case stored
    case expired

    public var label: String {
        switch self {
        case .none: "No cache"
        case .hit: "Cache hit"
        case .miss: "Cache miss"
        case .bypassed: "Cache bypassed"
        case .stored: "Cache stored"
        case .expired: "Cache expired"
        }
    }
}

public struct KillSnapshotConversionBudget: Equatable, Sendable {
    public let maxConvertedProcesses: Int

    public static let targetsOnly = KillSnapshotConversionBudget(maxConvertedProcesses: 96)
    public static let compatibility = KillSnapshotConversionBudget(maxConvertedProcesses: 4_096)

    public init(maxConvertedProcesses: Int) {
        self.maxConvertedProcesses = max(0, maxConvertedProcesses)
    }
}

public struct KillSnapshotBudget: Equatable, Sendable {
    public let targetMilliseconds: Double
    public let maxHeavyMetricReads: Int

    public static let preview = KillSnapshotBudget(targetMilliseconds: 12, maxHeavyMetricReads: 64)
    public static let confirm = KillSnapshotBudget(targetMilliseconds: 16, maxHeavyMetricReads: 96)
    public static let verify = KillSnapshotBudget(targetMilliseconds: 10, maxHeavyMetricReads: 96)

    public init(targetMilliseconds: Double, maxHeavyMetricReads: Int) {
        self.targetMilliseconds = max(1, targetMilliseconds)
        self.maxHeavyMetricReads = max(0, maxHeavyMetricReads)
    }
}

public enum KillVerificationMode: String, Codable, Sendable {
    case completeArena
    case targetOnly
    case eventTriggeredComplete

    public var label: String {
        switch self {
        case .completeArena: "complete arena"
        case .targetOnly: "target-only"
        case .eventTriggeredComplete: "event-triggered arena"
        }
    }
}

public enum KillScope: String, Codable, CaseIterable, Sendable {
    case ownedFamily
    case singleRoot
    case ownedProcessGroupPreview

    public var label: String {
        switch self {
        case .ownedFamily: "Owned family"
        case .singleRoot: "Root only"
        case .ownedProcessGroupPreview: "Process group preview"
        }
    }
}

public struct KillSnapshotRequest: Equatable, Sendable {
    public let policy: KillSnapshotPolicy
    public let rootIdentity: ProcessIdentity?
    public let targetIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let scope: KillScope
    public let budget: KillSnapshotBudget
    public let includeHeavyMetricsForTargets: Bool
    public let cachePolicy: KillSnapshotCachePolicy
    public let requiresCompleteGraph: Bool
    public let conversionBudget: KillSnapshotConversionBudget
    public let verificationMode: KillVerificationMode

    public init(
        policy: KillSnapshotPolicy,
        rootIdentity: ProcessIdentity? = nil,
        targetIdentities: [ProcessIdentity] = [],
        protectedPIDs: [Int32] = [],
        scope: KillScope = .ownedFamily,
        budget: KillSnapshotBudget? = nil,
        includeHeavyMetricsForTargets: Bool = true,
        cachePolicy: KillSnapshotCachePolicy? = nil,
        requiresCompleteGraph: Bool = true,
        conversionBudget: KillSnapshotConversionBudget? = nil,
        verificationMode: KillVerificationMode = .completeArena
    ) {
        self.policy = policy
        self.rootIdentity = rootIdentity
        self.targetIdentities = targetIdentities
        self.protectedPIDs = protectedPIDs
        self.scope = scope
        self.budget = budget ?? Self.defaultBudget(for: policy)
        self.includeHeavyMetricsForTargets = includeHeavyMetricsForTargets
        self.cachePolicy = cachePolicy ?? (policy == .preflight ? .preview : .disabled)
        self.requiresCompleteGraph = requiresCompleteGraph
        self.conversionBudget = conversionBudget ?? (rootIdentity == nil ? .compatibility : .targetsOnly)
        self.verificationMode = verificationMode
    }

    public init(policy: KillSnapshotPolicy) {
        self.init(
            policy: policy,
            includeHeavyMetricsForTargets: false,
            cachePolicy: .disabled,
            requiresCompleteGraph: true,
            conversionBudget: .compatibility,
            verificationMode: .completeArena
        )
    }

    public init(
        plan: KillPlan,
        policy: KillSnapshotPolicy,
        verificationMode: KillVerificationMode = .completeArena
    ) {
        self.init(
            policy: policy,
            rootIdentity: plan.rootIdentity,
            targetIdentities: plan.targetIdentities,
            protectedPIDs: plan.protectedPIDs,
            scope: plan.scope,
            includeHeavyMetricsForTargets: true,
            cachePolicy: policy == .preflight ? .preview : .disabled,
            requiresCompleteGraph: verificationMode != .targetOnly,
            conversionBudget: .targetsOnly,
            verificationMode: verificationMode
        )
    }

    private static func defaultBudget(for policy: KillSnapshotPolicy) -> KillSnapshotBudget {
        switch policy {
        case .preflight: .preview
        case .confirm: .confirm
        case .verify: .verify
        }
    }
}

public struct KillPerformanceReport: Codable, Equatable, Sendable {
    public let snapshotMilliseconds: Double
    public let graphReadCount: Int
    public let heavyMetricReadCount: Int
    public let targetConversionCount: Int
    public let cacheStatus: KillSnapshotCacheStatus
    public let didHitBudget: Bool
    public let skippedOptionalWorkCount: Int
    public let eventCoalescingCount: Int
    public let arenaStats: KillGraphArenaStats
    public let watcherHintCount: Int
    public let earlyGraceExitCount: Int
    public let targetOnlyVerificationCount: Int
    public let completeVerificationCount: Int
    public let eventTriggeredVerificationCount: Int

    public static let empty = KillPerformanceReport(
        snapshotMilliseconds: 0,
        graphReadCount: 0,
        heavyMetricReadCount: 0,
        targetConversionCount: 0,
        cacheStatus: .none,
        didHitBudget: false,
        skippedOptionalWorkCount: 0,
        eventCoalescingCount: 0,
        arenaStats: .empty,
        watcherHintCount: 0,
        earlyGraceExitCount: 0,
        targetOnlyVerificationCount: 0,
        completeVerificationCount: 0,
        eventTriggeredVerificationCount: 0
    )

    public init(
        snapshotMilliseconds: Double,
        graphReadCount: Int,
        heavyMetricReadCount: Int,
        targetConversionCount: Int,
        cacheStatus: KillSnapshotCacheStatus,
        didHitBudget: Bool,
        skippedOptionalWorkCount: Int = 0,
        eventCoalescingCount: Int = 0,
        arenaStats: KillGraphArenaStats = .empty,
        watcherHintCount: Int = 0,
        earlyGraceExitCount: Int = 0,
        targetOnlyVerificationCount: Int = 0,
        completeVerificationCount: Int = 0,
        eventTriggeredVerificationCount: Int = 0
    ) {
        self.snapshotMilliseconds = snapshotMilliseconds
        self.graphReadCount = graphReadCount
        self.heavyMetricReadCount = heavyMetricReadCount
        self.targetConversionCount = targetConversionCount
        self.cacheStatus = cacheStatus
        self.didHitBudget = didHitBudget
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
        self.eventCoalescingCount = eventCoalescingCount
        self.arenaStats = arenaStats
        self.watcherHintCount = watcherHintCount
        self.earlyGraceExitCount = earlyGraceExitCount
        self.targetOnlyVerificationCount = targetOnlyVerificationCount
        self.completeVerificationCount = completeVerificationCount
        self.eventTriggeredVerificationCount = eventTriggeredVerificationCount
    }

    public init(snapshot: KillProcessSnapshot, eventCoalescingCount: Int = 0) {
        self.init(
            snapshotMilliseconds: snapshot.elapsedMilliseconds,
            graphReadCount: snapshot.graphReadCount,
            heavyMetricReadCount: snapshot.heavyMetricReadCount,
            targetConversionCount: snapshot.targetConversionCount,
            cacheStatus: snapshot.cacheStatus,
            didHitBudget: snapshot.didHitBudget,
            skippedOptionalWorkCount: snapshot.skippedOptionalWorkCount,
            eventCoalescingCount: eventCoalescingCount,
            arenaStats: snapshot.arena?.stats ?? .empty
        )
    }
}

public struct KillProcessLite: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { identity }

    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let ownerName: String
    public let name: String
    public let status: UInt32
    public let flags: UInt32
    public let processGroupID: Int32
    public let openFileCount: Int
    public let residentMemoryBytes: UInt64
    public let physicalFootprintBytes: UInt64
    public let virtualMemoryBytes: UInt64
    public let cpuPercent: Double
    public let totalProcessorSeconds: TimeInterval
    public let threadCount: Int
    public let isSystemProcess: Bool
    public let didReadHeavyMetrics: Bool
    public let sampledAt: Date

    public var pid: Int32 { identity.pid }
    public var memoryForScoringBytes: UInt64 { max(physicalFootprintBytes, residentMemoryBytes) }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        ownerName: String,
        name: String,
        status: UInt32,
        flags: UInt32,
        processGroupID: Int32,
        openFileCount: Int,
        residentMemoryBytes: UInt64 = 0,
        physicalFootprintBytes: UInt64 = 0,
        virtualMemoryBytes: UInt64 = 0,
        cpuPercent: Double = 0,
        totalProcessorSeconds: TimeInterval = 0,
        threadCount: Int = 0,
        isSystemProcess: Bool = false,
        didReadHeavyMetrics: Bool = false,
        sampledAt: Date = Date()
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.ownerName = ownerName
        self.name = name
        self.status = status
        self.flags = flags
        self.processGroupID = processGroupID
        self.openFileCount = openFileCount
        self.residentMemoryBytes = residentMemoryBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.virtualMemoryBytes = virtualMemoryBytes
        self.cpuPercent = cpuPercent
        self.totalProcessorSeconds = totalProcessorSeconds
        self.threadCount = threadCount
        self.isSystemProcess = isSystemProcess
        self.didReadHeavyMetrics = didReadHeavyMetrics
        self.sampledAt = sampledAt
    }

    public init(process: ProcessMetrics, status: UInt32 = 0, flags: UInt32 = 0, processGroupID: Int32 = 0, openFileCount: Int = 0) {
        self.init(
            identity: process.identity,
            parentPID: process.parentPID,
            userID: process.userID,
            ownerName: process.ownerName,
            name: process.name,
            status: status,
            flags: flags,
            processGroupID: processGroupID,
            openFileCount: openFileCount,
            residentMemoryBytes: process.residentMemoryBytes,
            physicalFootprintBytes: process.physicalFootprintBytes,
            virtualMemoryBytes: process.virtualMemoryBytes,
            cpuPercent: process.cpuPercent,
            totalProcessorSeconds: process.totalProcessorSeconds,
            threadCount: process.threadCount,
            isSystemProcess: process.isSystemProcess,
            didReadHeavyMetrics: true,
            sampledAt: process.sampledAt
        )
    }

    public func updatingHeavyMetrics(
        residentMemoryBytes: UInt64,
        physicalFootprintBytes: UInt64,
        virtualMemoryBytes: UInt64,
        totalProcessorSeconds: TimeInterval,
        threadCount: Int,
        isSystemProcess: Bool
    ) -> KillProcessLite {
        KillProcessLite(
            identity: identity,
            parentPID: parentPID,
            userID: userID,
            ownerName: ownerName,
            name: name,
            status: status,
            flags: flags,
            processGroupID: processGroupID,
            openFileCount: openFileCount,
            residentMemoryBytes: residentMemoryBytes,
            physicalFootprintBytes: physicalFootprintBytes,
            virtualMemoryBytes: virtualMemoryBytes,
            totalProcessorSeconds: totalProcessorSeconds,
            threadCount: threadCount,
            isSystemProcess: isSystemProcess,
            didReadHeavyMetrics: true,
            sampledAt: sampledAt
        )
    }

    public func asProcessMetrics() -> ProcessMetrics {
        ProcessMetrics(
            identity: identity,
            parentPID: parentPID,
            userID: userID,
            ownerName: ownerName,
            name: name,
            executablePath: "",
            commandLine: name,
            residentMemoryBytes: residentMemoryBytes,
            physicalFootprintBytes: physicalFootprintBytes,
            virtualMemoryBytes: virtualMemoryBytes,
            cpuPercent: cpuPercent,
            totalProcessorSeconds: totalProcessorSeconds,
            threadCount: threadCount,
            isSystemProcess: isSystemProcess,
            sampledAt: sampledAt,
            forensics: .unavailable(reason: didReadHeavyMetrics ? "kill graph target metrics" : "kill graph lite")
        )
    }
}

public struct KillProcessGraph: Equatable, Sendable {
    public let processes: [KillProcessLite]
    public let sampledAt: Date
    public let elapsedMilliseconds: Double
    public let graphReadCount: Int
    public let heavyMetricReadCount: Int
    public let didHitBudget: Bool
    public let usedBSDInfoPath: Bool

    public static let empty = KillProcessGraph(
        processes: [],
        sampledAt: Date(timeIntervalSince1970: 0),
        elapsedMilliseconds: 0,
        graphReadCount: 0,
        heavyMetricReadCount: 0,
        didHitBudget: false,
        usedBSDInfoPath: true
    )

    public init(
        processes: [KillProcessLite],
        sampledAt: Date,
        elapsedMilliseconds: Double,
        graphReadCount: Int,
        heavyMetricReadCount: Int,
        didHitBudget: Bool,
        usedBSDInfoPath: Bool
    ) {
        self.processes = processes
        self.sampledAt = sampledAt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.graphReadCount = graphReadCount
        self.heavyMetricReadCount = heavyMetricReadCount
        self.didHitBudget = didHitBudget
        self.usedBSDInfoPath = usedBSDInfoPath
    }

    public var metrics: [ProcessMetrics] {
        processes.map { $0.asProcessMetrics() }
    }

    public func process(for identity: ProcessIdentity) -> KillProcessLite? {
        processes.first { $0.identity == identity }
    }

    public func descendants(of rootIdentity: ProcessIdentity) -> [(process: KillProcessLite, depth: Int)] {
        guard let root = process(for: rootIdentity) else {
            return []
        }
        let childrenByPID = Dictionary(grouping: processes, by: \.parentPID)
        var output: [(KillProcessLite, Int)] = []
        var stack: [(KillProcessLite, Int)] = [(root, 0)]
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

    public func processGroupNeighbors(rootIdentity: ProcessIdentity, currentUserID: UInt32, excluding identities: Set<ProcessIdentity>) -> [KillProcessLite] {
        guard let root = process(for: rootIdentity), root.processGroupID > 0 else {
            return []
        }
        return processes
            .filter { $0.processGroupID == root.processGroupID && $0.userID == currentUserID && !identities.contains($0.identity) }
            .sorted { $0.pid < $1.pid }
    }
}

public struct KillCollateralCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(identity.pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)" }

    public let identity: ProcessIdentity
    public let name: String
    public let processGroupID: Int32
    public let memoryBytes: UInt64
    public let reason: String

    public init(identity: ProcessIdentity, name: String, processGroupID: Int32, memoryBytes: UInt64, reason: String) {
        self.identity = identity
        self.name = name
        self.processGroupID = processGroupID
        self.memoryBytes = memoryBytes
        self.reason = reason
    }

    public init(process: KillProcessLite, reason: String) {
        self.init(
            identity: process.identity,
            name: process.name,
            processGroupID: process.processGroupID,
            memoryBytes: process.memoryForScoringBytes,
            reason: reason
        )
    }
}

public struct KillTargetDiff: Codable, Equatable, Sendable {
    public let addedPIDs: [Int32]
    public let exitedPIDs: [Int32]
    public let recycledPIDs: [Int32]
    public let reparentedPIDs: [Int32]
    public let survivorPIDs: [Int32]

    public static let empty = KillTargetDiff(addedPIDs: [], exitedPIDs: [], recycledPIDs: [], reparentedPIDs: [], survivorPIDs: [])

    public init(addedPIDs: [Int32], exitedPIDs: [Int32], recycledPIDs: [Int32], reparentedPIDs: [Int32], survivorPIDs: [Int32]) {
        self.addedPIDs = addedPIDs.sorted()
        self.exitedPIDs = exitedPIDs.sorted()
        self.recycledPIDs = recycledPIDs.sorted()
        self.reparentedPIDs = reparentedPIDs.sorted()
        self.survivorPIDs = survivorPIDs.sorted()
    }

    public var isEmpty: Bool {
        addedPIDs.isEmpty && exitedPIDs.isEmpty && recycledPIDs.isEmpty && reparentedPIDs.isEmpty && survivorPIDs.isEmpty
    }

    public var summary: String {
        if isEmpty {
            return "No target drift detected."
        }
        var parts: [String] = []
        if !addedPIDs.isEmpty { parts.append("+\(addedPIDs.count) new") }
        if !exitedPIDs.isEmpty { parts.append("\(exitedPIDs.count) exited") }
        if !recycledPIDs.isEmpty { parts.append("\(recycledPIDs.count) recycled") }
        if !reparentedPIDs.isEmpty { parts.append("\(reparentedPIDs.count) reparented") }
        if !survivorPIDs.isEmpty { parts.append("\(survivorPIDs.count) survived") }
        return parts.joined(separator: ", ")
    }
}

public struct KillGraphDelta: Codable, Equatable, Sendable {
    public let previewTargetPIDs: [Int32]
    public let confirmTargetPIDs: [Int32]
    public let finalSurvivorPIDs: [Int32]
    public let drift: KillTargetDiff

    public static let empty = KillGraphDelta(
        previewTargetPIDs: [],
        confirmTargetPIDs: [],
        finalSurvivorPIDs: [],
        drift: .empty
    )

    public init(
        previewTargetPIDs: [Int32],
        confirmTargetPIDs: [Int32],
        finalSurvivorPIDs: [Int32],
        drift: KillTargetDiff
    ) {
        self.previewTargetPIDs = previewTargetPIDs.sorted()
        self.confirmTargetPIDs = confirmTargetPIDs.sorted()
        self.finalSurvivorPIDs = finalSurvivorPIDs.sorted()
        self.drift = drift
    }

    public var summary: String {
        let added = Set(confirmTargetPIDs).subtracting(previewTargetPIDs)
        let removed = Set(previewTargetPIDs).subtracting(confirmTargetPIDs)
        if added.isEmpty, removed.isEmpty, finalSurvivorPIDs.isEmpty, drift.isEmpty {
            return "No intervention graph drift."
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("+\(added.count) confirm") }
        if !removed.isEmpty { parts.append("-\(removed.count) confirm") }
        if !finalSurvivorPIDs.isEmpty { parts.append("\(finalSurvivorPIDs.count) survivors") }
        if !drift.isEmpty { parts.append(drift.summary) }
        return parts.joined(separator: ", ")
    }
}

public struct KillScopePreview: Codable, Equatable, Sendable {
    public let scope: KillScope
    public let targetCount: Int
    public let lockedCount: Int
    public let nearbyCandidates: [KillCollateralCandidate]
    public let drift: KillTargetDiff
    public let summary: String

    public static let empty = KillScopePreview(
        scope: .ownedFamily,
        targetCount: 0,
        lockedCount: 0,
        nearbyCandidates: [],
        drift: .empty,
        summary: "No scope preview yet."
    )

    public init(
        scope: KillScope,
        targetCount: Int,
        lockedCount: Int,
        nearbyCandidates: [KillCollateralCandidate],
        drift: KillTargetDiff = .empty,
        summary: String
    ) {
        self.scope = scope
        self.targetCount = targetCount
        self.lockedCount = lockedCount
        self.nearbyCandidates = nearbyCandidates
        self.drift = drift
        self.summary = summary
    }
}

public enum KillStrategy: String, Codable, CaseIterable, Sendable {
    case standard
    case gentleDevServer
    case stubbornRunaway
    case inspectOnly

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .gentleDevServer: "Gentle dev server"
        case .stubbornRunaway: "Stubborn runaway"
        case .inspectOnly: "Inspect only"
        }
    }

    public func signals(gracefulSignal: Int32 = SIGTERM) -> [Int32] {
        switch self {
        case .standard:
            return [gracefulSignal, SIGKILL]
        case .gentleDevServer:
            return [SIGINT, SIGTERM, SIGKILL]
        case .stubbornRunaway:
            return [SIGTERM, SIGKILL]
        case .inspectOnly:
            return []
        }
    }
}

public enum KillDecisionFactorKind: String, Codable, Sendable {
    case whyKill
    case whyWait
    case blocking
}

public struct KillDecisionFactor: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)-\(title)-\(Int(weight.rounded()))" }

    public let kind: KillDecisionFactorKind
    public let title: String
    public let detail: String
    public let weight: Double

    public init(kind: KillDecisionFactorKind, title: String, detail: String, weight: Double) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.weight = weight
    }
}

public struct KillDecisionScore: Codable, Equatable, Sendable {
    public let value: Double
    public let confidence: Double
    public let factors: [KillDecisionFactor]

    public static let empty = KillDecisionScore(value: 0, confidence: 0, factors: [])

    public init(value: Double, confidence: Double, factors: [KillDecisionFactor]) {
        self.value = min(100, max(0, value))
        self.confidence = min(1, max(0, confidence))
        self.factors = factors
    }

    public var whyKill: [KillDecisionFactor] {
        factors.filter { $0.kind == .whyKill }
    }

    public var whyWait: [KillDecisionFactor] {
        factors.filter { $0.kind == .whyWait || $0.kind == .blocking }
    }
}

public struct KillSignalPhase: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(order)-\(signalName)-\(label)" }

    public let order: Int
    public let label: String
    public let signal: Int32?
    public let waitAfterSeconds: TimeInterval
    public let isForce: Bool

    public var signalName: String {
        guard let signal else {
            return "VERIFY"
        }
        return switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        default: "SIG\(signal)"
        }
    }

    public init(order: Int, label: String, signal: Int32?, waitAfterSeconds: TimeInterval, isForce: Bool) {
        self.order = order
        self.label = label
        self.signal = signal
        self.waitAfterSeconds = max(0, waitAfterSeconds)
        self.isForce = isForce
    }
}

public struct KillVerificationSchedule: Codable, Equatable, Sendable {
    public let graceSeconds: TimeInterval
    public let secondaryGraceSeconds: TimeInterval
    public let settleSeconds: TimeInterval
    public let allowsSkipForce: Bool

    public static let standard = KillVerificationSchedule(
        graceSeconds: 2,
        secondaryGraceSeconds: 0.15,
        settleSeconds: 0.35,
        allowsSkipForce: true
    )

    public init(
        graceSeconds: TimeInterval,
        secondaryGraceSeconds: TimeInterval,
        settleSeconds: TimeInterval,
        allowsSkipForce: Bool
    ) {
        self.graceSeconds = max(0, graceSeconds)
        self.secondaryGraceSeconds = max(0, secondaryGraceSeconds)
        self.settleSeconds = max(0, settleSeconds)
        self.allowsSkipForce = allowsSkipForce
    }
}

public struct KillStrategyProfile: Codable, Equatable, Sendable {
    public let strategy: KillStrategy
    public let confidence: Double
    public let phases: [KillSignalPhase]
    public let verificationSchedule: KillVerificationSchedule
    public let summary: String

    public static let standard = KillStrategyProfile(
        strategy: .standard,
        confidence: 0.65,
        phases: [
            KillSignalPhase(order: 0, label: "Ask target to terminate", signal: SIGTERM, waitAfterSeconds: 2, isForce: false),
            KillSignalPhase(order: 1, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
        ],
        verificationSchedule: .standard,
        summary: "SIGTERM, verify, then SIGKILL same-identity survivors."
    )

    public init(
        strategy: KillStrategy,
        confidence: Double,
        phases: [KillSignalPhase],
        verificationSchedule: KillVerificationSchedule,
        summary: String
    ) {
        self.strategy = strategy
        self.confidence = min(1, max(0, confidence))
        self.phases = phases
        self.verificationSchedule = verificationSchedule
        self.summary = summary
    }
}

public struct KillStrategyRecommendation: Codable, Equatable, Sendable {
    public let strategy: KillStrategy
    public let confidence: Double
    public let reasons: [String]
    public let previewText: String

    public static let standard = KillStrategyRecommendation(
        strategy: .standard,
        confidence: 0.65,
        reasons: ["Default safe intervention profile."],
        previewText: "SIGTERM, verify, then SIGKILL surviving same-identity targets."
    )

    public init(strategy: KillStrategy, confidence: Double, reasons: [String], previewText: String) {
        self.strategy = strategy
        self.confidence = min(1, max(0, confidence))
        self.reasons = reasons
        self.previewText = previewText
    }
}

public enum KillOperationEventKind: String, Codable, Sendable {
    case queued
    case preflight
    case targetUpdated
    case signaled
    case graceWaiting
    case forcePending
    case forceSkipped
    case verified
    case completed
    case failed
}

public struct KillOperationEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let operationID: KillOperationID
    public let kind: KillOperationEventKind
    public let pid: Int32?
    public let signalName: String?
    public let targetState: KillTargetState?
    public let message: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        operationID: KillOperationID,
        kind: KillOperationEventKind,
        pid: Int32? = nil,
        signalName: String? = nil,
        targetState: KillTargetState? = nil,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.operationID = operationID
        self.kind = kind
        self.pid = pid
        self.signalName = signalName
        self.targetState = targetState
        self.message = message
        self.createdAt = createdAt
    }
}

public actor KillOperationControl {
    private var skipForceRequested = false

    public init() {}

    public func requestSkipForce() {
        skipForceRequested = true
    }

    public func shouldSkipForce() -> Bool {
        skipForceRequested
    }
}

public struct KillOperationProgress: Equatable, Sendable {
    public let operationID: KillOperationID
    public var events: [KillOperationEvent]
    public var targetStates: [Int32: KillTargetState]
    public var report: KillReport?

    public init(operationID: KillOperationID, events: [KillOperationEvent] = [], targetStates: [Int32: KillTargetState] = [:], report: KillReport? = nil) {
        self.operationID = operationID
        self.events = events
        self.targetStates = targetStates
        self.report = report
    }

    public var isComplete: Bool {
        report != nil || events.contains { $0.kind == .completed || $0.kind == .failed }
    }

    public mutating func append(_ event: KillOperationEvent) {
        events.append(event)
        if let pid = event.pid, let state = event.targetState {
            targetStates[pid] = state
        }
    }
}

public struct KillOperationProgressViewModel: Equatable, Sendable {
    public let operationID: KillOperationID
    public let stageText: String
    public let targetStates: [Int32: KillTargetState]
    public let latestEvents: [KillOperationEvent]
    public let eventCoalescingCount: Int
    public let isComplete: Bool

    public init(
        progress: KillOperationProgress,
        coalescingWindow: Int = 6,
        eventCoalescingCount: Int = 0
    ) {
        operationID = progress.operationID
        targetStates = progress.targetStates
        latestEvents = Array(progress.events.suffix(max(1, coalescingWindow)))
        self.eventCoalescingCount = eventCoalescingCount
        isComplete = progress.isComplete
        stageText = progress.report?.summary ?? progress.events.last?.message ?? "Preparing intervention"
    }
}

public struct KillHistorySummary: Codable, Equatable, Sendable {
    public let signatureID: String?
    public let operationCount: Int
    public let gracefulSuccessRate: Double
    public let forceRate: Double
    public let survivorRate: Double
    public let averageReclaimBytes: UInt64
    public let commonDenialCount: Int

    public static let empty = KillHistorySummary(
        signatureID: nil,
        operationCount: 0,
        gracefulSuccessRate: 0,
        forceRate: 0,
        survivorRate: 0,
        averageReclaimBytes: 0,
        commonDenialCount: 0
    )

    public init(
        signatureID: String?,
        operationCount: Int,
        gracefulSuccessRate: Double,
        forceRate: Double,
        survivorRate: Double,
        averageReclaimBytes: UInt64,
        commonDenialCount: Int
    ) {
        self.signatureID = signatureID
        self.operationCount = operationCount
        self.gracefulSuccessRate = min(1, max(0, gracefulSuccessRate))
        self.forceRate = min(1, max(0, forceRate))
        self.survivorRate = min(1, max(0, survivorRate))
        self.averageReclaimBytes = averageReclaimBytes
        self.commonDenialCount = commonDenialCount
    }
}

public struct KillOutcomeLearning: Codable, Equatable, Sendable {
    public let history: KillHistorySummary
    public let recommendationHint: String

    public static let empty = KillOutcomeLearning(history: .empty, recommendationHint: "No kill history yet.")

    public init(history: KillHistorySummary, recommendationHint: String) {
        self.history = history
        self.recommendationHint = recommendationHint
    }
}

public actor KillOperationRunner {
    public init() {}

    public func runReport(
        plan: KillPlan,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval = 2,
        control: KillOperationControl = KillOperationControl(),
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        await killer.kill(
            plan: plan,
            forceKillDelay: forceKillDelay,
            skipForceCheck: {
                await control.shouldSkipForce()
            },
            eventSink: eventSink
        )
    }

    public func run(
        plan: KillPlan,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval = 2,
        control: KillOperationControl = KillOperationControl()
    ) -> AsyncStream<KillOperationEvent> {
        AsyncStream { continuation in
            Task {
                let report = await self.runReport(
                    plan: plan,
                    killer: killer,
                    forceKillDelay: forceKillDelay,
                    control: control,
                    eventSink: { event in
                        continuation.yield(event)
                    }
                )
                if report.eventHistory.last?.kind != .completed {
                    continuation.yield(
                        KillOperationEvent(
                            operationID: report.operationID,
                            kind: report.failures.isEmpty ? .completed : .failed,
                            message: report.summary
                        )
                    )
                }
                continuation.finish()
            }
        }
    }
}
