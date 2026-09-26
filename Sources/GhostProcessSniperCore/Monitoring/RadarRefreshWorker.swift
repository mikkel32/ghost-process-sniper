import Foundation

public enum RefreshGateDecision: Equatable, Sendable {
    case run
    case coalesced(Int)

    public var shouldRun: Bool {
        if case .run = self {
            return true
        }
        return false
    }
}

public actor RefreshGate {
    private var isRunning = false
    private var pendingCoalescedCount = 0

    public init() {}

    public func begin() -> RefreshGateDecision {
        if isRunning {
            pendingCoalescedCount += 1
            return .coalesced(pendingCoalescedCount)
        }
        isRunning = true
        return .run
    }

    public func finish() -> Int {
        let coalesced = pendingCoalescedCount
        pendingCoalescedCount = 0
        isRunning = false
        return coalesced
    }

    public var inFlight: Bool {
        isRunning
    }
}

public struct RefreshRequest: Equatable, Sendable {
    public let settings: ThresholdSettings
    public let currentFamilies: [ProcessFamily]
    public let currentIncidents: [RadarIncident]
    public let currentStoreHealth: StoreHealth
    public let previousRefresh: RefreshStats
    public let previousConsoleSnapshot: RadarConsoleSnapshot?
    public let popoverVisible: Bool
    public let focusedSignatureIDs: Set<String>
    public let now: Date
    public let startedAt: Date

    public init(
        settings: ThresholdSettings,
        currentFamilies: [ProcessFamily],
        currentIncidents: [RadarIncident],
        currentStoreHealth: StoreHealth,
        previousRefresh: RefreshStats,
        previousConsoleSnapshot: RadarConsoleSnapshot? = nil,
        popoverVisible: Bool,
        focusedSignatureIDs: Set<String>,
        now: Date,
        startedAt: Date
    ) {
        self.settings = settings
        self.currentFamilies = currentFamilies
        self.currentIncidents = currentIncidents
        self.currentStoreHealth = currentStoreHealth
        self.previousRefresh = previousRefresh
        self.previousConsoleSnapshot = previousConsoleSnapshot
        self.popoverVisible = popoverVisible
        self.focusedSignatureIDs = focusedSignatureIDs
        self.now = now
        self.startedAt = startedAt
    }
}

public struct RefreshOutcome: Equatable, Sendable {
    public let families: [ProcessFamily]
    public let summary: RadarSummary
    public let rules: [RadarRule]
    public let incidents: [RadarIncident]
    public let health: SamplerHealth
    public let model: RadarModel
    public let storeHealth: StoreHealth
    public let storeError: String?
    public let performance: RadarPerformanceMetrics
    public let systemPressure: SystemMemoryPressure
    public let payload: RadarPublishPayload
    public let phaseTrace: RefreshPhaseTrace
    public let generatedAt: Date
    public let thermalActivity: ThermalActivitySummary
    /// Every sampled process, tracked or not, for search.
    public let processes: [ProcessMetrics]

    public init(
        families: [ProcessFamily],
        summary: RadarSummary,
        rules: [RadarRule],
        incidents: [RadarIncident],
        health: SamplerHealth,
        model: RadarModel,
        storeHealth: StoreHealth,
        storeError: String?,
        performance: RadarPerformanceMetrics,
        systemPressure: SystemMemoryPressure,
        payload: RadarPublishPayload,
        phaseTrace: RefreshPhaseTrace,
        generatedAt: Date,
        thermalActivity: ThermalActivitySummary = .empty,
        processes: [ProcessMetrics] = []
    ) {
        self.families = families
        self.summary = summary
        self.rules = rules
        self.incidents = incidents
        self.health = health
        self.model = model
        self.storeHealth = storeHealth
        self.storeError = storeError
        self.performance = performance
        self.systemPressure = systemPressure
        self.payload = payload
        self.phaseTrace = phaseTrace
        self.generatedAt = generatedAt
        self.thermalActivity = thermalActivity
        self.processes = processes
    }
}

