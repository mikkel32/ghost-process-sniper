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

public struct ThresholdSettings: Codable, Equatable, Sendable {
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var leakVelocityMegabytesPerMinute: Double
    public var sustainedSeconds: TimeInterval
    public var refreshInterval: TimeInterval
    public var forceKillDelay: TimeInterval
    public var radarMode: RadarMode
    public var groupFamilies: Bool
    public var performanceMode: RadarPerformanceMode
    public var detectionMode: RadarDetectionMode
    public var sensitivity: RadarSensitivity
    public var adaptivePerformance: Bool

    /// Compatibility profile used by tests, imported settings, and callers
    /// that intentionally set exact thresholds.
    public static let aggressive = ThresholdSettings(
        memoryBytes: 1_073_741_824,
        cpuPercent: 80,
        leakVelocityMegabytesPerMinute: 120,
        sustainedSeconds: 5,
        refreshInterval: 1,
        forceKillDelay: 2,
        radarMode: .dev,
        groupFamilies: true,
        performanceMode: .balanced,
        detectionMode: .custom,
        sensitivity: .balanced,
        adaptivePerformance: false
    )

    /// Friendly default for new installs. Raw thresholds remain available as
    /// safety rails, but the engine resolves them from host capacity and
    /// memory pressure before every scan.
    public static let smart = ThresholdSettings(
        memoryBytes: 1_073_741_824,
        cpuPercent: 90,
        leakVelocityMegabytesPerMinute: 130,
        sustainedSeconds: 5,
        refreshInterval: 1,
        forceKillDelay: 2,
        radarMode: .dev,
        groupFamilies: true,
        performanceMode: .balanced,
        detectionMode: .automatic,
        sensitivity: .balanced,
        adaptivePerformance: true
    )

    public init(
        memoryBytes: UInt64,
        cpuPercent: Double,
        leakVelocityMegabytesPerMinute: Double,
        sustainedSeconds: TimeInterval,
        refreshInterval: TimeInterval,
        forceKillDelay: TimeInterval,
        radarMode: RadarMode,
        groupFamilies: Bool,
        performanceMode: RadarPerformanceMode = .balanced,
        detectionMode: RadarDetectionMode = .custom,
        sensitivity: RadarSensitivity = .balanced,
        adaptivePerformance: Bool = false
    ) {
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.leakVelocityMegabytesPerMinute = leakVelocityMegabytesPerMinute
        self.sustainedSeconds = sustainedSeconds
        self.refreshInterval = refreshInterval
        self.forceKillDelay = forceKillDelay
        self.radarMode = radarMode
        self.groupFamilies = groupFamilies
        self.performanceMode = performanceMode
        self.detectionMode = detectionMode
        self.sensitivity = sensitivity
        self.adaptivePerformance = adaptivePerformance
    }

    private enum CodingKeys: String, CodingKey {
        case memoryBytes
        case cpuPercent
        case leakVelocityMegabytesPerMinute
        case sustainedSeconds
        case refreshInterval
        case forceKillDelay
        case radarMode
        case groupFamilies
        case performanceMode
        case detectionMode
        case sensitivity
        case adaptivePerformance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThresholdSettings.aggressive
        memoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? defaults.memoryBytes
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? defaults.cpuPercent
        leakVelocityMegabytesPerMinute = try container.decodeIfPresent(Double.self, forKey: .leakVelocityMegabytesPerMinute) ?? defaults.leakVelocityMegabytesPerMinute
        sustainedSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .sustainedSeconds) ?? defaults.sustainedSeconds
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        forceKillDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .forceKillDelay) ?? defaults.forceKillDelay
        radarMode = try container.decodeIfPresent(RadarMode.self, forKey: .radarMode) ?? defaults.radarMode
        groupFamilies = try container.decodeIfPresent(Bool.self, forKey: .groupFamilies) ?? defaults.groupFamilies
        performanceMode = try container.decodeIfPresent(RadarPerformanceMode.self, forKey: .performanceMode) ?? .balanced
        // Legacy settings were explicitly configured by the user, so retain
        // their exact behavior instead of silently converting them to smart.
        detectionMode = try container.decodeIfPresent(RadarDetectionMode.self, forKey: .detectionMode) ?? .custom
        sensitivity = try container.decodeIfPresent(RadarSensitivity.self, forKey: .sensitivity) ?? .balanced
        adaptivePerformance = try container.decodeIfPresent(Bool.self, forKey: .adaptivePerformance) ?? false
    }

    public var memoryGigabytes: Double {
        get { Double(memoryBytes) / 1_073_741_824 }
        set { memoryBytes = UInt64(max(0.1, newValue) * 1_073_741_824) }
    }
}

