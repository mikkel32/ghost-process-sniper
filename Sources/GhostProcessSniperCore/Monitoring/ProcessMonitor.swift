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
    public private(set) var thermals: ThermalSnapshot = .unknown
    public private(set) var thermalActivity: ThermalActivitySummary = .empty
    /// Every process in the latest sample, for search. Not observed: the
    /// console re-queries on each publish, and views never read it directly.
    @ObservationIgnored public private(set) var sampledProcesses: [ProcessMetrics] = []
    @ObservationIgnored public private(set) var sampleRevision: UInt64 = 0

    @ObservationIgnored private let thermalSampler = ThermalSampler()
    @ObservationIgnored private var selfUsageMonitor = SelfUsageMonitor()
    @ObservationIgnored private let notifier: RadarNotifying
    @ObservationIgnored private let store: RadarStore?
    @ObservationIgnored private let worker: RadarRefreshWorker
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The only path into the worker: NativeProcessSampler.sample reuses
    /// scratch buffers across awaits and must never run concurrently.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// One queued rerun shared by every caller that arrived mid-refresh.
    @ObservationIgnored private var trailing: Task<Void, Never>?
    @ObservationIgnored private(set) var coalescedCount = 0
    @ObservationIgnored private(set) var rerunCount = 0
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadPersistedSettings = false
    @ObservationIgnored private var popoverVisible = false
    @ObservationIgnored private var focusedSignatureIDs: Set<String> = []
    @ObservationIgnored private var portCensusRequested = false
    @ObservationIgnored private var lastCompletedPublishMilliseconds = 0.0
    @ObservationIgnored private let hitchMonitor = MainActorHitchMonitor()
    @ObservationIgnored private var publishedStateObservers: [UUID: (ProcessMonitorPublishedState) -> Void] = [:]

    public var statusLevel: GhostLevel {
        summary.level
    }

    public var resolvedThresholdProfile: ResolvedThresholdProfile {
        settings.resolvedProfile(systemPressure: systemPressure)
    }

    public init(
        sampler: ProcessSampling = NativeProcessSampler(),
        builder: ProcessFamilyBuilder = ProcessFamilyBuilder(),
        intelligence: RadarIntelligence = RadarIntelligence(),
        settings: ThresholdSettings = .smart,
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
                await self?.refresh(reason: .loop)
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

    /// Samples and publishes. A call that arrives while a refresh is running
    /// returns only after a sample that started after the call: callers
    /// share one trailing rerun. Loop ticks just join the running refresh.
    public func refresh(reason: RefreshReason = .user, now: Date? = nil) async {
        guard let running = inFlight else {
            let task = Task { await self.performRefresh(now: now ?? Date()) }
            inFlight = task
            await task.value
            return
        }
        coalescedCount += 1
        guard reason != .loop else {
            await running.value
            return
        }
        if trailing == nil {
            trailing = Task {
                await running.value
                self.trailing = nil
                self.rerunCount += 1
                let rerun = Task { await self.performRefresh(now: Date()) }
                self.inFlight = rerun
                await rerun.value
            }
        }
        await trailing?.value
    }

    private func performRefresh(now: Date) async {
        defer { inFlight = nil }
        let refreshStart = Date()
        let signpost = RadarLogger.signposter
        let refreshState = signpost.beginInterval("RadarRefresh")
        defer { signpost.endInterval("RadarRefresh", refreshState) }

        do {
            thermals = await thermalSampler.sample(now: now)
            let outcome = try await worker.refresh(refreshRequest(now: now, startedAt: refreshStart))
            let usage = selfUsageMonitor.sample()
            if usage != selfUsage {
                selfUsage = usage
                if usage.isThrottling {
                    RadarLogger.sampler.info("Self-throttle active: radar averaging \(Int(usage.averageCPUPercent.rounded()), privacy: .public)% CPU")
                }
            }
            apply(outcome, coalescedRefreshCount: coalescedCount)
            await notifier.process(model: model)
        } catch {
            var metrics = performanceMetrics
            metrics.smoothness.coalescedRefreshCount = coalescedCount
            metrics.smoothness.refreshInFlight = false
            performanceMetrics = metrics
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

    /// Runs injected processes through the same worker pipeline as a live
    /// refresh, without sampling or notifying. Used by tests and previews.
    public func ingest(_ processes: [ProcessMetrics], now: Date = Date()) async {
        let batch = ProcessSampleBatch(processes: processes, sampledAt: now, stats: .empty)
        let outcome = await worker.ingest(batch: batch, request: refreshRequest(now: now, startedAt: now))
        apply(outcome, coalescedRefreshCount: 0)
    }

    private func refreshRequest(now: Date, startedAt: Date) -> RefreshRequest {
        defer { portCensusRequested = false }
        return RefreshRequest(
            settings: settings,
            currentFamilies: families,
            currentIncidents: incidents,
            currentStoreHealth: storeHealth,
            previousRefresh: performanceMetrics.lastRefresh,
            previousConsoleSnapshot: consoleSnapshot,
            popoverVisible: popoverVisible,
            focusedSignatureIDs: focusedSignatureIDs,
            portCensusRequested: portCensusRequested,
            now: now,
            startedAt: startedAt
        )
    }

    private func apply(_ outcome: RefreshOutcome, coalescedRefreshCount: Int) {
        if outcome.systemPressure != systemPressure {
            systemPressure = outcome.systemPressure
        }
        thermalActivity = outcome.thermalActivity
        recordSample(outcome.processes)
        publish(payload: outcome.payload, coalescedRefreshCount: coalescedRefreshCount)
    }

    private func recordSample(_ processes: [ProcessMetrics]) {
        sampledProcesses = processes
        sampleRevision &+= 1
    }

    public func recordStatusUpdateCost(_ milliseconds: Double) {
        var updated = performanceMetrics
        updated.smoothness.statusUpdateMilliseconds = milliseconds
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
        settingsSaveTask = DebouncedTask.schedule(delay: delay) { [store] in
            try? await store?.saveSettings(settings)
        }
    }

    public func focusFamilies(signatureIDs: Set<String>) {
        focusedSignatureIDs = signatureIDs
    }

    /// Reads every same-user process's listening ports on the next refresh and
    /// starts that refresh now, so `port:3000` finds a quiet server.
    public func requestPortCensus() {
        portCensusRequested = true
        Task { await refresh() }
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

    public func confirmKill(
        family: ProcessFamily,
        killer: ProcessKiller,
        approvedPlan: KillPlan? = nil,
        forceKillDelay: TimeInterval? = nil,
        skipForce: Bool = false,
        control: KillOperationControl? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        let plan: KillPlan
        if let approvedPlan { plan = approvedPlan }
        else { plan = await killPlan(for: family) }
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

    public func killPlan(for family: ProcessFamily) async -> KillPlan {
        let workload = KillWorkloadProfile(family: family, sample: sampledProcesses)
        guard let store else {
            return family.killPlan(workload: workload)
        }
        do {
            let devKind = family.classification?.kind.rawValue
            let history = try await store.killStrategyHistory(signatureID: family.signature.id, devKind: devKind)
            var calibrations: [KillStrategy: KillCalibrationSnapshot] = [:]
            for strategy in KillStrategy.allCases where strategy != .inspectOnly {
                let snapshot = try await store.killCalibrationSnapshot(
                    signatureID: family.signature.id,
                    devKind: devKind,
                    strategy: strategy
                )
                if snapshot.operationCount > 0 { calibrations[strategy] = snapshot }
            }
            return family.killPlan(killHistory: history, workload: workload, strategyCalibrations: calibrations)
        } catch {
            storeError = error.localizedDescription
            return family.killPlan(workload: workload)
        }
    }

    public func exportIncidentReport() async -> String {
        do {
            return try await store?.exportIncidentReport() ?? "Ghost Process Sniper Incident Report\nPersistence is unavailable."
        } catch {
            return "Ghost Process Sniper Incident Report\nExport failed: \(error.localizedDescription)"
        }
    }

    public func commandAvailability(_ command: RadarCommand, selection: RadarFocusedSelection) -> RadarCommandAvailability {
        RadarCommandCoordinator().availability(for: command, selection: selection, families: families)
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

    private func publish(payload: RadarPublishPayload, coalescedRefreshCount: Int) {
        let publishStart = Date()
        // Measure assignments and observer callbacks too. Report the last
        // completed publish on the next refresh, without self-triggering a loop.
        defer {
            lastCompletedPublishMilliseconds = Date().timeIntervalSince(publishStart) * 1_000
            hitchMonitor.recordPublish(milliseconds: lastCompletedPublishMilliseconds)
        }
        var state = payload.state
        var performance = state.performanceMetrics
        performance.smoothness.coalescedRefreshCount = coalescedRefreshCount
        performance.smoothness.refreshInFlight = false
        performance.smoothness.record(performance.smoothness.smoothnessReport.merging(hitchMonitor.report))
        storeError = state.storeError
        storeHealth = state.storeHealth
        scannerHealth = state.scannerHealth

        let finalPublishCost = lastCompletedPublishMilliseconds
        performance.smoothness.mainActorPublishMilliseconds = finalPublishCost
        performance.smoothness.record(performance.smoothness.smoothnessReport.merging(hitchMonitor.report))
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
        let contentChanged = payload.delta.mode == .contentChanged ||
            finalConsoleSnapshot.contentRevision != consoleSnapshot.contentRevision

        engineDiagnostics = finalEngine
        engineStatus = finalConsoleSnapshot.compact.engineStatus
        health = SamplerHealth(
            engineName: state.health.engineName,
            lastSampleDate: state.health.lastSampleDate,
            processCount: state.health.processCount,
            familyCount: contentChanged ? state.health.familyCount : health.familyCount,
            errorMessage: state.health.errorMessage
        )
        // Rendering buckets are not a data cache. Stable displayed numbers
        // must never freeze measurement timestamps or intervention inputs.
        families = state.families
        model = state.model
        if contentChanged {
            summary = state.summary
            rules = state.rules
            incidents = state.incidents
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
        RadarLogger.performance.debug("Refresh \(performance.lastRefresh.totalMilliseconds, privacy: .public)ms, next \(performance.nextRefreshInterval, privacy: .public)s, publish \(finalPublishCost, privacy: .public)ms, hitches \(performance.smoothness.hitchCount, privacy: .public), forensics \(performance.forensicsRefreshCount, privacy: .public)/\(performance.forensicsDeferredCount, privacy: .public)")
    }

    private func notifyPublishedStateObservers(_ state: ProcessMonitorPublishedState) {
        let observers = Array(publishedStateObservers.values)
        for observer in observers {
            observer(state)
        }
    }
}
