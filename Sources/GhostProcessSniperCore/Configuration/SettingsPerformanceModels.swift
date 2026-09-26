import Foundation

public enum SystemPressureLevel: String, Codable, Comparable, Sendable {
    case nominal
    case elevated
    case serious
    case critical

    public var allowsOptionalForensics: Bool {
        switch self {
        case .nominal, .elevated: true
        case .serious, .critical: false
        }
    }

    public static func < (lhs: SystemPressureLevel, rhs: SystemPressureLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ level: SystemPressureLevel) -> Int {
        switch level {
        case .nominal: 0
        case .elevated: 1
        case .serious: 2
        case .critical: 3
        }
    }
}

public struct SamplingPlan: Equatable, Sendable {
    public var sampledAt: Date
    public var performanceMode: RadarPerformanceMode
    public var commandRefreshInterval: TimeInterval
    public var includeForensicsFor: Set<ProcessIdentity>
    public var includeForensicsForPIDs: Set<Int32>
    public var allowsOptionalForensics: Bool
    public var maxForensicsPerRefresh: Int
    public var reason: String
    public var scannerBudget: ScannerBudget
    public var candidateSet: CandidateSet
    public var probePolicy: ProcessProbePolicy
    public var metricsEnrichmentBudget: Int
    /// Someone is looking at the radar, so latency matters more than overhead.
    public var uiVisible: Bool
    /// Members of classified developer families: priority work without explicit demand.
    public var hintedIdentities: Set<ProcessIdentity>

    public static func balanced(now: Date = Date()) -> SamplingPlan {
        let budget = ScannerBudget.budget(for: .balanced)
        return SamplingPlan(
            sampledAt: now,
            performanceMode: .balanced,
            commandRefreshInterval: SamplingPlan.telemetryRefreshInterval,
            includeForensicsFor: [],
            includeForensicsForPIDs: [],
            allowsOptionalForensics: true,
            maxForensicsPerRefresh: budget.maxForensicsRefreshes,
            reason: "balanced",
            scannerBudget: budget,
            probePolicy: .balanced,
            metricsEnrichmentBudget: budget.maxTelemetryRefreshes * 2
        )
    }

    /// Telemetry refreshes on exec (a new kernel name) and when never read; this
    /// age is only the safety net for processes that rewrite their own argv.
    public static let telemetryRefreshInterval: TimeInterval = 600

    /// `lanePriorities` and `forceCommandRefresh` are ignored (nothing needs
    /// them any more); they stay only so existing callers compile.
    public init(
        sampledAt: Date,
        performanceMode: RadarPerformanceMode,
        commandRefreshInterval: TimeInterval,
        includeForensicsFor: Set<ProcessIdentity>,
        includeForensicsForPIDs: Set<Int32>,
        forceCommandRefresh: Bool = false,
        allowsOptionalForensics: Bool,
        maxForensicsPerRefresh: Int,
        reason: String,
        scannerBudget: ScannerBudget? = nil,
        candidateSet: CandidateSet = .empty,
        probePolicy: ProcessProbePolicy = .balanced,
        lanePriorities: [ScanLane] = [],
        metricsEnrichmentBudget: Int? = nil,
        uiVisible: Bool = false,
        hintedIdentities: Set<ProcessIdentity> = []
    ) {
        self.sampledAt = sampledAt
        self.performanceMode = performanceMode
        self.commandRefreshInterval = commandRefreshInterval
        self.includeForensicsFor = includeForensicsFor
        self.includeForensicsForPIDs = includeForensicsForPIDs
        self.allowsOptionalForensics = allowsOptionalForensics
        self.maxForensicsPerRefresh = maxForensicsPerRefresh
        self.reason = reason
        self.scannerBudget = scannerBudget ?? ScannerBudget.budget(for: performanceMode)
        self.candidateSet = candidateSet
        self.probePolicy = probePolicy
        self.metricsEnrichmentBudget = metricsEnrichmentBudget ?? max(4, (scannerBudget ?? ScannerBudget.budget(for: performanceMode)).maxTelemetryRefreshes * 2)
        self.uiVisible = uiVisible
        self.hintedIdentities = hintedIdentities
    }
}

