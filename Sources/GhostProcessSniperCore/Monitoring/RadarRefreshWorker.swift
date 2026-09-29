import Foundation

public enum RefreshReason: Sendable {
    /// Someone waits on data sampled after the call: Scan now, a stop, a search.
    case user
    /// A background tick; it joins a running refresh instead of queueing one.
    case loop
}

public struct RefreshRequest: Equatable, Sendable {
    public let settings: ThresholdSettings
    public let currentFamilies: [ProcessFamily]
    public let currentIncidents: [RadarIncident]
    public let currentStoreHealth: StoreHealth
    public let previousConsoleSnapshot: RadarConsoleSnapshot?
    /// The popover or the console is on screen.
    public let uiVisible: Bool
    public let focusedSignatureIDs: Set<String>
    /// Read every same-user process's listening ports this tick (a `port:` search).
    public let portCensusRequested: Bool
    /// Main-actor figures the worker folds into the published diagnostics,
    /// so the main actor does not rebuild them after every tick.
    public let hitchReport: RadarSmoothnessReport
    public let lastPublishMilliseconds: Double
    public let coalescedRefreshCount: Int
    public let now: Date
    public let startedAt: Date

    public init(
        settings: ThresholdSettings,
        currentFamilies: [ProcessFamily],
        currentIncidents: [RadarIncident],
        currentStoreHealth: StoreHealth,
        previousConsoleSnapshot: RadarConsoleSnapshot? = nil,
        uiVisible: Bool,
        focusedSignatureIDs: Set<String>,
        portCensusRequested: Bool = false,
        hitchReport: RadarSmoothnessReport = .empty,
        lastPublishMilliseconds: Double = 0,
        coalescedRefreshCount: Int = 0,
        now: Date,
        startedAt: Date
    ) {
        self.settings = settings
        self.currentFamilies = currentFamilies
        self.currentIncidents = currentIncidents
        self.currentStoreHealth = currentStoreHealth
        self.previousConsoleSnapshot = previousConsoleSnapshot
        self.uiVisible = uiVisible
        self.focusedSignatureIDs = focusedSignatureIDs
        self.portCensusRequested = portCensusRequested
        self.hitchReport = hitchReport
        self.lastPublishMilliseconds = lastPublishMilliseconds
        self.coalescedRefreshCount = coalescedRefreshCount
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
    /// Security findings and the launch feed.
    public let sentinel: SentinelReport
    /// Energy per app, the battery, and what keeps the Mac awake.
    public let energy: EnergyReport

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
        processes: [ProcessMetrics] = [],
        sentinel: SentinelReport = .empty,
        energy: EnergyReport = .empty
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
        self.sentinel = sentinel
        self.energy = energy
    }
}