public struct SamplingPlan: Equatable, Sendable {
    public var sampledAt: Date
    public var performanceMode: RadarPerformanceMode
    public var commandRefreshInterval: TimeInterval
    public var includeForensicsFor: Set<ProcessIdentity>
    public var includeForensicsForPIDs: Set<Int32>
    public var forceCommandRefresh: Bool
    public var allowsOptionalForensics: Bool
    public var maxForensicsPerRefresh: Int
    public var reason: String
    public var scannerBudget: ScannerBudget
    public var candidateSet: CandidateSet
    public var probePolicy: ProcessProbePolicy
    public var metricsEnrichmentBudget: Int
    /// Someone is looking at the radar, so latency matters more than overhead.
    public var uiVisible: Bool

    public static func balanced(now: Date = Date()) -> SamplingPlan {
        let budget = ScannerBudget.budget(for: .balanced)
        return SamplingPlan(
            sampledAt: now,
            performanceMode: .balanced,
            commandRefreshInterval: 10,
            includeForensicsFor: [],
            includeForensicsForPIDs: [],
            forceCommandRefresh: false,
            allowsOptionalForensics: true,
            maxForensicsPerRefresh: budget.maxForensicsRefreshes,
            reason: "balanced",
            scannerBudget: budget,
            probePolicy: .balanced,
            metricsEnrichmentBudget: budget.maxTelemetryRefreshes * 2
        )
    }