public struct SamplerStats: Equatable, Sendable {
    public let processCount: Int
    public let commandRefreshCount: Int
    public let commandCacheHitCount: Int
    public let forensicsRefreshCount: Int
    public let forensicsDeferredCount: Int
    public let elapsedMilliseconds: Double
    public let telemetryDeferredCount: Int
    public let forensicsCacheHitCount: Int
    public let forensicsNegativeCacheHitCount: Int
    public let skippedPIDCount: Int
    public let expensiveCallCount: Int
    public let richMetricRefreshCount: Int
    public let scannerWorkerCount: Int
    public let skippedOptionalWorkCount: Int
    public let scannerTaskCount: Int
    public let tinyQueueSequentialCount: Int
    public let didHitDeadline: Bool
    public let laneCounts: [ScanLane: Int]
    public let bsdReadCount: Int
    public let taskInfoReadCount: Int
    public let reusedRecordCount: Int
    public let pidBufferCopyCount: Int
    public let scratchpadReuseCount: Int
    /// Processes whose CPU and memory were read this tick.
    public let usageReadCount: Int
    public let usageFailedCount: Int
    /// Other users' processes the kernel will not describe without privilege.
    public let bsdDeniedCount: Int

    public static let empty = SamplerStats(
        processCount: 0,
        commandRefreshCount: 0,
        commandCacheHitCount: 0,
        forensicsRefreshCount: 0,
        forensicsDeferredCount: 0,
        elapsedMilliseconds: 0
    )

    public init(
        processCount: Int,
        commandRefreshCount: Int,
        commandCacheHitCount: Int,
        forensicsRefreshCount: Int,
        forensicsDeferredCount: Int,
        elapsedMilliseconds: Double,
        telemetryDeferredCount: Int = 0,
        forensicsCacheHitCount: Int = 0,
        forensicsNegativeCacheHitCount: Int = 0,
        skippedPIDCount: Int = 0,
        expensiveCallCount: Int = 0,
        richMetricRefreshCount: Int = 0,
        scannerWorkerCount: Int = 0,
        skippedOptionalWorkCount: Int = 0,
        scannerTaskCount: Int = 0,
        tinyQueueSequentialCount: Int = 0,
        didHitDeadline: Bool = false,
        laneCounts: [ScanLane: Int] = [:],
        bsdReadCount: Int = 0,
        taskInfoReadCount: Int = 0,
        reusedRecordCount: Int = 0,
        pidBufferCopyCount: Int = 0,
        scratchpadReuseCount: Int = 0,
        usageReadCount: Int = 0,
        usageFailedCount: Int = 0,
        bsdDeniedCount: Int = 0
    ) {
        self.processCount = processCount
        self.commandRefreshCount = commandRefreshCount
        self.commandCacheHitCount = commandCacheHitCount
        self.forensicsRefreshCount = forensicsRefreshCount
        self.forensicsDeferredCount = forensicsDeferredCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.telemetryDeferredCount = telemetryDeferredCount
        self.forensicsCacheHitCount = forensicsCacheHitCount
        self.forensicsNegativeCacheHitCount = forensicsNegativeCacheHitCount
        self.skippedPIDCount = skippedPIDCount
        self.expensiveCallCount = expensiveCallCount
        self.richMetricRefreshCount = richMetricRefreshCount
        self.scannerWorkerCount = scannerWorkerCount
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
        self.scannerTaskCount = scannerTaskCount
        self.tinyQueueSequentialCount = tinyQueueSequentialCount
        self.didHitDeadline = didHitDeadline
        self.laneCounts = laneCounts
        self.bsdReadCount = bsdReadCount
        self.taskInfoReadCount = taskInfoReadCount
        self.reusedRecordCount = reusedRecordCount
        self.pidBufferCopyCount = pidBufferCopyCount
        self.scratchpadReuseCount = scratchpadReuseCount
        self.usageReadCount = usageReadCount
        self.usageFailedCount = usageFailedCount
        self.bsdDeniedCount = bsdDeniedCount
    }
}