public actor RadarRefreshWorker {
    private let sampler: ProcessSampling
    private let store: RadarStore?
    private var pipeline: RadarPipeline
    private var scheduler = RadarScheduler()
    private var averageRefreshMilliseconds = 0.0
    private var lastIncidentRefreshDate: Date?
    /// The store flush the incident list was last read after. Incidents are
    /// only written by a flush, so until the next one a re-read is identical.
    private var incidentsReadAtFlush: Date?
    private var spikeRing = SpikeRingBuffer(limit: 8)
    private var thermalHistory = ThermalActivityHistory()
    private let sentinel: SentinelEngine?
    private var energy: EnergyMonitor
    private var responsibility: ResponsibleProcessLookup

    public init(
        sampler: ProcessSampling = NativeProcessSampler(),
        store: RadarStore? = nil,
        builder: ProcessFamilyBuilder = ProcessFamilyBuilder(),
        intelligence: RadarIntelligence = RadarIntelligence(),
        sentinel: SentinelEngine? = nil,
        battery: (any BatterySource)? = IOKitBatterySource(),
        sleepAssertions: (any SleepAssertionSource)? = IOKitSleepAssertionSource(),
        responsibleQuery: (@Sendable (Int32) -> Int32?)? = nil
    ) {
        // Tests stand in for the libSystem call, which answers for real pids only.
        self.responsibility = ResponsibleProcessLookup(query: responsibleQuery ?? ResponsibleProcessLookup.system)
        self.sampler = sampler
        self.store = store
        self.sentinel = sentinel
        self.energy = EnergyMonitor(battery: battery, assertions: sleepAssertions, persistsHistory: store != nil)
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
            uiVisible: request.uiVisible,
            focusedSignatureIDs: request.focusedSignatureIDs,
            portCensusRequested: request.portCensusRequested,
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
        // Asked once per tick: the families place launchd-started helpers
        // with it, and the energy attribution below reuses the same answers.
        let responsible = responsibility.hints(for: batch.processes, now: request.now)
        let build = pipeline.buildCandidates(
            processes: batch.processes,
            settings: effectiveSettings,
            responsible: responsible,
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
            if Self.shouldRereadIncidents(
                lastReadAt: lastIncidentRefreshDate,
                readAtFlush: incidentsReadAtFlush,
                storeFlush: currentStoreHealth.lastFlushDate,
                performanceMode: scheduler.currentPerformanceMode,
                now: request.now
            ) {
                currentIncidents = try await store?.recentIncidents() ?? []
                lastIncidentRefreshDate = request.now
                incidentsReadAtFlush = currentStoreHealth.lastFlushDate
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
        let hotSinceAlerted = scheduler.noteHotFamilies(scored.families, now: request.now)
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
        let nextInterval = scheduler.nextInterval(settings: effectiveSettings, context: RadarSchedulingContext(
            uiVisible: request.uiVisible,
            power: scheduler.currentPower,
            thermalPressure: scheduler.currentPressure,
            summaryLevel: RadarScheduler.schedulingLevel(scored.families),
            hotSinceAlerted: hotSinceAlerted,
            currentRefreshMilliseconds: stats.totalMilliseconds,
            userIdleSeconds: request.uiVisible ? scheduler.userIdleSeconds() : 0
        ))
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
        tracedPerformance.smoothness.record(spikeReport.merging(request.hitchReport))
        tracedPerformance.smoothness.mainActorPublishMilliseconds = request.lastPublishMilliseconds
        tracedPerformance.smoothness.coalescedRefreshCount = request.coalescedRefreshCount
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
            detailSignatures: request.focusedSignatureIDs.union(scored.families.prefix(8).map(\.familyKey)),
            processes: batch.processes
        )
        var resolver = ThermalWorkloadResolver(processes: batch.processes, responsiblePIDs: responsible)
        let currentActivity = ThermalActivityAnalyzer.project(
            processes: batch.processes, families: scored.families, now: request.now, resolver: &resolver)
        let thermalActivity = thermalHistory.record(currentActivity, at: request.now)
        let energyReport = energy.update(processes: batch.processes, families: scored.families,
                                         resolver: &resolver, uiVisible: request.uiVisible, now: request.now)
        await syncEnergyHistory(now: request.now)
        let sentinelReport = await sentinel?.ingest(
            processes: batch.processes, uiVisible: request.uiVisible, now: request.now) ?? .empty

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
            processes: batch.processes,
            sentinel: sentinelReport,
            energy: energyReport
        )
    }

    /// Loads today's stored energy once, then adds what was measured every
    /// five minutes; `force` writes whatever is pending, for quitting.
    public func syncEnergyHistory(now: Date, force: Bool = false) async {
        guard let store else { return }
        if energy.needsHistoryLoad(now: now) {
            do {
                energy.loadHistory(try await store.energyHistory(days: EnergyHistory.dayCount, now: now), now: now)
            } catch {
                energy.noteHistoryLoadFailed(now: now)
                RadarLogger.store.error("Energy history load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let batches = energy.takeHistoryFlush(now: now, force: force) else { return }
        for (index, batch) in batches.enumerated() {
            do {
                try await store.recordEnergy(batch.usages, day: batch.day, now: now)
            } catch {
                energy.restoreHistory(Array(batches[index...]))
                RadarLogger.store.error("Energy history write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
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

    /// Re-reads after every flush, and on a slow timer as a safety net for
    /// anything else that touches the incident table.
    static func shouldRereadIncidents(
        lastReadAt: Date?,
        readAtFlush: Date?,
        storeFlush: Date?,
        performanceMode: RadarPerformanceMode,
        now: Date
    ) -> Bool {
        guard let lastReadAt, storeFlush == readAtFlush else {
            return true
        }
        let quietInterval: TimeInterval = switch performanceMode {
        case .batterySaver: 30
        case .balanced: 15
        case .realtime: 5
        }
        return now.timeIntervalSince(lastReadAt) >= quietInterval
    }
}