    /// `lanePriorities` is ignored (nothing ever read it); it stays only so existing callers compile.
    public init(
        sampledAt: Date,
        performanceMode: RadarPerformanceMode,
        commandRefreshInterval: TimeInterval,
        includeForensicsFor: Set<ProcessIdentity>,
        includeForensicsForPIDs: Set<Int32>,
        forceCommandRefresh: Bool,
        allowsOptionalForensics: Bool,
        maxForensicsPerRefresh: Int,
        reason: String,
        scannerBudget: ScannerBudget? = nil,
        candidateSet: CandidateSet = .empty,
        probePolicy: ProcessProbePolicy = .balanced,
        lanePriorities: [ScanLane] = [],
        metricsEnrichmentBudget: Int? = nil,
        uiVisible: Bool = false
    ) {
        self.sampledAt = sampledAt
        self.performanceMode = performanceMode
        self.commandRefreshInterval = commandRefreshInterval
        self.includeForensicsFor = includeForensicsFor
        self.includeForensicsForPIDs = includeForensicsForPIDs
        self.forceCommandRefresh = forceCommandRefresh
        self.allowsOptionalForensics = allowsOptionalForensics
        self.maxForensicsPerRefresh = maxForensicsPerRefresh
        self.reason = reason
        self.scannerBudget = scannerBudget ?? ScannerBudget.budget(for: performanceMode)
        self.candidateSet = candidateSet
        self.probePolicy = probePolicy
        self.metricsEnrichmentBudget = metricsEnrichmentBudget ?? max(4, (scannerBudget ?? ScannerBudget.budget(for: performanceMode)).maxTelemetryRefreshes * 2)
        self.uiVisible = uiVisible
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
        scratchpadReuseCount: Int = 0
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
    public let mainActorPublishMilliseconds: Double
    public let coalescedRefreshCount: Int
    public let refreshInFlight: Bool
    public let uiCacheHitCount: Int
    public let scannerWorkerCount: Int
    public let skippedOptionalWorkCount: Int
    public let hitchCount: Int
    public let worstHitchMilliseconds: Double
    public let latestSpikePhase: String
    public let uiPublishSkippedCount: Int
    public let contentRevision: SnapshotContentRevision
    public let statusUpdateMilliseconds: Double
    public let scannerTaskCount: Int
    public let tinyQueueSequentialCount: Int
    public let diagnosticsOnlyPublishCount: Int
    public let contentPublishSkippedCount: Int
    public let samplerAllocationReuseCount: Int
    public let taskInfoReadCount: Int
    public let reusedProcessRecordCount: Int
    public let duplicateClusterCount: Int
    public let promotedDuplicateCandidateCount: Int
    public let duplicateDetectorMilliseconds: Double
    public let hardwareOffenderCount: Int
    public let hardwareDetectorMilliseconds: Double
    public let smoothnessReport: RadarSmoothnessReport

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
        mainActorPublishMilliseconds: Double = 0,
        coalescedRefreshCount: Int = 0,
        refreshInFlight: Bool = false,
        uiCacheHitCount: Int = 0,
        scannerWorkerCount: Int = 0,
        skippedOptionalWorkCount: Int = 0,
        hitchCount: Int = 0,
        worstHitchMilliseconds: Double = 0,
        latestSpikePhase: String = "none",
        uiPublishSkippedCount: Int = 0,
        contentRevision: SnapshotContentRevision = .zero,
        statusUpdateMilliseconds: Double = 0,
        scannerTaskCount: Int = 0,
        tinyQueueSequentialCount: Int = 0,
        diagnosticsOnlyPublishCount: Int = 0,
        contentPublishSkippedCount: Int = 0,
        samplerAllocationReuseCount: Int = 0,
        taskInfoReadCount: Int = 0,
        reusedProcessRecordCount: Int = 0,
        duplicateClusterCount: Int = 0,
        promotedDuplicateCandidateCount: Int = 0,
        duplicateDetectorMilliseconds: Double = 0,
        hardwareOffenderCount: Int = 0,
        hardwareDetectorMilliseconds: Double = 0,
        smoothnessReport: RadarSmoothnessReport = .empty
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
        self.mainActorPublishMilliseconds = mainActorPublishMilliseconds
        self.coalescedRefreshCount = coalescedRefreshCount
        self.refreshInFlight = refreshInFlight
        self.uiCacheHitCount = uiCacheHitCount
        self.scannerWorkerCount = scannerWorkerCount
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
        self.hitchCount = hitchCount
        self.worstHitchMilliseconds = worstHitchMilliseconds
        self.latestSpikePhase = latestSpikePhase
        self.uiPublishSkippedCount = uiPublishSkippedCount
        self.contentRevision = contentRevision
        self.statusUpdateMilliseconds = statusUpdateMilliseconds
        self.scannerTaskCount = scannerTaskCount
        self.tinyQueueSequentialCount = tinyQueueSequentialCount
        self.diagnosticsOnlyPublishCount = diagnosticsOnlyPublishCount
        self.contentPublishSkippedCount = contentPublishSkippedCount
        self.samplerAllocationReuseCount = samplerAllocationReuseCount
        self.taskInfoReadCount = taskInfoReadCount
        self.reusedProcessRecordCount = reusedProcessRecordCount
        self.duplicateClusterCount = duplicateClusterCount
        self.promotedDuplicateCandidateCount = promotedDuplicateCandidateCount
        self.duplicateDetectorMilliseconds = duplicateDetectorMilliseconds
        self.hardwareOffenderCount = hardwareOffenderCount
        self.hardwareDetectorMilliseconds = hardwareDetectorMilliseconds
        self.smoothnessReport = smoothnessReport
    }