public struct ProcessSampleBatch: Equatable, Sendable {
    public let processes: [ProcessMetrics]
    public let sampledAt: Date
    public let stats: SamplerStats
    public let scannerHealth: ScannerHealthSnapshot

    public init(
        processes: [ProcessMetrics],
        sampledAt: Date,
        stats: SamplerStats,
        scannerHealth: ScannerHealthSnapshot = .starting
    ) {
        self.processes = processes
        self.sampledAt = sampledAt
        self.stats = stats
        self.scannerHealth = scannerHealth
    }
}

public struct RadarPerformanceBudget: Equatable, Sendable {
    public let targetIdleCPUPercent: Double
    public let targetRefreshMilliseconds: Double
    public let maxForensicsPerRefresh: Int
    public let storeFlushInterval: TimeInterval

    public static let balanced = RadarPerformanceBudget(
        targetIdleCPUPercent: 0.25,
        targetRefreshMilliseconds: 60,
        maxForensicsPerRefresh: 4,
        storeFlushInterval: 5
    )

    public static func budget(for mode: RadarPerformanceMode) -> RadarPerformanceBudget {
        switch mode {
        case .batterySaver:
            RadarPerformanceBudget(
                targetIdleCPUPercent: 0.18,
                targetRefreshMilliseconds: 45,
                maxForensicsPerRefresh: 2,
                storeFlushInterval: 10
            )
        case .balanced:
            .balanced
        case .realtime:
            RadarPerformanceBudget(
                targetIdleCPUPercent: 1.2,
                targetRefreshMilliseconds: 120,
                maxForensicsPerRefresh: 12,
                storeFlushInterval: 2
            )
        }
    }
}

public struct RefreshStats: Equatable, Sendable {
    public let startedAt: Date
    public let sampleMilliseconds: Double
    public let buildMilliseconds: Double
    public let scoreMilliseconds: Double
    public let storeMilliseconds: Double
    public let publishMilliseconds: Double
    public let totalMilliseconds: Double
    public let processCount: Int
    public let familyCount: Int

    public static let empty = RefreshStats(
        startedAt: Date(timeIntervalSince1970: 0),
        sampleMilliseconds: 0,
        buildMilliseconds: 0,
        scoreMilliseconds: 0,
        storeMilliseconds: 0,
        publishMilliseconds: 0,
        totalMilliseconds: 0,
        processCount: 0,
        familyCount: 0
    )

    public init(
        startedAt: Date,
        sampleMilliseconds: Double,
        buildMilliseconds: Double,
        scoreMilliseconds: Double,
        storeMilliseconds: Double,
        publishMilliseconds: Double,
        totalMilliseconds: Double,
        processCount: Int,
        familyCount: Int
    ) {
        self.startedAt = startedAt
        self.sampleMilliseconds = sampleMilliseconds
        self.buildMilliseconds = buildMilliseconds
        self.scoreMilliseconds = scoreMilliseconds
        self.storeMilliseconds = storeMilliseconds
        self.publishMilliseconds = publishMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.processCount = processCount
        self.familyCount = familyCount
    }
}

/// Publish, hitch and scanner-shape diagnostics that ride along with each
/// refresh. Callers copy the metrics and mutate this in place, so a new
/// counter is one stored property here and nothing else.
public struct RadarSmoothnessState: Equatable, Sendable {
    public var mainActorPublishMilliseconds: Double = 0
    public var coalescedRefreshCount = 0
    public var refreshInFlight = false
    public var uiCacheHitCount = 0
    public var scannerWorkerCount = 0
    public var skippedOptionalWorkCount = 0
    public var hitchCount = 0
    public var worstHitchMilliseconds: Double = 0
    public var latestSpikePhase = "none"
    public var uiPublishSkippedCount = 0
    public var contentRevision: SnapshotContentRevision = .zero
    public var statusUpdateMilliseconds: Double = 0
    public var scannerTaskCount = 0
    public var tinyQueueSequentialCount = 0
    public var diagnosticsOnlyPublishCount = 0
    public var contentPublishSkippedCount = 0
    public var samplerAllocationReuseCount = 0
    public var taskInfoReadCount = 0
    public var reusedProcessRecordCount = 0
    public var duplicateClusterCount = 0
    public var promotedDuplicateCandidateCount = 0
    public var duplicateDetectorMilliseconds: Double = 0
    public var hardwareOffenderCount = 0
    public var hardwareDetectorMilliseconds: Double = 0
    public var smoothnessReport: RadarSmoothnessReport = .empty

