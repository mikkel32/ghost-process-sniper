import Darwin
import Foundation
import Observation

@MainActor
@Observable
public final class ProcessMonitor {
    public var settings: ThresholdSettings
    public private(set) var families: [ProcessFamily] = []
    public private(set) var summary: RadarSummary = .empty
    public private(set) var health: SamplerHealth = .starting
    public private(set) var incidents: [RadarIncident] = []
    public private(set) var rules: [RadarRule] = []
    public private(set) var model: RadarModel = .empty
    public private(set) var viewModel: RadarViewModel = .empty
    public private(set) var triageFamilies: [FamilyTriageViewModel] = []
    public private(set) var detailViewModels: [String: FamilyDetailViewModel] = [:]
    public private(set) var consoleSnapshot: RadarConsoleSnapshot = .empty
    public private(set) var engineDiagnostics: EngineDiagnosticsViewModel = .empty
    public private(set) var engineStatus: EngineStatusSnapshot = .empty
    public private(set) var performanceMetrics: RadarPerformanceMetrics = .empty
    public private(set) var scannerHealth: ScannerHealthSnapshot = .starting
    public private(set) var storeHealth: StoreHealth = .empty
    public private(set) var storeError: String?
    public private(set) var publishedState: ProcessMonitorPublishedState = .empty
    public private(set) var systemPressure: SystemMemoryPressure = .unknown
    public private(set) var selfUsage: SelfResourceUsage = .unknown

    @ObservationIgnored private var selfUsageMonitor = SelfUsageMonitor()
    @ObservationIgnored private let pressureSampler = SystemPressureSampler()
    @ObservationIgnored private let notifier: RadarNotifying
    @ObservationIgnored private let store: RadarStore?
    @ObservationIgnored private let worker: RadarRefreshWorker
    @ObservationIgnored private let refreshGate = RefreshGate()
    @ObservationIgnored private var pipeline: RadarPipeline
    @ObservationIgnored private var scheduler = RadarScheduler()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadPersistedSettings = false
    @ObservationIgnored private var popoverVisible = false
    @ObservationIgnored private var focusedSignatureIDs: Set<String> = []
    @ObservationIgnored private var averageRefreshMilliseconds = 0.0
    @ObservationIgnored private let hitchMonitor = MainActorHitchMonitor()
    @ObservationIgnored private var publishedStateObservers: [UUID: (ProcessMonitorPublishedState) -> Void] = [:]

    public var statusLevel: GhostLevel {
        summary.level
    }

    public var activeAlertCount: Int {
        summary.hotCount
    }

    public init(
        sampler: ProcessSampling = NativeProcessSampler(),
        builder: ProcessFamilyBuilder = ProcessFamilyBuilder(),
        intelligence: RadarIntelligence = RadarIntelligence(),
        settings: ThresholdSettings = .aggressive,
        store: RadarStore? = ProcessMonitor.createDefaultStore(),
        notifier: RadarNotifying = NoopRadarNotifier()
    ) {
        self.settings = settings
        self.store = store
        self.notifier = notifier
        self.worker = RadarRefreshWorker(
            sampler: sampler,
            store: store,
            builder: builder,
            intelligence: intelligence
        )
        self.pipeline = RadarPipeline(builder: builder, intelligence: intelligence)
    }

    deinit {
        refreshTask?.cancel()
        settingsSaveTask?.cancel()
    }

