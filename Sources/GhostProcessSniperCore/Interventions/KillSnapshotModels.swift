import Darwin
import Foundation

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

public struct KillSnapshotRequest: Equatable, Sendable {
    public let policy: KillSnapshotPolicy
    public let rootIdentity: ProcessIdentity?
    public let targetIdentities: [ProcessIdentity]
    public let protectedPIDs: [Int32]
    public let scope: KillScope
    public let budget: KillSnapshotBudget
    public let includeHeavyMetricsForTargets: Bool
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
        self.requiresCompleteGraph = requiresCompleteGraph
        self.conversionBudget = conversionBudget ?? (rootIdentity == nil ? .compatibility : .targetsOnly)
        self.verificationMode = verificationMode
    }

    public init(policy: KillSnapshotPolicy) {
        self.init(
            policy: policy,
            includeHeavyMetricsForTargets: false,
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
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
    }
}

public struct KillProcessIndex: Sendable {
    public let snapshot: KillProcessSnapshot
    private let byIdentity: [ProcessIdentity: ProcessMetrics]
    private let byPID: [Int32: [ProcessMetrics]]
    private let byIdentityLite: [ProcessIdentity: KillProcessLite]
    private let byPIDLite: [Int32: [KillProcessLite]]
    private let arena: KillGraphArena?

    public init(snapshot: KillProcessSnapshot) {
        self.snapshot = snapshot
        self.arena = snapshot.arena
        self.byIdentity = Dictionary(snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        self.byPID = Dictionary(grouping: snapshot.processes, by: \.pid)
        let liteProcesses = snapshot.graph?.processes ?? []
        self.byIdentityLite = Dictionary(liteProcesses.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        self.byPIDLite = Dictionary(grouping: liteProcesses, by: \.pid)
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
    /// Exited and waiting for its parent to collect it; signals do nothing.
    public var isZombie: Bool { status == Self.zombieStatus }

    /// SZOMB in sys/proc.h, which Swift does not import.
    static let zombieStatus: UInt32 = 5
    /// SSTOP: stopped with Ctrl-Z or SIGSTOP; every signal but SIGKILL and
    /// SIGCONT waits until it runs again.
    static let stoppedStatus: UInt32 = 4
    /// PROC_FLAG_TRACED and PROC_FLAG_INEXIT from libproc.
    static let tracedFlag: UInt32 = 0x2
    static let exitingFlag: UInt32 = 0x4

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
            cpuPercent: cpuPercent,
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
}