    public init() {}

    /// Adopts a hitch report together with the summary fields derived from it.
    public mutating func record(_ report: RadarSmoothnessReport) {
        hitchCount = report.hitchCount
        worstHitchMilliseconds = report.worstHitchMilliseconds
        latestSpikePhase = report.latestSpikePhase
        smoothnessReport = report
    }
}

/// Smoothness fields read straight through (`metrics.hitchCount`); writes go
/// through `smoothness` on a copy.
@dynamicMemberLookup
public struct RadarPerformanceMetrics: Equatable, Sendable {
    public let mode: RadarPerformanceMode
    public let pressureLevel: SystemPressureLevel
    public let lastRefresh: RefreshStats
    public let averageRefreshMilliseconds: Double
    public let nextRefreshInterval: TimeInterval
    public let forensicsDeferredCount: Int
    public let forensicsRefreshCount: Int
    public let commandCacheHitCount: Int
    public let storeBacklogCount: Int
    public let lastStoreFlushDate: Date?
    public let budget: RadarPerformanceBudget
    public let scannerHealth: ScannerHealthSnapshot
    public var smoothness: RadarSmoothnessState

    public static let empty = RadarPerformanceMetrics(
        mode: .balanced,
        pressureLevel: .nominal,
        lastRefresh: .empty,
        averageRefreshMilliseconds: 0,
        nextRefreshInterval: 1,
        forensicsDeferredCount: 0,
        forensicsRefreshCount: 0,
        commandCacheHitCount: 0,
        storeBacklogCount: 0,
        lastStoreFlushDate: nil,
        budget: .balanced,
        scannerHealth: .starting
    )

    public init(
        mode: RadarPerformanceMode,
        pressureLevel: SystemPressureLevel,
        lastRefresh: RefreshStats,
        averageRefreshMilliseconds: Double,
        nextRefreshInterval: TimeInterval,
        forensicsDeferredCount: Int,
        forensicsRefreshCount: Int,
        commandCacheHitCount: Int,
        storeBacklogCount: Int,
        lastStoreFlushDate: Date?,
        budget: RadarPerformanceBudget,
        scannerHealth: ScannerHealthSnapshot = .starting,
        smoothness: RadarSmoothnessState = RadarSmoothnessState()
    ) {
        self.mode = mode
        self.pressureLevel = pressureLevel
        self.lastRefresh = lastRefresh
        self.averageRefreshMilliseconds = averageRefreshMilliseconds
        self.nextRefreshInterval = nextRefreshInterval
        self.forensicsDeferredCount = forensicsDeferredCount
        self.forensicsRefreshCount = forensicsRefreshCount
        self.commandCacheHitCount = commandCacheHitCount
        self.storeBacklogCount = storeBacklogCount
        self.lastStoreFlushDate = lastStoreFlushDate
        self.budget = budget
        self.scannerHealth = scannerHealth
        self.smoothness = smoothness
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<RadarSmoothnessState, Value>) -> Value {
        smoothness[keyPath: keyPath]
    }
}

public struct SamplerHealth: Equatable, Sendable {
    public let engineName: String
    public let lastSampleDate: Date?
    public let processCount: Int
    public let familyCount: Int
    public let errorMessage: String?

    public static let starting = SamplerHealth(
        engineName: "libproc",
        lastSampleDate: nil,
        processCount: 0,
        familyCount: 0,
        errorMessage: nil
    )

    public init(
        engineName: String,
        lastSampleDate: Date?,
        processCount: Int,
        familyCount: Int,
        errorMessage: String?
    ) {
        self.engineName = engineName
        self.lastSampleDate = lastSampleDate
        self.processCount = processCount
        self.familyCount = familyCount
        self.errorMessage = errorMessage
    }
}
