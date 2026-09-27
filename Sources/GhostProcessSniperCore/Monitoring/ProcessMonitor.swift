import Darwin
import Foundation
import Observation

@MainActor
@Observable
public final class ProcessMonitor {
    public var settings: ThresholdSettings
    public private(set) var families: [ProcessFamily] = []
    public private(set) var summary: RadarSummary = .empty
    /// Counts and errors only; the per-tick time is `lastSampleDate`, so
    /// readers of the counts do not re-render every tick.
    public private(set) var health: SamplerHealth = .starting
    public private(set) var lastSampleDate: Date?
    public private(set) var incidents: [RadarIncident] = []
    public private(set) var rules: [RadarRule] = []
    public private(set) var model: RadarModel = .empty
    public private(set) var triageFamilies: [FamilyTriageViewModel] = []
    public private(set) var consoleSnapshot: RadarConsoleSnapshot = .empty
    public private(set) var engineDiagnostics: EngineDiagnosticsViewModel = .empty
    public private(set) var engineStatus: EngineStatusSnapshot = .empty
    public private(set) var performanceMetrics: RadarPerformanceMetrics = .empty
    public private(set) var scannerHealth: ScannerHealthSnapshot = .starting
    public private(set) var storeHealth: StoreHealth = .empty
    public internal(set) var storeError: String?
    public private(set) var publishedState: ProcessMonitorPublishedState = .empty
    public private(set) var systemPressure: SystemMemoryPressure = .unknown
    public private(set) var selfUsage: SelfResourceUsage = .unknown
    public private(set) var thermals: ThermalSnapshot = .unknown
    public private(set) var thermalObservations = ThermalObservationWindow()
    public private(set) var thermalActivity: ThermalActivitySummary = .empty
    /// Security findings, the launch feed and the privacy sensors.
    public internal(set) var sentinel: SentinelReport = .empty
    /// Energy per app, the battery and sleep blockers; changes every scan.
    public private(set) var energy: EnergyReport = .empty
    /// The slice of `energy` the menu bar and Overview show; changes rarely.
    public private(set) var energyGlance: EnergyGlance = .empty
    @ObservationIgnored let sentinelEngine: SentinelEngine?
    /// Every process in the latest sample, for search. Not observed: the
    /// console re-queries on each publish, and views never read it directly.
    @ObservationIgnored public private(set) var sampledProcesses: [ProcessMetrics] = []
    @ObservationIgnored public private(set) var sampleRevision: UInt64 = 0
    @ObservationIgnored var stopRiskCache = StopRiskCache()