    public func updatingSmoothness(
        mainActorPublishMilliseconds: Double? = nil,
        coalescedRefreshCount: Int? = nil,
        refreshInFlight: Bool? = nil,
        uiCacheHitCount: Int? = nil,
        scannerWorkerCount: Int? = nil,
        skippedOptionalWorkCount: Int? = nil,
        hitchCount: Int? = nil,
        worstHitchMilliseconds: Double? = nil,
        latestSpikePhase: String? = nil,
        uiPublishSkippedCount: Int? = nil,
        contentRevision: SnapshotContentRevision? = nil,
        statusUpdateMilliseconds: Double? = nil,
        scannerTaskCount: Int? = nil,
        tinyQueueSequentialCount: Int? = nil,
        diagnosticsOnlyPublishCount: Int? = nil,
        contentPublishSkippedCount: Int? = nil,
        samplerAllocationReuseCount: Int? = nil,
        taskInfoReadCount: Int? = nil,
        reusedProcessRecordCount: Int? = nil,
        duplicateClusterCount: Int? = nil,
        promotedDuplicateCandidateCount: Int? = nil,
        duplicateDetectorMilliseconds: Double? = nil,
        hardwareOffenderCount: Int? = nil,
        hardwareDetectorMilliseconds: Double? = nil,
        smoothnessReport: RadarSmoothnessReport? = nil
    ) -> RadarPerformanceMetrics {
        RadarPerformanceMetrics(
            mode: mode,
            pressureLevel: pressureLevel,
            lastRefresh: lastRefresh,
            averageRefreshMilliseconds: averageRefreshMilliseconds,
            nextRefreshInterval: nextRefreshInterval,
            forensicsDeferredCount: forensicsDeferredCount,
            forensicsRefreshCount: forensicsRefreshCount,
            commandCacheHitCount: commandCacheHitCount,
            storeBacklogCount: storeBacklogCount,
            lastStoreFlushDate: lastStoreFlushDate,
            budget: budget,
            scannerHealth: scannerHealth,
            mainActorPublishMilliseconds: mainActorPublishMilliseconds ?? self.mainActorPublishMilliseconds,
            coalescedRefreshCount: coalescedRefreshCount ?? self.coalescedRefreshCount,
            refreshInFlight: refreshInFlight ?? self.refreshInFlight,
            uiCacheHitCount: uiCacheHitCount ?? self.uiCacheHitCount,
            scannerWorkerCount: scannerWorkerCount ?? self.scannerWorkerCount,
            skippedOptionalWorkCount: skippedOptionalWorkCount ?? self.skippedOptionalWorkCount,
            hitchCount: hitchCount ?? self.hitchCount,
            worstHitchMilliseconds: worstHitchMilliseconds ?? self.worstHitchMilliseconds,
            latestSpikePhase: latestSpikePhase ?? self.latestSpikePhase,
            uiPublishSkippedCount: uiPublishSkippedCount ?? self.uiPublishSkippedCount,
            contentRevision: contentRevision ?? self.contentRevision,
            statusUpdateMilliseconds: statusUpdateMilliseconds ?? self.statusUpdateMilliseconds,
            scannerTaskCount: scannerTaskCount ?? self.scannerTaskCount,
            tinyQueueSequentialCount: tinyQueueSequentialCount ?? self.tinyQueueSequentialCount,
            diagnosticsOnlyPublishCount: diagnosticsOnlyPublishCount ?? self.diagnosticsOnlyPublishCount,
            contentPublishSkippedCount: contentPublishSkippedCount ?? self.contentPublishSkippedCount,
            samplerAllocationReuseCount: samplerAllocationReuseCount ?? self.samplerAllocationReuseCount,
            taskInfoReadCount: taskInfoReadCount ?? self.taskInfoReadCount,
            reusedProcessRecordCount: reusedProcessRecordCount ?? self.reusedProcessRecordCount,
            duplicateClusterCount: duplicateClusterCount ?? self.duplicateClusterCount,
            promotedDuplicateCandidateCount: promotedDuplicateCandidateCount ?? self.promotedDuplicateCandidateCount,
            duplicateDetectorMilliseconds: duplicateDetectorMilliseconds ?? self.duplicateDetectorMilliseconds,
            hardwareOffenderCount: hardwareOffenderCount ?? self.hardwareOffenderCount,
            hardwareDetectorMilliseconds: hardwareDetectorMilliseconds ?? self.hardwareDetectorMilliseconds,
            smoothnessReport: smoothnessReport ?? self.smoothnessReport
        )
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