public actor RadarRefreshWorker {
    private let sampler: ProcessSampling
    private let store: RadarStore?
    private var pipeline: RadarPipeline
    private var scheduler = RadarScheduler()
    private var averageRefreshMilliseconds = 0.0
    private var lastIncidentRefreshDate: Date?
    private var spikeRing = SpikeRingBuffer(limit: 8)
    private var thermalHistory = ThermalActivityHistory()

    public init(
        sampler: ProcessSampling = NativeProcessSampler(),
        store: RadarStore? = nil,
        builder: ProcessFamilyBuilder = ProcessFamilyBuilder(),
        intelligence: RadarIntelligence = RadarIntelligence()
    ) {
        self.sampler = sampler
        self.store = store
        self.pipeline = RadarPipeline(builder: builder, intelligence: intelligence)
    }

    public func refresh(_ request: RefreshRequest) async throws -> RefreshOutcome {
        let signpost = RadarLogger.signposter
        let systemPressure = SystemPressureSampler().sample()
        let effectiveSettings = request.settings
            .resolvedProfile(systemPressure: systemPressure)
            .effectiveSettings
        let plan = scheduler.plan(
            settings: effectiveSettings,
            families: request.currentFamilies,
            popoverVisible: request.popoverVisible,
            focusedSignatureIDs: request.focusedSignatureIDs,
            now: request.now
        )

        let sampleState = signpost.beginInterval("RadarSample")
        let batch = try await sampler.sample(plan: plan)
        signpost.endInterval("RadarSample", sampleState)

        return await ingest(
            batch: batch,
            request: request,
            effectiveSettings: effectiveSettings,
            systemPressure: systemPressure
        )
    }

    public func ingest(
        batch: ProcessSampleBatch,
        request: RefreshRequest
    ) async -> RefreshOutcome {
        let systemPressure = SystemPressureSampler().sample()
        let effectiveSettings = request.settings
            .resolvedProfile(systemPressure: systemPressure)
            .effectiveSettings
        return await ingest(
            batch: batch,
            request: request,
            effectiveSettings: effectiveSettings,
            systemPressure: systemPressure
        )
    }

    private func ingest(
        batch: ProcessSampleBatch,
        request: RefreshRequest,
        effectiveSettings: ThresholdSettings,
        systemPressure: SystemMemoryPressure
    ) async -> RefreshOutcome {
        let build = pipeline.buildCandidates(
            processes: batch.processes,
            settings: effectiveSettings,
            now: request.now
        )
        let storeStart = Date()
        var currentRules = RadarRule.builtIns(settings: effectiveSettings)
        var currentIncidents = request.currentIncidents
        var currentStoreHealth = request.currentStoreHealth
        var storeError: String?

        let context: RadarContext
        do {
            let stored = try await store?.context(for: build.families, settings: effectiveSettings, now: request.now) ??
                RadarContext(baselines: [:], recentIncidentCounts: [:], rules: currentRules)
            context = stored.updating(systemPressure: systemPressure)
            currentRules = context.rules
        } catch {
            storeError = error.localizedDescription
            context = RadarContext(
                baselines: [:],
                recentIncidentCounts: [:],
                rules: currentRules,
                systemPressure: systemPressure
            )
            RadarLogger.store.error("Store context failed: \(error.localizedDescription, privacy: .public)")
        }

        let scored = pipeline.score(
            families: build.families,
            diff: build.diff,
            context: context,
            settings: effectiveSettings,
            now: request.now
        )
        let summary = pipeline.summary(for: scored.families)
        var health = SamplerHealth(
            engineName: store == nil ? "libproc" : "libproc + smooth idle radar",
            lastSampleDate: request.now,
            processCount: batch.processes.count,
            familyCount: scored.families.count,
            errorMessage: storeError
        )
        let model = RadarModel(
            families: scored.families,
            duplicateClusters: build.duplicateClusters,
            summary: summary,
            incidents: currentIncidents,
            rules: currentRules,
            health: health,
            generatedAt: request.now
        )

        do {
            currentStoreHealth = try await store?.enqueue(model: model, settings: request.settings, now: request.now) ?? .empty
            if shouldRefreshIncidents(
                summary: summary,
                performanceMode: scheduler.currentPerformanceMode,
                now: request.now
            ) {
                currentIncidents = try await store?.recentIncidents() ?? []
                lastIncidentRefreshDate = request.now
            }
        } catch {
            storeError = error.localizedDescription
            RadarLogger.store.error("Persistence pass failed: \(error.localizedDescription, privacy: .public)")
        }
        health = SamplerHealth(
            engineName: health.engineName,
            lastSampleDate: health.lastSampleDate,
            processCount: health.processCount,
            familyCount: health.familyCount,
            errorMessage: storeError
        )

        let storeMilliseconds = Date().timeIntervalSince(storeStart) * 1_000
        let nextInterval = scheduler.nextInterval(
            settings: effectiveSettings,
            summary: summary,
            lastRefresh: request.previousRefresh,
            popoverVisible: request.popoverVisible
        )
        let stats = RefreshStats(
            startedAt: request.startedAt,
            sampleMilliseconds: batch.stats.elapsedMilliseconds,
            buildMilliseconds: build.buildMilliseconds,
            scoreMilliseconds: scored.scoreMilliseconds,
            storeMilliseconds: storeMilliseconds,
            publishMilliseconds: 0,
            totalMilliseconds: Date().timeIntervalSince(request.startedAt) * 1_000,
            processCount: batch.processes.count,
            familyCount: scored.families.count
        )
        let performance = metrics(
            performanceMode: scheduler.currentPerformanceMode,
            stats: stats,
            samplerStats: batch.stats,
            storeHealth: currentStoreHealth,
            nextInterval: nextInterval,
            scannerHealth: batch.scannerHealth,
            duplicateClusterCount: build.duplicateClusters.filter { !$0.isInternalToSingleFamily }.count,
            promotedDuplicateCandidateCount: build.promotedDuplicateCandidateCount,
            duplicateDetectorMilliseconds: build.duplicateDetectorMilliseconds,
            hardwareOffenderCount: build.hardwareOffenderCount,
            hardwareDetectorMilliseconds: build.hardwareDetectorMilliseconds
        )
        let phaseTrace = RefreshPhaseTrace(stats: stats)
        let spikeThreshold = RadarPerformanceBudget.budget(for: scheduler.currentPerformanceMode).targetRefreshMilliseconds
        spikeRing.record(trace: phaseTrace, threshold: spikeThreshold, at: request.now)
        let spikeReport = spikeRing.report
        var tracedPerformance = performance
        tracedPerformance.smoothness.record(spikeReport)
        tracedPerformance.smoothness.scannerTaskCount = batch.stats.scannerTaskCount
        tracedPerformance.smoothness.tinyQueueSequentialCount = batch.stats.tinyQueueSequentialCount
        let payload = RadarPublishPayload.build(
            families: scored.families,
            duplicateClusters: build.duplicateClusters,
            summary: summary,
            rules: currentRules,
            incidents: currentIncidents,
            health: health,
            storeHealth: currentStoreHealth,
            storeError: storeError,
            performance: tracedPerformance,
            previous: request.previousConsoleSnapshot,
            generatedAt: request.now,
            detailSignatures: request.focusedSignatureIDs.union(scored.families.prefix(8).map(\.familyKey))
        )
        let currentActivity = ThermalActivityAnalyzer.project(
            processes: batch.processes, families: scored.families, now: request.now)
        let thermalActivity = thermalHistory.record(currentActivity, at: request.now)

        return RefreshOutcome(
            families: payload.state.families,
            summary: payload.state.summary,
            rules: payload.state.rules,
            incidents: payload.state.incidents,
            health: payload.state.health,
            model: payload.state.model,
            storeHealth: payload.state.storeHealth,
            storeError: storeError,
            performance: payload.state.performanceMetrics,
            systemPressure: systemPressure,
            payload: payload,
            phaseTrace: phaseTrace,
            generatedAt: request.now,
            thermalActivity: thermalActivity,
            processes: batch.processes
        )
    }

    private func metrics(
        performanceMode: RadarPerformanceMode,
        stats: RefreshStats,
        samplerStats: SamplerStats,
        storeHealth: StoreHealth,
        nextInterval: TimeInterval,
        scannerHealth: ScannerHealthSnapshot,
        duplicateClusterCount: Int = 0,
        promotedDuplicateCandidateCount: Int = 0,
        duplicateDetectorMilliseconds: Double = 0,
        hardwareOffenderCount: Int = 0,
        hardwareDetectorMilliseconds: Double = 0
    ) -> RadarPerformanceMetrics {
        let alpha = averageRefreshMilliseconds == 0 ? 1 : 0.18
        averageRefreshMilliseconds = averageRefreshMilliseconds * (1 - alpha) + stats.totalMilliseconds * alpha
        var smoothness = RadarSmoothnessState()
        smoothness.refreshInFlight = true
        smoothness.scannerWorkerCount = samplerStats.scannerWorkerCount
        smoothness.skippedOptionalWorkCount = samplerStats.skippedOptionalWorkCount
        smoothness.scannerTaskCount = samplerStats.scannerTaskCount
        smoothness.tinyQueueSequentialCount = samplerStats.tinyQueueSequentialCount
        smoothness.samplerAllocationReuseCount = samplerStats.scratchpadReuseCount
        smoothness.taskInfoReadCount = samplerStats.taskInfoReadCount
        smoothness.reusedProcessRecordCount = samplerStats.reusedRecordCount
        smoothness.duplicateClusterCount = duplicateClusterCount
        smoothness.promotedDuplicateCandidateCount = promotedDuplicateCandidateCount
        smoothness.duplicateDetectorMilliseconds = duplicateDetectorMilliseconds
        smoothness.hardwareOffenderCount = hardwareOffenderCount
        smoothness.hardwareDetectorMilliseconds = hardwareDetectorMilliseconds
        return RadarPerformanceMetrics(
            mode: performanceMode,
            pressureLevel: scheduler.currentPressure,
            lastRefresh: stats,
            averageRefreshMilliseconds: averageRefreshMilliseconds,
            nextRefreshInterval: nextInterval,
            forensicsDeferredCount: samplerStats.forensicsDeferredCount,
            forensicsRefreshCount: samplerStats.forensicsRefreshCount,
            commandCacheHitCount: samplerStats.commandCacheHitCount,
            storeBacklogCount: storeHealth.backlogCount,
            lastStoreFlushDate: storeHealth.lastFlushDate,
            budget: RadarPerformanceBudget.budget(for: performanceMode),
            scannerHealth: scannerHealth,
            smoothness: smoothness
        )
    }

    private func shouldRefreshIncidents(
        summary: RadarSummary,
        performanceMode: RadarPerformanceMode,
        now: Date
    ) -> Bool {
        if summary.level >= .hot || summary.hotCount > 0 {
            return true
        }
        guard let lastIncidentRefreshDate else {
            return true
        }
        let quietInterval: TimeInterval = switch performanceMode {
        case .batterySaver: 30
        case .balanced: 15
        case .realtime: 5
        }
        return now.timeIntervalSince(lastIncidentRefreshDate) >= quietInterval
    }
}