    @ObservationIgnored private let thermalSampler: any ThermalSampling
    @ObservationIgnored var lastThermalReadAt: Date?
    @ObservationIgnored private var selfUsageMonitor = SelfUsageMonitor()
    @ObservationIgnored let notifier: RadarNotifying
    @ObservationIgnored var notifyTask: Task<Void, Never>?
    @ObservationIgnored var pendingNotification: RadarModel?
    @ObservationIgnored let store: RadarStore?
    @ObservationIgnored let worker: RadarRefreshWorker
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The loop's current sleep; cancelling it runs the next tick now.
    @ObservationIgnored var sleeper: Task<Void, Never>?
    @ObservationIgnored var wakePending = false
    /// The only path into the worker: NativeProcessSampler.sample reuses
    /// scratch buffers across awaits and must never run concurrently.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// One queued rerun shared by every caller that arrived mid-refresh.
    @ObservationIgnored private var trailing: Task<Void, Never>?
    @ObservationIgnored private(set) var coalescedCount = 0
    @ObservationIgnored private(set) var rerunCount = 0
    @ObservationIgnored var postKillTask: Task<Void, Never>?
    @ObservationIgnored var activeStopCount = 0
    @ObservationIgnored var activeStopWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored var didLoadPersistedSettings = false
    /// What `settings` held before the stored settings loaded; a field that
    /// differs from it was edited and wins over the stored value.
    @ObservationIgnored let settingsBeforeLoad: ThresholdSettings
    @ObservationIgnored var settingsLoad: Task<Bool, Never>?
    @ObservationIgnored var visibleSurfaces: Set<RadarSurface> = []
    @ObservationIgnored private var focusedSignatureIDs: Set<String> = []
    @ObservationIgnored private var portCensusRequested = false
    @ObservationIgnored private var lastCompletedPublishMilliseconds = 0.0
    @ObservationIgnored let hitchMonitor = MainActorHitchMonitor()
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
        notifier: RadarNotifying = NoopRadarNotifier(),
        thermalSampler: any ThermalSampling = ThermalSampler(),
        sentinel: SentinelEngine.Live? = nil,
        sentinelTrust: SentinelTrustStore? = .standard,
        battery: (any BatterySource)? = IOKitBatterySource(),
        sleepAssertions: (any SleepAssertionSource)? = IOKitSleepAssertionSource()
    ) {
        self.settings = settings
        settingsBeforeLoad = settings
        self.store = store
        self.thermalSampler = thermalSampler
        self.notifier = notifier
        let relay = SentinelWakeRelay()
        let engine = sentinel.map { SentinelEngine(live: $0, trustStore: sentinelTrust, onUrgentSpawn: { relay.fire() }) }
        sentinelEngine = engine
        self.worker = RadarRefreshWorker(
            sampler: sampler,
            store: store,
            builder: builder,
            intelligence: intelligence,
            sentinel: engine,
            battery: battery,
            sleepAssertions: sleepAssertions
        )
        // A browser or mail app starting a shell is worth a scan now, not at
        // the next tick; the relay lets the watcher ask without owning us.
        relay.setHandler { [weak self] in
            Task { @MainActor in self?.wakeForSentinel() }
        }
    }

    deinit {
        refreshTask?.cancel()
        sleeper?.cancel()
        settingsSaveTask?.cancel()
        notifyTask?.cancel()
    }

    public func start() {
        stop()
        wakePending = false
        // Utility QoS keeps hidden sampling, scoring and store work off the
        // performance cores; a visible caller awaiting it escalates it.
        refreshTask = Task(priority: .utility) { @MainActor [weak self] in
            var isFirstTick = true
            while !Task.isCancelled {
                // Retried every tick until it succeeds: saves wait for it.
                await self?.loadPersistedSettingsIfNeeded()
                guard let interval = await self?.runLoopTick(isFirstTick: isFirstTick) else { return }
                isFirstTick = false
                let sleeper = self?.startSleepUntilNextTick(interval)
                await sleeper?.value
            }
        }
        updateHitchMonitor()
    }

    var isRunning: Bool {
        refreshTask != nil
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        sleeper?.cancel()
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        pendingNotification = nil
        updateHitchMonitor()
        Task { [store] in
            try? await store?.flush()
        }
    }

    /// Samples and publishes. A call that arrives while a refresh is running
    /// returns only after a sample that started after the call: callers
    /// share one trailing rerun. Loop ticks just join the running refresh.
    public func refresh(reason: RefreshReason = .user, now: Date? = nil) async {
        guard let running = inFlight else {
            await launchRefresh(now: now ?? Date()).value
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
                // A caller may have started a refresh in the gap after the
                // running one ended; it began after every waiter, so join it.
                if let fresh = self.inFlight {
                    await fresh.value
                    return
                }
                self.rerunCount += 1
                await self.launchRefresh(now: Date()).value
            }
        }
        await trailing?.value
    }

    /// Only called while nothing is in flight.
    private func launchRefresh(now: Date) -> Task<Void, Never> {
        let task = Task { await self.performRefresh(now: now) }
        inFlight = task
        return task
    }

    private func performRefresh(now: Date) async {
        defer { inFlight = nil }
        let refreshStart = Date()
        let signpost = RadarLogger.signposter
        let refreshState = signpost.beginInterval("RadarRefresh")
        defer { signpost.endInterval("RadarRefresh", refreshState) }

        do {
            if readsThermals(at: now) {
                lastThermalReadAt = now
                let sampled = await thermalSampler.sample(now: now)
                if let next = ThermalSnapshotStore.update(thermals, thermalObservations, with: sampled, at: now) { (thermals, thermalObservations) = next }
            }
            let outcome = try await worker.refresh(refreshRequest(now: now, startedAt: refreshStart))
            let usage = selfUsageMonitor.sample(
                throttleAbovePercent: uiVisible ? .infinity : 2 * outcome.performance.budget.targetIdleCPUPercent
            )
            if usage != selfUsage {
                if usage.isThrottling, !selfUsage.isThrottling {
                    RadarLogger.sampler.info("Self-throttle active: radar averaging \(String(format: "%.2f", usage.averageCPUPercent), privacy: .public)% CPU")
                }
                selfUsage = usage
            }
            apply(outcome)
            scheduleNotification(for: model)
        } catch {
            var metrics = performanceMetrics
            metrics.smoothness.coalescedRefreshCount = coalescedCount
            metrics.smoothness.refreshInFlight = false
            performanceMetrics = metrics
            health = SamplerHealth(
                engineName: "libproc",
                lastSampleDate: nil,
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
        apply(outcome)
    }

    private func refreshRequest(now: Date, startedAt: Date) -> RefreshRequest {
        defer { portCensusRequested = false }
        return RefreshRequest(
            settings: settings,
            currentFamilies: families,
            currentIncidents: incidents,
            currentStoreHealth: storeHealth,
            previousConsoleSnapshot: consoleSnapshot,
            uiVisible: uiVisible,
            focusedSignatureIDs: focusedSignatureIDs,
            portCensusRequested: portCensusRequested,
            hitchReport: hitchMonitor.report,
            lastPublishMilliseconds: lastCompletedPublishMilliseconds,
            coalescedRefreshCount: coalescedCount,
            now: now,
            startedAt: startedAt
        )
    }

    private func apply(_ outcome: RefreshOutcome) {
        if outcome.systemPressure != systemPressure {
            systemPressure = outcome.systemPressure
        }
        if outcome.thermalActivity != thermalActivity {
            thermalActivity = outcome.thermalActivity
        }
        if outcome.sentinel != sentinel {
            sentinel = outcome.sentinel
        }
        if outcome.energy != energy { energy = outcome.energy }
        let glance = EnergyGlance(outcome.energy)
        if glance != energyGlance { energyGlance = glance }
        recordSample(outcome.processes)
        publish(payload: outcome.payload)
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
        setSurface(.popover, visible: visible)
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

    public func recordKill(report: KillReport, family: ProcessFamily, learnsFromOutcome: Bool = true) async {
        do {
            try await store?.recordAction(kind: .kill, family: family, summary: report.diagnosticText)
            try await store?.recordKillOperation(report: report, family: family, learnsFromOutcome: learnsFromOutcome)
            try await store?.flush()
            RadarLogger.kill.info("Kill report for \(family.displayName, privacy: .public): \(report.summary, privacy: .public)")
        } catch {
            storeError = error.localizedDescription
        }
    }

    /// Returns as soon as the processes are handled. Recording and the
    /// radar refresh follow in order, and the next plan waits for them.
    public func confirmKill(
        family: ProcessFamily,
        killer: ProcessKiller,
        approvedPlan: KillPlan? = nil,
        forceKillDelay: TimeInterval? = nil,
        skipForce: Bool = false,
        learnsFromOutcome: Bool = true,
        control: KillOperationControl? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        beginStop()
        defer { endStop() }
        await postKillTask?.value
        let plan = if let approvedPlan { approvedPlan } else { await killPlan(for: family) }
        let operationControl = control ?? KillOperationControl()
        if skipForce { await operationControl.holdForce() }
        let report = await KillOperationRunner().runReport(plan: plan, killer: killer, forceKillDelay: forceKillDelay ?? settings.forceKillDelay,
                                                           control: operationControl, eventSink: eventSink)
        // Behind any batch recorded while this stop ran.
        enqueuePostKill { monitor in
            await monitor.recordKill(report: report, family: family, learnsFromOutcome: learnsFromOutcome)
            await monitor.refresh()
        }
        return report
    }

    public func killPlan(for family: ProcessFamily) async -> KillPlan {
        await postKillTask?.value
        let workload = stopWorkload(for: family)
        guard let store else { return family.killPlan(workload: workload) }
        do {
            let history = try await store.killStrategyHistory(signatureID: family.signature.id)
            let outcomes = try await store.killOutcomeHistory(signatureID: family.signature.id,
                                                              devKind: family.classification?.kind.rawValue)
            return family.killPlan(killHistory: history, workload: workload, strategyCalibrations: outcomes)
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
        EngineDiagnosticsViewModel.diagnosticsReport(
            metrics: performanceMetrics,
            health: health,
            storeHealth: storeHealth,
            storeError: storeError,
            summary: summary,
            generatedAt: Date()
        )
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
        RadarStore()
    }

    /// Shown until the first refresh publishes its own.
    func loadStoredRulesAndIncidents() async {
        do {
            rules = try await store?.loadRules(settings: settings) ?? RadarRule.builtIns(settings: settings)
            incidents = try await store?.recentIncidents() ?? []
        } catch {
            storeError = error.localizedDescription
        }
    }

    public func save(rule: RadarRule) async {
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

    /// The worker already folded in the hitch report and last publish cost
    /// and built the engine diagnostics, so this only assigns what changed.
    private func publish(payload: RadarPublishPayload) {
        let publishStart = Date()
        // Measure assignments and observer callbacks too. Report the last
        // completed publish on the next refresh, without self-triggering a loop.
        defer {
            lastCompletedPublishMilliseconds = Date().timeIntervalSince(publishStart) * 1_000
            hitchMonitor.recordPublish(milliseconds: lastCompletedPublishMilliseconds)
        }
        var state = payload.state
        var performance = state.performanceMetrics
        performance.smoothness.refreshInFlight = false
        let nextStoreError = state.storeError ?? state.storeHealth.errorMessage
        if storeError != nextStoreError { storeError = nextStoreError }
        if storeHealth != state.storeHealth { storeHealth = state.storeHealth }
        if scannerHealth != state.scannerHealth { scannerHealth = state.scannerHealth }
        let contentChanged = payload.delta.mode == .contentChanged ||
            state.consoleSnapshot.contentRevision != consoleSnapshot.contentRevision

        if engineDiagnostics != state.engineDiagnostics { engineDiagnostics = state.engineDiagnostics }
        if engineStatus != state.engineStatus { engineStatus = state.engineStatus }
        let nextHealth = SamplerHealth(
            engineName: state.health.engineName,
            lastSampleDate: nil,
            processCount: state.health.processCount,
            familyCount: contentChanged ? state.health.familyCount : health.familyCount,
            errorMessage: state.health.errorMessage
        )
        if nextHealth != health { health = nextHealth }
        lastSampleDate = state.health.lastSampleDate
        // Rendering buckets are not a data cache. Stable displayed numbers
        // must never freeze measurement timestamps or intervention inputs.
        families = state.families
        model = state.model
        if contentChanged {
            summary = state.summary
            rules = state.rules
            incidents = state.incidents
            triageFamilies = state.triageFamilies
            consoleSnapshot = state.consoleSnapshot
        }
        if performance != performanceMetrics { performanceMetrics = performance }
        state = ProcessMonitorPublishedState(
            families: families,
            summary: summary,
            health: health,
            incidents: incidents,
            rules: rules,
            model: model,
            triageFamilies: triageFamilies,
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
        RadarLogger.performance.debug("Refresh \(performance.lastRefresh.totalMilliseconds, privacy: .public)ms, next \(performance.nextRefreshInterval, privacy: .public)s, publish \(performance.mainActorPublishMilliseconds, privacy: .public)ms, hitches \(performance.smoothness.hitchCount, privacy: .public), forensics \(performance.forensicsRefreshCount, privacy: .public)/\(performance.forensicsDeferredCount, privacy: .public)")
    }

    private func notifyPublishedStateObservers(_ state: ProcessMonitorPublishedState) {
        let observers = Array(publishedStateObservers.values)
        for observer in observers {
            observer(state)
        }
    }
}