    public func start() {
        stop()
        hitchMonitor.start()
        refreshTask = Task { @MainActor [weak self] in
            await self?.loadPersistedSettingsIfNeeded()
            while !Task.isCancelled {
                await self?.refresh()
                var interval = max(0.25, self?.performanceMetrics.nextRefreshInterval ?? 1)
                // Self-throttle: when the radar's own average CPU is above
                // budget, stretch the cadence until it recovers.
                if self?.selfUsage.isThrottling == true {
                    interval = min(interval * 1.6, 8)
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        hitchMonitor.stop()
        Task { [store] in
            try? await store?.flush()
        }
    }

    public func refresh(now: Date = Date()) async {
        let refreshStart = Date()
        let signpost = RadarLogger.signposter
        let refreshState = signpost.beginInterval("RadarRefresh")
        defer { signpost.endInterval("RadarRefresh", refreshState) }

        let gateDecision = await refreshGate.begin()
        guard gateDecision.shouldRun else {
            if case .coalesced(let count) = gateDecision {
                performanceMetrics = performanceMetrics.updatingSmoothness(
                    coalescedRefreshCount: count,
                    refreshInFlight: true
                )
            }
            return
        }

        do {
            let request = RefreshRequest(
                settings: settings,
                currentFamilies: families,
                currentIncidents: incidents,
                currentStoreHealth: storeHealth,
                previousRefresh: performanceMetrics.lastRefresh,
                previousConsoleSnapshot: consoleSnapshot,
                popoverVisible: popoverVisible,
                focusedSignatureIDs: focusedSignatureIDs,
                now: now,
                startedAt: refreshStart
            )
            let outcome = try await worker.refresh(request)
            let coalesced = await refreshGate.finish()
            let pressure = pressureSampler.sample()
            if pressure != systemPressure {
                systemPressure = pressure
            }
            let usage = selfUsageMonitor.sample()
            if usage != selfUsage {
                selfUsage = usage
                if usage.isThrottling {
                    RadarLogger.sampler.info("Self-throttle active: radar averaging \(Int(usage.averageCPUPercent.rounded()), privacy: .public)% CPU")
                }
            }
            publish(outcome: outcome, coalescedRefreshCount: coalesced)
            await notifier.process(model: model)
        } catch {
            let coalesced = await refreshGate.finish()
            performanceMetrics = performanceMetrics.updatingSmoothness(
                coalescedRefreshCount: coalesced,
                refreshInFlight: false
            )
            health = SamplerHealth(
                engineName: "libproc",
                lastSampleDate: health.lastSampleDate,
                processCount: health.processCount,
                familyCount: families.count,
                errorMessage: error.localizedDescription
            )
            RadarLogger.sampler.error("Sample failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func ingest(_ processes: [ProcessMetrics], now: Date = Date()) {
        let build = pipeline.buildCandidates(
            processes: processes,
            settings: settings,
            now: now
        )
        let scored = pipeline.score(
            families: build.families,
            diff: build.diff,
            context: RadarContext(
                baselines: [:],
                recentIncidentCounts: [:],
                rules: RadarRule.builtIns(settings: settings)
            ),
            settings: settings,
            now: now
        )
        let summary = pipeline.summary(for: scored.families)
        let stats = RefreshStats(
            startedAt: now,
            sampleMilliseconds: 0,
            buildMilliseconds: build.buildMilliseconds,
            scoreMilliseconds: scored.scoreMilliseconds,
            storeMilliseconds: 0,
            publishMilliseconds: 0,
            totalMilliseconds: build.buildMilliseconds + scored.scoreMilliseconds,
            processCount: processes.count,
            familyCount: scored.families.count
        )
        publish(
            families: scored.families,
            duplicateClusters: build.duplicateClusters,
            summary: summary,
            rules: RadarRule.builtIns(settings: settings),
            incidents: incidents,
            health: SamplerHealth(
                engineName: "libproc",
                lastSampleDate: now,
                processCount: processes.count,
                familyCount: scored.families.count,
                errorMessage: nil
            ),
            generatedAt: now,
            storeHealth: storeHealth,
            performance: metrics(
                stats: stats,
                samplerStats: .empty,
                storeHealth: storeHealth,
                nextInterval: settings.refreshInterval,
                scannerHealth: .starting,
                duplicateClusterCount: build.duplicateClusters.filter { !$0.isInternalToSingleFamily }.count,
                promotedDuplicateCandidateCount: build.promotedDuplicateCandidateCount,
                duplicateDetectorMilliseconds: build.duplicateDetectorMilliseconds,
                hardwareOffenderCount: build.hardwareOffenderCount,
                hardwareDetectorMilliseconds: build.hardwareDetectorMilliseconds
            )
        )
    }

    public func recordStatusUpdateCost(_ milliseconds: Double) {
        let updated = performanceMetrics.updatingSmoothness(statusUpdateMilliseconds: milliseconds)
        performanceMetrics = updated
        publishedState = publishedState.updating(performanceMetrics: updated)
    }

    public func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
    }

    @discardableResult
    public func addPublishedStateObserver(_ observer: @escaping (ProcessMonitorPublishedState) -> Void) -> UUID {
        let id = UUID()
        publishedStateObservers[id] = observer
        return id
    }

    public func removePublishedStateObserver(_ id: UUID) {
        publishedStateObservers[id] = nil
    }

    public func saveSettingsDebounced(delay: TimeInterval = 0.45) {
        settingsSaveTask?.cancel()
        let settings = settings
        settingsSaveTask = Task { [store] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            try? await store?.saveSettings(settings)
        }
    }

    public func saveSettingsNow() async {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        do {
            try await store?.saveSettings(settings)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
    }

    public func focusFamily(signatureID: String?) {
        guard let signatureID else {
            focusedSignatureIDs.removeAll()
            return
        }
        focusedSignatureIDs = [signatureID]
    }

    public func focusFamilies(signatureIDs: Set<String>) {
        focusedSignatureIDs = signatureIDs
    }

    public func snooze(_ family: ProcessFamily, minutes: TimeInterval = 60) async {
        let rule = RadarRule(
            name: "Snooze \(family.displayName)",
            isBuiltIn: false,
            match: RadarRuleMatch(signatureID: family.signature.id, minimumLevel: .quiet),
            action: .snooze,
            expiresAt: Date().addingTimeInterval(minutes * 60)
        )
        await save(rule: rule)
    }

    public func ignore(_ family: ProcessFamily) async {
        let rule = RadarRule(
            name: "Ignore \(family.displayName)",
            isBuiltIn: false,
            match: RadarRuleMatch(signatureID: family.signature.id, minimumLevel: .quiet),
            action: .ignore
        )
        await save(rule: rule)
    }

    public func addCommandRule(commandContains: String, action: RadarActionType) async {
        await addRule(draft: RuleDraft(commandContains: commandContains, action: action))
    }

    public func addRule(draft: RuleDraft) async {
        guard let rule = draft.makeRule(existingRules: rules) else {
            return
        }
        await save(rule: rule)
    }

    public func setRuleEnabled(id: UUID, isEnabled: Bool) async {
        guard let store else {
            guard let index = rules.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else {
                return
            }
            rules[index].isEnabled = isEnabled
            return
        }
        do {
            try await store.setRuleEnabled(id: id, isEnabled: isEnabled)
            rules = try await store.loadRules(settings: settings)
        } catch {
            storeError = error.localizedDescription
        }
    }

    public func deleteRule(id: UUID) async {
        guard let store else {
            return
        }
        do {
            try await store.deleteRule(id: id)
            rules = try await store.loadRules(settings: settings)
        } catch {
            storeError = error.localizedDescription
        }
    }

    public func recordKill(report: KillReport, family: ProcessFamily) async {
        do {
            try await store?.recordAction(
                kind: .kill,
                family: family,
                summary: report.diagnosticText
            )
            try await store?.recordKillOperation(report: report, family: family)
            try await store?.flush()
            RadarLogger.kill.info("Kill report for \(family.displayName, privacy: .public): \(report.summary, privacy: .public)")
        } catch {
            storeError = error.localizedDescription
        }
    }

    public func previewKill(
        family: ProcessFamily,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval? = nil
    ) async -> KillPreview {
        let plan = await killPlan(for: family)
        return await killer.preview(
            plan: plan,
            forceKillDelay: forceKillDelay ?? settings.forceKillDelay
        )
    }

    public func previewIntervention(
        family: ProcessFamily,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval? = nil
    ) async -> KillPreview {
        await previewKill(family: family, killer: killer, forceKillDelay: forceKillDelay)
    }

    public func startIntervention(
        family: ProcessFamily,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval? = nil,
        control: KillOperationControl = KillOperationControl()
    ) async -> AsyncStream<KillOperationEvent> {
        let plan = await killPlan(for: family)
        let runner = KillOperationRunner()
        return await runner.run(
            plan: plan,
            killer: killer,
            forceKillDelay: forceKillDelay ?? settings.forceKillDelay,
            control: control
        )
    }

    public func confirmKill(
        family: ProcessFamily,
        killer: ProcessKiller,
        forceKillDelay: TimeInterval? = nil,
        skipForce: Bool = false,
        control: KillOperationControl? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        let plan = await killPlan(for: family)
        let operationControl = control ?? KillOperationControl()
        if skipForce {
            await operationControl.requestSkipForce()
        }
        let runner = KillOperationRunner()
        let report = await runner.runReport(
            plan: plan,
            killer: killer,
            forceKillDelay: forceKillDelay ?? settings.forceKillDelay,
            control: operationControl,
            eventSink: eventSink
        )
        await recordKill(report: report, family: family)
        await refresh()
        return report
    }

    private func killPlan(for family: ProcessFamily) async -> KillPlan {
        guard let store else {
            return family.killPlan()
        }
        do {
            let history = try await store.killStrategyHistory(
                signatureID: family.signature.id,
                devKind: family.classification?.kind.rawValue
            )
            let gentleCalibration = try await store.killCalibrationSnapshot(
                signatureID: family.signature.id,
                devKind: family.classification?.kind.rawValue,
                strategy: .gentleDevServer
            )
            let stubbornCalibration = try await store.killCalibrationSnapshot(
                signatureID: family.signature.id,
                devKind: family.classification?.kind.rawValue,
                strategy: .stubbornRunaway
            )
            let standardCalibration = try await store.killCalibrationSnapshot(
                signatureID: family.signature.id,
                devKind: family.classification?.kind.rawValue,
                strategy: .standard
            )
            let calibrations = [gentleCalibration, stubbornCalibration, standardCalibration]
            let calibration = calibrations.max { $0.operationCount < $1.operationCount }
            return family.killPlan(
                killHistory: history,
                killCalibration: calibration?.operationCount == 0 ? nil : calibration
            )
        } catch {
            storeError = error.localizedDescription
            return family.killPlan()
        }
    }

    public func exportIncidentReport() async -> String {
        do {
            return try await store?.exportIncidentReport() ?? "Ghost Process Sniper Incident Report\nPersistence is unavailable."
        } catch {
            return "Ghost Process Sniper Incident Report\nExport failed: \(error.localizedDescription)"
        }
    }

    public func incidents(matching query: IncidentQuery) async -> [RadarIncident] {
        do {
            if let store {
                return try await store.queryIncidents(query)
            }
        } catch {
            storeError = error.localizedDescription
        }
        return query.apply(to: incidents)
    }

    public func ruleMatchPreviews() -> [RuleMatchPreview] {
        consoleSnapshot.rulePreviews
    }

    public func commandAvailability(_ command: RadarCommand, selection: RadarFocusedSelection) -> RadarCommandAvailability {
        RadarCommandCoordinator().availability(for: command, selection: selection, families: families)
    }

    public func commandAvailabilityMap(selection: RadarFocusedSelection) -> [RadarCommand: RadarCommandAvailability] {
        RadarCommandCoordinator().availabilityMap(selection: selection, families: families)
    }

    public func familySelection(after selection: RadarFocusedSelection, direction: Int) -> RadarFocusedSelection {
        RadarCommandCoordinator().selection(after: selection, families: families, direction: direction)
    }

    public func diagnosticsReport() -> String {
        engineDiagnostics.diagnosticsReport
    }

    public func exportDiagnosticsReport() async -> String {
        let live = diagnosticsReport()
        do {
            if let store {
                return live + "\n\n" + (try await store.exportDiagnosticsReport(settings: settings))
            }
        } catch {
            return live + "\n\nStore diagnostics failed: \(error.localizedDescription)"
        }
        return live + "\n\nPersistence is unavailable."
    }

    public func family(signatureID: String) -> ProcessFamily? {
        families.first { $0.familyKey == signatureID || $0.signature.id == signatureID }
    }

    public func detailViewModel(signatureID: String) -> FamilyDetailViewModel? {
        if let detail = detailViewModels[signatureID] {
            return detail
        }
        guard let family = family(signatureID: signatureID) else {
            return nil
        }
        return detailViewModels[family.familyKey] ?? FamilyDetailViewModel(family: family)
    }

    public func snooze(signatureID: String, minutes: TimeInterval = 60) async {
        guard let family = family(signatureID: signatureID) else {
            return
        }
        await snooze(family, minutes: minutes)
    }

    public func ignore(signatureID: String) async {
        guard let family = family(signatureID: signatureID) else {
            return
        }
        await ignore(family)
    }

    nonisolated public static func createDefaultStore() -> RadarStore? {
        try? RadarStore()
    }

    private func loadPersistedSettingsIfNeeded() async {
        guard !didLoadPersistedSettings else {
            return
        }
        didLoadPersistedSettings = true
        do {
            if let loaded = try await store?.loadSettings(defaults: settings) {
                settings = loaded
            }
            rules = try await store?.loadRules(settings: settings) ?? RadarRule.builtIns(settings: settings)
            incidents = try await store?.recentIncidents() ?? []
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func save(rule: RadarRule) async {
        guard let store else {
            rules.append(rule)
            return
        }
        do {
            try await store.saveRule(rule)
            rules = try await store.loadRules(settings: settings)
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func publish(outcome: RefreshOutcome, coalescedRefreshCount: Int) {
        publish(payload: outcome.payload, coalescedRefreshCount: coalescedRefreshCount)
    }

    private func publish(payload: RadarPublishPayload, coalescedRefreshCount: Int) {
        let publishStart = Date()
        var state = payload.state
        let mergedReport = state.performanceMetrics.smoothnessReport.merging(hitchMonitor.report)
        var performance = state.performanceMetrics.updatingSmoothness(
            coalescedRefreshCount: coalescedRefreshCount,
            refreshInFlight: false,
            hitchCount: mergedReport.hitchCount,
            worstHitchMilliseconds: mergedReport.worstHitchMilliseconds,
            latestSpikePhase: mergedReport.latestSpikePhase,
            smoothnessReport: mergedReport
        )
        storeError = state.storeError
        storeHealth = state.storeHealth
        scannerHealth = state.scannerHealth

        let finalPublishCost = Date().timeIntervalSince(publishStart) * 1_000
        hitchMonitor.recordPublish(milliseconds: finalPublishCost)
        let finalReport = performance.smoothnessReport.merging(hitchMonitor.report)
        performance = performance.updatingSmoothness(
            mainActorPublishMilliseconds: finalPublishCost,
            hitchCount: finalReport.hitchCount,
            worstHitchMilliseconds: finalReport.worstHitchMilliseconds,
            latestSpikePhase: finalReport.latestSpikePhase,
            smoothnessReport: finalReport
        )
        let finalEngine = EngineDiagnosticsViewModel(
            metrics: performance,
            health: state.health,
            storeHealth: state.storeHealth,
            storeError: state.storeError,
            summary: state.summary,
            generatedAt: payload.generatedAt
        )
        let finalConsoleSnapshot = state.consoleSnapshot.updatingEngine(
            finalEngine,
            health: state.health,
            generatedAt: payload.generatedAt
        )
        let contentChanged = finalConsoleSnapshot.contentRevision != consoleSnapshot.contentRevision

        engineDiagnostics = finalEngine
        engineStatus = finalConsoleSnapshot.compact.engineStatus
        health = SamplerHealth(
            engineName: state.health.engineName,
            lastSampleDate: state.health.lastSampleDate,
            processCount: state.health.processCount,
            familyCount: contentChanged ? state.health.familyCount : health.familyCount,
            errorMessage: state.health.errorMessage
        )
        if contentChanged {
            families = state.families
            summary = state.summary
            rules = state.rules
            incidents = state.incidents
            model = state.model
            triageFamilies = state.triageFamilies
            detailViewModels = state.detailViewModels
            consoleSnapshot = finalConsoleSnapshot
        }

        if contentChanged {
            viewModel = RadarViewModel(
                summary: state.summary,
                families: state.viewModel.families,
                performance: performance,
                generatedAt: payload.generatedAt
            )
        }
        performanceMetrics = performance
        state = ProcessMonitorPublishedState(
            families: families,
            summary: summary,
            health: health,
            incidents: incidents,
            rules: rules,
            model: model,
            viewModel: viewModel,
            triageFamilies: triageFamilies,
            detailViewModels: detailViewModels,
            consoleSnapshot: consoleSnapshot,
            engineDiagnostics: engineDiagnostics,
            engineStatus: engineStatus,
            performanceMetrics: performance,
            scannerHealth: scannerHealth,
            storeHealth: storeHealth,
            storeError: storeError
        )
        publishedState = state
        notifyPublishedStateObservers(state)
        RadarLogger.performance.debug("Refresh \(performance.lastRefresh.totalMilliseconds, privacy: .public)ms, next \(performance.nextRefreshInterval, privacy: .public)s, publish \(finalPublishCost, privacy: .public)ms, hitches \(performance.hitchCount, privacy: .public), forensics \(performance.forensicsRefreshCount, privacy: .public)/\(performance.forensicsDeferredCount, privacy: .public)")
    }

    private func notifyPublishedStateObservers(_ state: ProcessMonitorPublishedState) {
        let observers = Array(publishedStateObservers.values)
        for observer in observers {
            observer(state)
        }
    }

    private func publish(
        families: [ProcessFamily],
        duplicateClusters: [DuplicateProcessCluster] = [],
        summary: RadarSummary,
        rules: [RadarRule],
        incidents: [RadarIncident],
        health: SamplerHealth,
        generatedAt: Date,
        storeHealth: StoreHealth,
        performance: RadarPerformanceMetrics
    ) {
        let payload = RadarPublishPayload.build(
            families: families,
            duplicateClusters: duplicateClusters,
            summary: summary,
            rules: rules,
            incidents: incidents,
            health: health,
            storeHealth: storeHealth,
            storeError: storeError,
            performance: performance,
            previous: consoleSnapshot,
            generatedAt: generatedAt
        )
        publish(payload: payload, coalescedRefreshCount: performance.coalescedRefreshCount)
    }

    private func refreshedEngineSnapshot(
        snapshot: RadarConsoleSnapshot,
        metrics: RadarPerformanceMetrics,
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        summary: RadarSummary,
        generatedAt: Date
    ) -> RadarConsoleSnapshot {
        snapshot.updatingEngine(
            EngineDiagnosticsViewModel(
                metrics: metrics,
                health: health,
                storeHealth: storeHealth,
                storeError: storeError,
                summary: summary,
                generatedAt: generatedAt
            ),
            health: health,
            generatedAt: generatedAt
        )
    }

    private func metrics(
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
        return RadarPerformanceMetrics(
            mode: settings.performanceMode,
            pressureLevel: scheduler.currentPressure,
            lastRefresh: stats,
            averageRefreshMilliseconds: averageRefreshMilliseconds,
            nextRefreshInterval: nextInterval,
            forensicsDeferredCount: samplerStats.forensicsDeferredCount,
            forensicsRefreshCount: samplerStats.forensicsRefreshCount,
            commandCacheHitCount: samplerStats.commandCacheHitCount,
            storeBacklogCount: storeHealth.backlogCount,
            lastStoreFlushDate: storeHealth.lastFlushDate,
            budget: RadarPerformanceBudget.budget(for: settings.performanceMode),
            scannerHealth: scannerHealth,
            scannerWorkerCount: samplerStats.scannerWorkerCount,
            skippedOptionalWorkCount: samplerStats.skippedOptionalWorkCount,
            scannerTaskCount: samplerStats.scannerTaskCount,
            tinyQueueSequentialCount: samplerStats.tinyQueueSequentialCount,
            samplerAllocationReuseCount: samplerStats.scratchpadReuseCount,
            taskInfoReadCount: samplerStats.taskInfoReadCount,
            reusedProcessRecordCount: samplerStats.reusedRecordCount,
            duplicateClusterCount: duplicateClusterCount,
            promotedDuplicateCandidateCount: promotedDuplicateCandidateCount,
            duplicateDetectorMilliseconds: duplicateDetectorMilliseconds,
            hardwareOffenderCount: hardwareOffenderCount,
            hardwareDetectorMilliseconds: hardwareDetectorMilliseconds
        )
    }

}
