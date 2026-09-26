import Darwin
import Foundation
import GhostProcessSniperCore

@main
struct CoreChecks {
    @MainActor
    static func main() async throws {
        var failures: [String] = []
        var completed = 0
        func run(_ name: String, _ action: @MainActor () async throws -> Void) async {
            do { try await action() } catch {
                let failure = "\(name): \(error)"
                failures.append(failure)
                print("FAILED: " + failure)
            }
            completed += 1
        }
        await run("nativeSamplerSeesCurrentProcess") { try await nativeSamplerSeesCurrentProcess() }
        await run("nativeKillSnapshotProviderUsesLitePath") { try await nativeKillSnapshotProviderUsesLitePath() }
        await run("nativeSamplerDefersForensicsWhenPlanRequestsIt") { try await nativeSamplerDefersForensicsWhenPlanRequestsIt() }
        await run("nativeSamplerUsesBSDFirstCheapGraph") { try await nativeSamplerUsesBSDFirstCheapGraph() }
        await run("classifierScoresDevProcesses") { try classifierScoresDevProcesses() }
        await run("classifierProducesProcessKinds") { try classifierProducesProcessKinds() }
        await run("duplicateDetectorCapturesSmallSameUserProcesses") { try duplicateDetectorCapturesSmallSameUserProcesses() }
        await run("duplicateDetectorIgnoresSingletonsAndSystemBundles") { try duplicateDetectorIgnoresSingletonsAndSystemBundles() }
        await run("duplicateDetectorSeparatesIndependentRootsFromInternalHelpers") { try duplicateDetectorSeparatesIndependentRootsFromInternalHelpers() }
        await run("familyBuilderGroupsElectronStyleFamilies") { try familyBuilderGroupsElectronStyleFamilies() }
        await run("familyBuilderKeepsRadarUsefulInDevMode") { try familyBuilderKeepsRadarUsefulInDevMode() }
        await run("familyBuilderPromotesGenericHardwareOffenders") { try familyBuilderPromotesGenericHardwareOffenders() }
        await run("familyBuilderSurfacesGPUHardwareSignals") { try familyBuilderSurfacesGPUHardwareSignals() }
        await run("ghostScoreInfersTypedComponents") { try ghostScoreInfersTypedComponents() }
        await run("triageViewModelsFilterAndSort") { try triageViewModelsFilterAndSort() }
        await run("incidentQueryFiltersAndSorts") { try incidentQueryFiltersAndSorts() }
        await run("ruleDraftRejectsDuplicates") { try ruleDraftRejectsDuplicates() }
        await run("radarCommandRouterRespectsSelection") { try radarCommandRouterRespectsSelection() }
        await run("radarCommandCoordinatorNavigatesFamilies") { try radarCommandCoordinatorNavigatesFamilies() }
        await run("consoleSnapshotPrecomputesStableRows") { try consoleSnapshotPrecomputesStableRows() }
        await run("consoleDerivedSnapshotCachesRows") { try consoleDerivedSnapshotCachesRows() }
        await run("compactDefaultsAndEngineIsolationBehave") { try compactDefaultsAndEngineIsolationBehave() }
        await run("consoleSnapshotSurfacesPredictiveQueues") { try consoleSnapshotSurfacesPredictiveQueues() }
        await run("ruleMatchPreviewCountsLiveFamilies") { try ruleMatchPreviewCountsLiveFamilies() }
        await run("trendWindowComputesLeakVelocity") { try trendWindowComputesLeakVelocity() }
        await run("riskForecasterPredictsETAAndState") { try riskForecasterPredictsETAAndState() }
        await run("riskForecasterSuppressesQuietNoise") { try riskForecasterSuppressesQuietNoise() }
        await run("riskForecasterDetectsStaleAndRecurringFamilies") { try riskForecasterDetectsStaleAndRecurringFamilies() }
        await run("riskForecasterDetectsLeakAcceleration") { try riskForecasterDetectsLeakAcceleration() }
        await run("trendWindowRegressionResistsEndpointSpikes") { try trendWindowRegressionResistsEndpointSpikes() }
        await run("riskForecasterDiscountsNoisyImminentForecasts") { try riskForecasterDiscountsNoisyImminentForecasts() }
        await run("memoryPatternAnalyzerClassifiesShapes") { try memoryPatternAnalyzerClassifiesShapes() }
        await run("riskForecasterTreatsSawtoothAsChurn") { try riskForecasterTreatsSawtoothAsChurn() }
        await run("systemPressureBoostsLargeFamilies") { try systemPressureBoostsLargeFamilies() }
        await run("familyVerdictSynthesizesJudgment") { try familyVerdictSynthesizesJudgment() }
        await run("riskForecasterRequiresSustainedCPUEvidence") { try riskForecasterRequiresSustainedCPUEvidence() }
        await run("startupGraceDelaysLeakCalls") { try startupGraceDelaysLeakCalls() }
        await run("decliningFamiliesEaseOff") { try decliningFamiliesEaseOff() }
        await run("selfUsageMonitorMeasuresOwnCost") { try selfUsageMonitorMeasuresOwnCost() }
        await run("scannerDeadlineAndCachesBehave") { try scannerDeadlineAndCachesBehave() }
        await run("scannerHealthFeedsDiagnostics") { try scannerHealthFeedsDiagnostics() }
        await run("gpuUsageTrackerComputesDeltaPercent") { try gpuUsageTrackerComputesDeltaPercent() }
        await run("spikeRingBufferBoundsReports") { try spikeRingBufferBoundsReports() }
        await run("samplerExecutionPlanScalesAndCounts") { try samplerExecutionPlanScalesAndCounts() }
        await run("radarPublishPayloadSkipsUnchangedContentRebuild") { try radarPublishPayloadSkipsUnchangedContentRebuild() }
        await run("menuBarStatusPresentationIsIconOnlyAndCompact") { try menuBarStatusPresentationIsIconOnlyAndCompact() }
        await run("menuBarPresentationKeepsDiagnosticsOutOfTitle") { try menuBarPresentationKeepsDiagnosticsOutOfTitle() }
        await run("refreshGateCoalescesOverlappingRequests") { try await refreshGateCoalescesOverlappingRequests() }
        await run("radarRefreshWorkerPublishesStableOutcome") { try await radarRefreshWorkerPublishesStableOutcome() }
        await run("radarSchedulerAdaptsCadence") { try radarSchedulerAdaptsCadence() }
        await run("radarSchedulerFocusesSelectedFamilies") { try radarSchedulerFocusesSelectedFamilies() }
        await run("radarPipelineDiffsAndHoldsLevels") { try radarPipelineDiffsAndHoldsLevels() }
        await run("familyScoringCacheReusesUnchangedFamilies") { try familyScoringCacheReusesUnchangedFamilies() }
        await run("monitorPublishesRadarSummary") { try monitorPublishesRadarSummary() }
        await run("monitorPublishedStateObserversCanBeRemoved") { try monitorPublishedStateObserversCanBeRemoved() }
        await run("monitorDiagnosticsOnlyPublishKeepsViewModelStable") { try monitorDiagnosticsOnlyPublishKeepsViewModelStable() }
        await run("monitorPublishObserversCanMutateRegistrationDuringCallback") { try monitorPublishObserversCanMutateRegistrationDuringCallback() }
        await run("radarStorePersistsSettingsRulesAndIncidents") { try await radarStorePersistsSettingsRulesAndIncidents() }
        await run("radarStoreQueriesIncidentsAndTogglesRules") { try await radarStoreQueriesIncidentsAndTogglesRules() }
        await run("radarStorePersistsForecastSnapshots") { try await radarStorePersistsForecastSnapshots() }
        await run("radarStoreCoalescesRecommendationHistory") { try await radarStoreCoalescesRecommendationHistory() }
        await run("monitorDebouncesSettingsPersistence") { try await monitorDebouncesSettingsPersistence() }
        await run("radarStoreBatchesQueuedWrites") { try await radarStoreBatchesQueuedWrites() }
        await run("radarStoreSkipsUnchangedSettingsAndBatchesContext") { try await radarStoreSkipsUnchangedSettingsAndBatchesContext() }
        await run("radarStoreCachesQuietRuleContext") { try await radarStoreCachesQuietRuleContext() }
        await run("radarIntelligenceEscalatesBaselineAnomalies") { try radarIntelligenceEscalatesBaselineAnomalies() }
        await run("culpritAnalysisExplainsLikelyCause") { try culpritAnalysisExplainsLikelyCause() }
        await run("radarRuleEngineMatchesAdvisoryRules") { try radarRuleEngineMatchesAdvisoryRules() }
        await run("monitorPersistsIncidentsWithInjectedStore") { try await monitorPersistsIncidentsWithInjectedStore() }
        await run("radarPipelineHandlesLargeSamplesWithinBudget") { try radarPipelineHandlesLargeSamplesWithinBudget() }
        await run("consoleSnapshotContentRevisionAvoidsGeneratedAtInvalidation") { try consoleSnapshotContentRevisionAvoidsGeneratedAtInvalidation() }
        await run("radarSnapshotSurfacesDuplicateRowsAndStableRevision") { try radarSnapshotSurfacesDuplicateRowsAndStableRevision() }
        await run("radarPublishPayloadPrecomputesViewState") { try radarPublishPayloadPrecomputesViewState() }
        await run("processKillerTerminatesKillPlanInTreeOrder") { try await processKillerTerminatesKillPlanInTreeOrder() }
        await run("processKillerEscalatesSurvivingIdentities") { try await processKillerEscalatesSurvivingIdentities() }
        await run("processKillerRejectsRecycledPID") { try await processKillerRejectsRecycledPID() }
        await run("processKillerDeniesForeignProcesses") { try await processKillerDeniesForeignProcesses() }
        await run("processKillerPreviewsKillPlan") { try await processKillerPreviewsKillPlan() }
        await run("processKillerPreviewsNewOwnedDescendants") { try await processKillerPreviewsNewOwnedDescendants() }
        await run("processKillerSkipsExitedTargetsBeforeEscalation") { try await processKillerSkipsExitedTargetsBeforeEscalation() }
        await run("processKillerDetectsRecycledPIDDuringEscalation") { try await processKillerDetectsRecycledPIDDuringEscalation() }
        await run("processKillerUsesCheapSnapshotPolicy") { try await processKillerUsesCheapSnapshotPolicy() }
        await run("processKillerUsesDedicatedSnapshotProvider") { try await processKillerUsesDedicatedSnapshotProvider() }
        await run("processKillerSkipForceReportsSurvivors") { try await processKillerSkipForceReportsSurvivors() }
        await run("processKillerRecordsMultiPassVerification") { try await processKillerRecordsMultiPassVerification() }
        await run("processKillerClassifiesExitedBeforeSignal") { try await processKillerClassifiesExitedBeforeSignal() }
        await run("processKillerReportsReclaimEstimate") { try await processKillerReportsReclaimEstimate() }
        await run("nativeKillSnapshotProviderUsesBSDGraphAndTargetMetrics") { try await nativeKillSnapshotProviderUsesBSDGraphAndTargetMetrics() }
        await run("killGraphArenaIndexesAndSlicesOwnedFamily") { try killGraphArenaIndexesAndSlicesOwnedFamily() }
        await run("nativeKillSnapshotProviderReturnsArenaStats") { try await nativeKillSnapshotProviderReturnsArenaStats() }
        await run("killGraphArenaReusesIndexesAndSortsNeighbors") { try killGraphArenaReusesIndexesAndSortsNeighbors() }
        await run("nativeKillSnapshotProviderSupportsTargetOnlyVerification") { try await nativeKillSnapshotProviderSupportsTargetOnlyVerification() }
        await run("nativeKillSnapshotProviderLimitsProcessMetricConversion") { try await nativeKillSnapshotProviderLimitsProcessMetricConversion() }
        await run("processKillerSurfacesProcessGroupNeighbors") { try await processKillerSurfacesProcessGroupNeighbors() }
        await run("interventionPolicyEngineSimulatesStrategies") { try interventionPolicyEngineSimulatesStrategies() }
        await run("interventionPolicyEngineAppliesCalibration") { try interventionPolicyEngineAppliesCalibration() }
        await run("processKillerRecommendsGentleDevServerStrategy") { try await processKillerRecommendsGentleDevServerStrategy() }
        await run("killHistoryChangesStrategyRecommendation") { try await killHistoryChangesStrategyRecommendation() }
        await run("processKillerReactorUsesAdaptiveVerification") { try await processKillerReactorUsesAdaptiveVerification() }
        await run("killGraceCoordinatorEndsEarlyOnExitEvidence") { try await killGraceCoordinatorEndsEarlyOnExitEvidence() }
        await run("killInterventionReactorRecordsHintsWavesAndModes") { try await killInterventionReactorRecordsHintsWavesAndModes() }
        await run("processKillerStreamsOperationEventsInOrder") { try await processKillerStreamsOperationEventsInOrder() }
        await run("processKillerHonorsLiveSkipForceControl") { try await processKillerHonorsLiveSkipForceControl() }
        await run("killOperationStateMachineRecordsExitEvents") { try await killOperationStateMachineRecordsExitEvents() }
        await run("fakeKillPreviewBenchmarksStayBounded") { try await fakeKillPreviewBenchmarksStayBounded() }
        await run("radarStoreRecordsKillActions") { try await radarStoreRecordsKillActions() }
        await run("radarStoreRecordsStructuredKillOperations") { try await radarStoreRecordsStructuredKillOperations() }
        await run("radarStoreRecordsKillEventsAndLearning") { try await radarStoreRecordsKillEventsAndLearning() }
        await run("radarStoreRecordsInterventionKernelTables") { try await radarStoreRecordsInterventionKernelTables() }
        await run("radarStoreRecordsKillCalibrationAggregates") { try await radarStoreRecordsKillCalibrationAggregates() }
        guard failures.isEmpty else {
            throw CheckFailure(message: "\(failures.count) of \(completed) checks failed: " + failures.joined(separator: "; "))
        }
        print("GhostProcessSniperCoreChecks passed (\(completed) checks)")
    }
}

private func nativeSamplerSeesCurrentProcess() async throws {
    let sampler = NativeProcessSampler()
    let processes = try await sampler.sample()
    guard let current = processes.first(where: { $0.pid == getpid() }) else {
        throw CheckFailure(message: "native sampler did not include current process")
    }
    try check(current.identity.startTimeSeconds > 0, "native sampler should include stable start time")
    try check(!current.name.isEmpty, "native sampler should include process name")
}

private func nativeKillSnapshotProviderUsesLitePath() async throws {
    let provider = NativeKillSnapshotProvider()
    let snapshot = try await provider.snapshot(policy: .preflight)
    guard let current = snapshot.processes.first(where: { $0.pid == getpid() }) else {
        throw CheckFailure(message: "native kill snapshot did not include current process")
    }
    try check(snapshot.usedCheapPath, "native kill snapshot should use the lite kill path")
    try check(snapshot.expensiveCallCount == 0, "native kill snapshot should not run command/path/forensics sweeps")
    try check(current.commandLine == current.name, "native kill snapshot should avoid argv reads")
    try check(current.forensics.isPartial, "native kill snapshot should mark forensics as unavailable")
}

private func nativeSamplerDefersForensicsWhenPlanRequestsIt() async throws {
    let sampler = NativeProcessSampler()
    let first = try await sampler.sample(
        plan: SamplingPlan(
            sampledAt: Date(timeIntervalSince1970: 1_000),
            performanceMode: .batterySaver,
            commandRefreshInterval: 60,
            includeForensicsFor: [],
            includeForensicsForPIDs: [],
            forceCommandRefresh: false,
            allowsOptionalForensics: false,
            maxForensicsPerRefresh: 0,
            reason: "check"
        )
    )
    let second = try await sampler.sample(
        plan: SamplingPlan(
            sampledAt: Date(timeIntervalSince1970: 1_001),
            performanceMode: .batterySaver,
            commandRefreshInterval: 60,
            includeForensicsFor: [],
            includeForensicsForPIDs: [],
            forceCommandRefresh: false,
            allowsOptionalForensics: false,
            maxForensicsPerRefresh: 0,
            reason: "check"
        )
    )

    try check(first.stats.forensicsRefreshCount == 0, "battery saver plan should skip expensive forensics")
    try check(first.stats.forensicsDeferredCount > 0, "sampler should report deferred forensics")
    try check(second.stats.commandCacheHitCount > 0, "sampler should reuse command/path cache on stable processes")
}

private func nativeSamplerUsesBSDFirstCheapGraph() async throws {
    let sampler = NativeProcessSampler()
    let plan = SamplingPlan(
        sampledAt: Date(timeIntervalSince1970: 1_010),
        performanceMode: .batterySaver,
        commandRefreshInterval: 120,
        includeForensicsFor: [],
        includeForensicsForPIDs: [],
        forceCommandRefresh: false,
        allowsOptionalForensics: false,
        maxForensicsPerRefresh: 0,
        reason: "bsd-first-check",
        metricsEnrichmentBudget: 4,
        unknownProcessStride: 32,
        trueCheapScanEnabled: true
    )
    let first = try await sampler.sample(plan: plan)
    var secondPlan = plan
    secondPlan.sampledAt = Date(timeIntervalSince1970: 1_011)
    let second = try await sampler.sample(plan: secondPlan)

    try check(first.stats.bsdReadCount >= first.stats.processCount, "cheap graph scan should read BSD identity for sampled processes")
    try check(first.stats.taskInfoReadCount < max(1, first.stats.bsdReadCount), "quiet scan should avoid all-process task-info sweeps")
    // Successful BSD reads can be fewer than enumerated PIDs due to exits,
    // permissions, or the deadline. Assert against the selected scan strategy.
    let expectedPIDCopies = first.stats.scannerWorkerCount > 1 ? 1 : 0
    try check(first.stats.pidBufferCopyCount == expectedPIDCopies, "sequential scans should avoid PID copies; parallel scans should share exactly one snapshot")
    try check(second.stats.scratchpadReuseCount > 0, "sampler should reuse actor-owned scratch buffers")
    try check(second.stats.reusedRecordCount > 0 || second.stats.commandCacheHitCount > 0, "stable quiet refresh should reuse cached process records or telemetry")
}

private func classifierScoresDevProcesses() throws {
    let classifier = DevProcessClassifier()

    try check(classifier.confidence(for: sample(name: "node", commandLine: "node ./node_modules/vite/bin/vite.js")) >= 0.45, "node should classify as dev")
    try check(classifier.confidence(for: sample(name: "Codex Helper", executablePath: "/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper", commandLine: "/Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/helper")) >= 0.45, "Electron app helper should classify as dev")
    try check(classifier.confidence(for: sample(name: "ollama", commandLine: "ollama serve")) >= 0.45, "ollama should classify as dev")
    try check(classifier.confidence(for: sample(name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", commandLine: "/Applications/Safari.app/Contents/MacOS/Safari")) < 0.45, "Safari should not classify as dev by default")
}

private func classifierProducesProcessKinds() throws {
    let classifier = DevProcessClassifier()

    try check(classifier.classification(for: sample(name: "node", commandLine: "node ./node_modules/vite/bin/vite.js")).kind == .nodeServer, "node should produce Node server kind")
    try check(classifier.classification(for: sample(name: "python3", commandLine: "python3 -m uvicorn app:server")).kind == .pythonService, "uvicorn should produce Python service kind")
    try check(classifier.classification(for: sample(name: "ollama", commandLine: "ollama serve")).kind == .localModelRunner, "ollama should produce model runner kind")
    try check(classifier.classification(for: sample(name: "java", commandLine: "java -jar spring-boot.jar")).kind == .javaServer, "spring boot should produce Java server kind")
    try check(classifier.classification(for: sample(name: "go", commandLine: "go run main.go")).kind == .goService, "go run should produce Go service kind")
    try check(classifier.classification(for: sample(name: "air", commandLine: "air -c .air.toml")).kind == .goService, "air live reloader should produce Go service kind")
    try check(classifier.classification(for: sample(name: "my-rust-service", executablePath: "/Users/dev/project/target/debug/my-rust-service", commandLine: "./target/debug/my-rust-service")).kind == .rustService, "Rust target binary should produce Rust service kind")
    try check(classifier.classification(for: sample(name: "bun", commandLine: "bun run server.ts")).kind == .bunServer, "bun run should produce Bun server kind")
    try check(classifier.classification(for: sample(name: "deno", commandLine: "deno run --allow-net server.ts")).kind == .denoServer, "deno run should produce Deno server kind")
    try check(classifier.classification(for: sample(name: "php", commandLine: "php artisan serve")).kind == .phpService, "artisan serve should produce PHP service kind")
    try check(classifier.classification(for: sample(name: "beam.smp", commandLine: "mix phx.server")).kind == .elixirService, "mix phx.server should produce Elixir service kind")
    try check(classifier.classification(for: sample(name: "dotnet", commandLine: "dotnet watch run")).kind == .dotnetService, "dotnet watch run should produce .NET service kind")
}

private func duplicateDetectorCapturesSmallSameUserProcesses() throws {
    var trend = TrendWindow()
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 4_000_000_000
    settings.cpuPercent = 200
    settings.radarMode = .dev
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let first = sample(
        pid: 210,
        parentPID: 1,
        name: "miniwatch",
        executablePath: "/Users/dev/.local/bin/miniwatch",
        commandLine: "miniwatch --repo api --port 4010",
        memory: 22_000_000,
        cpu: 1
    )
    let second = sample(
        pid: 211,
        parentPID: 1,
        start: 2,
        name: "miniwatch",
        executablePath: "/Users/dev/.local/bin/miniwatch",
        commandLine: "miniwatch --repo web --port 4011",
        memory: 24_000_000,
        cpu: 2
    )

    let result = builder.buildFamiliesWithDuplicates(
        from: [first, second],
        settings: settings,
        trendWindow: &trend,
        now: Date(timeIntervalSince1970: 2_100)
    )
    let visibleClusters = result.duplicateClusters.filter { !$0.isInternalToSingleFamily }

    try check(visibleClusters.count == 1, "two same-user small CLI instances should create one duplicate cluster")
    try check(visibleClusters[0].memberCount == 2, "duplicate cluster should track both members")
    try check(visibleClusters[0].independentRootCount == 2, "duplicate cluster should track independent roots")
    try check(result.promotedDuplicateCandidateCount == 2, "duplicate members should be promoted as family candidates")
    try check(result.families.count == 2, "independent duplicate roots should become visible families")
    try check(result.families.allSatisfy { $0.score.level >= .watch }, "duplicate-promoted families should have watch visibility")
    try check(result.families.contains { $0.score.reasons.contains("2 matching instances") }, "duplicate score should explain matching instances")
    try check(result.families.contains { $0.score.components.contains(where: { $0.kind == .fanout && $0.title.contains("matching instances") }) }, "duplicate score should expose a fanout component")
}

private func duplicateDetectorIgnoresSingletonsAndSystemBundles() throws {
    var trend = TrendWindow()
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 4_000_000_000
    settings.cpuPercent = 200
    settings.radarMode = .dev
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let singleton = sample(
        pid: 220,
        name: "miniwatch",
        executablePath: "/Users/dev/.local/bin/miniwatch",
        commandLine: "miniwatch --repo api",
        memory: 22_000_000,
        cpu: 1
    )
    let one = builder.buildFamiliesWithDuplicates(
        from: [singleton],
        settings: settings,
        trendWindow: &trend,
        now: Date(timeIntervalSince1970: 2_200)
    )
    try check(one.duplicateClusters.isEmpty, "one small process should not create a duplicate cluster")

    let systemA = sample(
        pid: 221,
        userID: 0,
        name: "system-helper",
        executablePath: "/System/Library/CoreServices/system-helper",
        commandLine: "system-helper",
        memory: 12_000_000,
        cpu: 1
    )
    let systemB = sample(
        pid: 222,
        userID: 0,
        start: 2,
        name: "system-helper",
        executablePath: "/System/Library/CoreServices/system-helper",
        commandLine: "system-helper",
        memory: 13_000_000,
        cpu: 1
    )
    let system = builder.buildFamiliesWithDuplicates(
        from: [systemA, systemB],
        settings: settings,
        trendWindow: &trend,
        now: Date(timeIntervalSince1970: 2_210)
    )
    try check(system.duplicateClusters.isEmpty, "system-owned duplicate helpers should be excluded")
}

private func duplicateDetectorSeparatesIndependentRootsFromInternalHelpers() throws {
    var trend = TrendWindow()
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 4_000_000_000
    settings.cpuPercent = 200
    settings.radarMode = .dev
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let root = sample(
        pid: 230,
        parentPID: 1,
        name: "MyElectron",
        executablePath: "/Users/dev/Apps/MyElectron.app/Contents/MacOS/MyElectron",
        commandLine: "/Users/dev/Apps/MyElectron.app/Contents/MacOS/MyElectron",
        memory: 40_000_000,
        cpu: 1
    )
    let helperA = sample(
        pid: 231,
        parentPID: 230,
        name: "MyElectron Helper",
        executablePath: "/Users/dev/Apps/MyElectron.app/Contents/Frameworks/MyElectron Helper.app/Contents/MacOS/MyElectron Helper",
        commandLine: "MyElectron Helper --type=renderer",
        memory: 18_000_000,
        cpu: 1
    )
    let helperB = sample(
        pid: 232,
        parentPID: 230,
        start: 2,
        name: "MyElectron Helper",
        executablePath: "/Users/dev/Apps/MyElectron.app/Contents/Frameworks/MyElectron Helper.app/Contents/MacOS/MyElectron Helper",
        commandLine: "MyElectron Helper --type=gpu-process",
        memory: 16_000_000,
        cpu: 1
    )

    let result = builder.buildFamiliesWithDuplicates(
        from: [root, helperA, helperB],
        settings: settings,
        trendWindow: &trend,
        now: Date(timeIntervalSince1970: 2_300)
    )

    try check(result.families.count == 1, "duplicate app helpers should stay inside their owning app family")
    try check(result.duplicateClusters.count == 1, "internal helper duplicates should still be retained as evidence")
    try check(result.duplicateClusters[0].isInternalToSingleFamily, "duplicates fully inside one visible family should not become noisy duplicate rows")
    try check(result.duplicateClusters[0].relatedFamilyKeys == [result.families[0].familyKey], "internal duplicate evidence should point to the owning family")
    try check(result.duplicateClusters.filter { !$0.isInternalToSingleFamily }.isEmpty, "internal app helper duplicates should be hidden from the duplicate list")
}

private func familyBuilderGroupsElectronStyleFamilies() throws {
    var trend = TrendWindow()
    let settings = ThresholdSettings.aggressive
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let root = sample(pid: 100, parentPID: 1, name: "Codex", executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", commandLine: "/Applications/Codex.app/Contents/MacOS/Codex", memory: 200_000_000)
    let renderer = sample(pid: 101, parentPID: 100, name: "Codex Helper", executablePath: "/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper", commandLine: "/Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/helper --type=renderer", memory: 700_000_000)

    let families = builder.buildFamilies(from: [root, renderer], settings: settings, trendWindow: &trend, now: Date(timeIntervalSince1970: 1_000))

    try check(families.count == 1, "Electron-style descendants should collapse into one family")
    try check(families.first?.root.pid == 100, "family root should be the app process")
    try check(families.first?.childCount == 1, "family should count child process")
    try check(families.first?.totalPhysicalFootprintBytes == 900_000_000, "family should aggregate footprint")
    try check(families.first?.classification != nil, "family builder should cache classification metadata")
}

private func familyBuilderKeepsRadarUsefulInDevMode() throws {
    var trend = TrendWindow()
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 1_000_000_000
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let quietDev = sample(pid: 110, name: "node", commandLine: "node server.js", memory: 50_000_000)
    let heavyNonDev = sample(pid: 111, name: "Preview", executablePath: "/System/Applications/Preview.app/Contents/MacOS/Preview", commandLine: "Preview", memory: 1_200_000_000)

    let families = builder.buildFamilies(from: [quietDev, heavyNonDev], settings: settings, trendWindow: &trend, now: Date(timeIntervalSince1970: 2_000))

    try check(families.map(\.root.pid).contains(110), "quiet dev process should still appear in radar")
    try check(families.map(\.root.pid).contains(111), "heavy non-dev process should appear when crossing threshold")
}

private func familyBuilderPromotesGenericHardwareOffenders() throws {
    var trend = TrendWindow()
    var settings = ThresholdSettings.aggressive
    settings.radarMode = .dev
    settings.memoryBytes = 4_000_000_000
    settings.cpuPercent = 200
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let quiet = sample(
        pid: 112,
        name: "Notes",
        executablePath: "/Applications/Notes.app/Contents/MacOS/Notes",
        commandLine: "Notes",
        memory: 60_000_000,
        cpu: 1
    )
    let cpuOffender = sample(
        pid: 113,
        name: "render-worker",
        executablePath: "/Applications/RenderKit.app/Contents/MacOS/render-worker",
        commandLine: "render-worker --preview",
        memory: 320_000_000,
        cpu: 82
    )
    let systemOffender = sample(
        pid: 114,
        userID: 0,
        name: "system-render",
        executablePath: "/System/Library/CoreServices/system-render",
        commandLine: "system-render",
        memory: 900_000_000,
        cpu: 120
    )

    let families = builder.buildFamilies(
        from: [quiet, cpuOffender, systemOffender],
        settings: settings,
        trendWindow: &trend,
        now: Date(timeIntervalSince1970: 2_400)
    )
    let offender = families.first { $0.root.pid == 113 }

    try check(offender != nil, "generic same-user CPU offender should be promoted even below fixed threshold")
    try check(families.contains { $0.root.pid == 114 } == false, "system-owned generic offenders should stay hidden unless surfaced by existing policies")
    try check(offender?.hardwareSignals.contains { $0.kind == .cpuPressure || $0.kind == .sampleOutlier } == true, "promoted generic offender should carry hardware evidence")
    try check(offender?.classification?.kind == .unknownHeavy, "unknown generic offender should remain classified as unknown heavy")
    try check(offender?.score.level ?? .quiet >= .watch, "generic hardware offender should receive watch visibility")
}

private func familyBuilderSurfacesGPUHardwareSignals() throws {
    var trend = TrendWindow()
    var settings = ThresholdSettings.aggressive
    settings.radarMode = .dev
    settings.memoryBytes = 4_000_000_000
    settings.cpuPercent = 200
    let builder = ProcessFamilyBuilder(currentUserID: 501)
    let gpuOffender = sample(
        pid: 115,
        name: "SmallRenderer",
        executablePath: "/Applications/SmallRenderer.app/Contents/MacOS/SmallRenderer",
        commandLine: "SmallRenderer --canvas",
        memory: 96_000_000,
        cpu: 8,
        gpu: 64
    )

    let families = builder.buildFamilies(
        from: [gpuOffender],
        settings: settings,
        trendWindow: &trend,
        now: Date(timeIntervalSince1970: 2_450)
    )
    guard let family = families.first else {
        throw CheckFailure(message: "GPU-heavy unknown process should become a visible family")
    }
    let triage = FamilyTriageViewModel(family: family)
    let panel = FamilyDetailPanelModel(family: family, previous: nil)

    try check(family.totalGPUPercent == 64, "family should aggregate GPU usage")
    try check(family.hardwareSignals.contains { $0.kind == .gpuPressure }, "family should carry GPU hardware signal")
    try check(family.score.components.contains { $0.kind == .gpu }, "GPU score reason should infer GPU component")
    try check(triage.gpuText == "64%", "triage view model should expose compact GPU text")
    try check(panel.summaryCards.contains { $0.title == "GPU" && $0.value == "64%" }, "detail panel should expose GPU summary card")
}

private func ghostScoreInfersTypedComponents() throws {
    let score = GhostScore(
        value: 70,
        level: .hot,
        reasons: ["memory above threshold", "CPU burst", "GPU activity 64%", "background dev process"]
    )
    let kinds = Set(score.components.map(\.kind))
    try check(kinds.contains(.memory), "typed score components should include memory")
    try check(kinds.contains(.cpu), "typed score components should include CPU")
    try check(kinds.contains(.gpu), "typed score components should include GPU")
    try check(kinds.contains(.background), "typed score components should include background")
}

private func triageViewModelsFilterAndSort() throws {
    let node = hotFamily(pid: 120, memory: 900_000_000, cpu: 25)
    let python = hotFamily(
        pid: 121,
        memory: 120_000_000,
        cpu: 5,
        score: GhostScore(value: 8, level: .quiet, reasons: ["quiet dev process"])
    )
    let items = consoleSnapshot([python, node]).families(query: "server", filter: .attention, sort: .memory)

    try check(items.map(\.displayName) == ["node"], "triage view model should filter by query and attention state")
    try check(items.first?.memoryBytes == 900_000_000, "triage view model should sort by memory")
}

private func incidentQueryFiltersAndSorts() throws {
    let signature = ProcessSignature(displayName: "node", canonicalPath: "/usr/local/bin/node", commandLine: "node server.js")
    let old = RadarIncident(
        signature: signature,
        familyName: "node api",
        level: .hot,
        maxScore: 80,
        memoryBytes: 300_000_000,
        cpuPercent: 40,
        leakVelocityMegabytesPerMinute: 20,
        reasons: ["memory above threshold"],
        startedAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 2),
        resolvedAt: Date(timeIntervalSince1970: 3),
        occurrenceCount: 1
    )
    let recurring = RadarIncident(
        signature: signature,
        familyName: "node leak",
        level: .critical,
        maxScore: 96,
        memoryBytes: 900_000_000,
        cpuPercent: 80,
        leakVelocityMegabytesPerMinute: 220,
        reasons: ["fast leak"],
        startedAt: Date(timeIntervalSince1970: 4),
        lastSeenAt: Date(timeIntervalSince1970: 6),
        occurrenceCount: 5
    )

    let query = IncidentQuery(text: "leak", filter: .active, sort: .recurrence, limit: 10)
    let results = query.apply(to: [old, recurring])

    try check(results.map(\.familyName) == ["node leak"], "incident query should filter by active text match")
}

private func ruleDraftRejectsDuplicates() throws {
    let draft = RuleDraft(commandContains: "node", minimumLevel: .watch, action: .inspect)
    guard let firstRule = draft.makeRule(existingRules: []) else {
        throw CheckFailure(message: "valid draft should create a rule")
    }
    try check(draft.makeRule(existingRules: [firstRule]) == nil, "rule draft should reject exact duplicates")
}

private func radarCommandRouterRespectsSelection() throws {
    let family = hotFamily(pid: 130, memory: 600_000_000, cpu: 80)
    let router = RadarCommandRouter()
    let none = router.availability(for: .killPreview, selection: .overview, families: [family])
    let selected = router.availability(for: .killPreview, selection: .family(family.signature.id), families: [family])

    try check(!none.isEnabled, "kill preview should require a selected family")
    try check(selected.isEnabled, "kill preview should be enabled for a killable selected family")
    try check(router.selectedFamily(selection: .family(family.signature.id), families: [family])?.id == family.id, "router should resolve selected family")
}

private func radarCommandCoordinatorNavigatesFamilies() throws {
    let first = hotFamily(pid: 131, memory: 700_000_000, cpu: 90)
    let second = hotFamily(pid: 132, memory: 500_000_000, cpu: 10, score: GhostScore(value: 20, level: .watch, reasons: ["large memory footprint"]))
    let coordinator = RadarCommandCoordinator()
    let selection = RadarFocusedSelection.family(first.familyKey)
    let next = coordinator.selection(after: selection, orderedFamilyKeys: [first.familyKey, second.familyKey], direction: 1)
    let wrapped = coordinator.selection(after: selection, orderedFamilyKeys: [first.familyKey, second.familyKey], direction: -1)

    try check(coordinator.availability(for: .copyDiagnostics, selection: selection, families: [first, second]).isEnabled, "copy diagnostics should always be command-available")
    try check(coordinator.availability(for: .nextFamily, selection: selection, families: [first, second]).isEnabled, "next family should be available when families exist")
    try check(next == .family(second.familyKey), "command coordinator should navigate to the next visible family")
    try check(wrapped == .family(second.familyKey), "command coordinator should wrap around the visible order")
}

private func consoleSnapshotPrecomputesStableRows() throws {
    let first = hotFamily(pid: 140, memory: 900_000_000, cpu: 70)
    let second = hotFamily(pid: 141, memory: 700_000_000, cpu: 50)
    let summary = RadarSummary(statusText: "2 hot", level: .hot, familyCount: 2, hotCount: 2, totalMemoryBytes: 1_600_000_000, topFamilyName: "node")
    let snapshot = RadarConsoleSnapshot.build(
        families: [first, second],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 1)
    )

    try check(snapshot.families.count == 2, "snapshot should precompute family rows")
    try check(snapshot.detailPanel(for: first.familyKey) != nil, "snapshot should retain detail by family key")
    try check(snapshot.detailPanel(for: first.signature.id) != nil, "snapshot should keep signature fallback for compatibility")
    try check(CompactConsoleSnapshot.sidebarSections(from: snapshot.compact.allRows).first?.count == 2, "snapshot should precompute sidebar section counts")
    try check(snapshot.families(query: "node", filter: .attention, sort: .memory).count == 2, "snapshot should filter without remapping process families")
    try check(snapshot.compact.layoutMode == .compact, "snapshot should build the compact console payload")
    try check(snapshot.compact.allRows.count == 2, "compact snapshot should precompute sidebar rows")
    try check(snapshot.compact.topRiskRows.first?.id == snapshot.families.first?.id, "compact risk queue should match smart-sorted family rows")
    try check(snapshot.compact.commandCenter.statusText == "\(summary.hotCount) to review", "compact command center should show the measured review count instead of a raw forecast label")
    try check(snapshot.compact.detailModels[first.familyKey] != nil, "compact snapshot should precompute detail panels")

    let watch = hotFamily(pid: 142, memory: 300_000_000, cpu: 5, score: GhostScore(value: 42, level: .watch, reasons: ["watch"]))
    let quiet = hotFamily(pid: 143, memory: 100_000_000, cpu: 1, score: GhostScore(value: 8, level: .quiet, reasons: ["quiet"]))
    let semantic = RadarConsoleSnapshot.build(
        families: [first, second, watch, quiet],
        summary: RadarSummary(statusText: "2 hot", level: .hot, familyCount: 4, hotCount: 2, totalMemoryBytes: 2_000_000_000, topFamilyName: "node"),
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 2)
    )
    try check(semantic.compact.topRiskRows.count == 2, "risk queue should contain only hot or leaking families")
    try check(semantic.compact.topRiskRows.allSatisfy { $0.level >= .hot || $0.forecastState >= .leaking }, "risk queue should reject watch-only families")
    try check(semantic.compact.warmingRows.allSatisfy { $0.level < .hot && $0.forecastState < .leaking }, "risk and warming queues should be mutually exclusive")
}

private func consoleDerivedSnapshotCachesRows() throws {
    let family = hotFamily(pid: 139, memory: 700_000_000, cpu: 60)
    let snapshot = RadarConsoleSnapshot.build(
        families: [family],
        summary: RadarSummary(statusText: "1 hot", level: .hot, familyCount: 1, hotCount: 1, totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName),
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 1)
    )
    var state = RadarConsoleState.default
    state.searchText = "node"
    state.familyFilter = .attention
    state.familySort = .memory
    state.focusedSelection = .family(family.familyKey)

    let first = ConsoleDerivedSnapshot.build(snapshot: snapshot, incidents: [], state: state)

    try check(first.familyRows.map(\.id) == [family.familyKey], "derived snapshot should precompute filtered family rows")
    try check(first.compactFamilyRows.map(\.id) == [family.familyKey], "derived snapshot should precompute compact filtered rows")
    try check(first.compactSidebarSections.first?.rows.map(\.id) == [family.familyKey], "derived snapshot should precompute compact sidebar sections")
    try check(first.search.familyMatches[family.familyKey] != nil, "derived snapshot should carry search matches for highlighted rows")

    var cache = ConsoleDerivedSnapshotCache()
    let built = cache.update(ConsoleProjectionRequest(source: snapshot, incidents: [], state: state))
    state.focusedSelection = .overview
    let selectionOnlyUpdate = cache.update(ConsoleProjectionRequest(source: snapshot, incidents: [], state: state))
    try check(cache.missCount == 1 && cache.hitCount == 1, "selection changes should reuse expensive derived projections")
    try check(selectionOnlyUpdate == built, "selection-only cache hits should return the stable projection")
}

private func compactDefaultsAndEngineIsolationBehave() throws {
    let family = hotFamily(pid: 138, memory: 600_000_000, cpu: 40)
    let summary = RadarSummary(
        statusText: "Watching",
        level: .watch,
        familyCount: 1,
        hotCount: 0,
        totalMemoryBytes: family.totalPhysicalFootprintBytes,
        topFamilyName: family.displayName
    )
    let first = RadarConsoleSnapshot.build(
        families: [family],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: SamplerHealth(engineName: "test", lastSampleDate: nil, processCount: 42, familyCount: 1, errorMessage: nil),
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 1)
    )
    let second = RadarConsoleSnapshot.build(
        families: [family],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty.updatingSmoothness(mainActorPublishMilliseconds: 5),
        health: SamplerHealth(engineName: "test", lastSampleDate: nil, processCount: 84, familyCount: 1, errorMessage: nil),
        storeHealth: StoreHealth(
            backlogCount: 2,
            pendingActionCount: 0,
            lastFlushDate: nil,
            lastPruneDate: nil,
            errorMessage: nil
        ),
        storeError: nil,
        previous: first,
        generatedAt: Date(timeIntervalSince1970: 2)
    )
    let state = RadarConsoleState.default

    try check(state.showInspector == false, "compact console should default the inspector closed")
    try check(first.contentRevision == second.contentRevision, "engine-only updates should keep content revision stable")
    try check(first.compact.allRows == second.compact.allRows, "engine-only updates should not rebuild compact family rows")
    try check(first.compact.detailModels == second.compact.detailModels, "engine-only updates should not rebuild compact detail models")
    try check(first.compact.engineStatus.processText == "42", "first engine status should carry process count")
    try check(second.compact.engineStatus.processText == "84", "diagnostics-only compact updates should keep lightweight engine text live")
    try check(second.compact.engineStatus.refreshText != first.compact.engineStatus.refreshText || second.compact.engineStatus.backlogText != first.compact.engineStatus.backlogText, "engine status should still update without content invalidation")
    try check(derivedKey(first, state) == derivedKey(second, state), "diagnostics-only updates should reuse the derived snapshot key")
}

private func consoleSnapshotSurfacesPredictiveQueues() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let base = forecastFamily(
        pid: 142,
        memory: 300 * 1_048_576,
        cpu: 8,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 35,
            cpuSlopePerMinute: 0,
            memoryPoints: [220, 250, 280, 300].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 12, level: .quiet, reasons: ["quiet dev process"])
    )
    let forecast = forecastWithFreshMeasurements(
        family: base,
        settings: settings,
        now: Date(timeIntervalSince1970: 12_000)
    )
    let family = base.enriched(forecast: forecast)
    let snapshot = RadarConsoleSnapshot.build(
        families: [family],
        summary: RadarSummary(statusText: "Warming", level: .watch, familyCount: 1, hotCount: 0, totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName),
        incidents: [],
        rules: RadarRule.builtIns(settings: settings),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 12_000)
    )

    try check(snapshot.warmingFamilies.count == 1, "snapshot should expose a warming predictive queue")
    try check(snapshot.families.first?.etaText == forecast.etaText, "triage row should precompute forecast ETA")
    try check(snapshot.detailPanel(for: family.familyKey)?.forecastWhyNow.contains("memory is rising") == true, "detail panel should expose why-now forecast text")
}

private func ruleMatchPreviewCountsLiveFamilies() throws {
    let family = hotFamily(pid: 145, memory: 650_000_000, cpu: 70)
    let rule = RadarRule(
        name: "Inspect node",
        match: RadarRuleMatch(commandContains: "node", minimumLevel: .watch),
        action: .inspect
    )
    let preview = RuleMatchPreview(rule: rule, families: [family])

    try check(preview.matchCount == 1, "rule preview should count live matching families")
    try check(preview.matchedFamilyKeys == [family.familyKey], "rule preview should expose matching family keys")
}

private func trendWindowComputesLeakVelocity() throws {
    var trend = TrendWindow()
    let identity = ProcessIdentity(pid: 200, startTimeSeconds: 10, startTimeMicroseconds: 0)
    _ = trend.update(identity: identity, memoryBytes: 100 * 1_048_576, cpuPercent: 5, at: Date(timeIntervalSince1970: 1_000))
    let metrics = trend.update(identity: identity, memoryBytes: 260 * 1_048_576, cpuPercent: 25, at: Date(timeIntervalSince1970: 1_060))

    try check(Int(metrics.memoryVelocityMegabytesPerMinute.rounded()) == 160, "trend should compute MB/min leak velocity")
    try check(Int(metrics.cpuSlopePerMinute.rounded()) == 20, "trend should compute CPU slope")
}

private func riskForecasterPredictsETAAndState() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let family = forecastFamily(
        pid: 205,
        memory: 300 * 1_048_576,
        cpu: 12,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 60,
            cpuSlopePerMinute: 0,
            memoryPoints: [120, 180, 240, 300].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )

    let forecast = forecastWithFreshMeasurements(
        family: family,
        settings: settings,
        now: Date(timeIntervalSince1970: 12_500)
    )

    try check(forecast.state >= .leaking, "forecaster should promote imminent memory growth")
    try check((forecast.etaSeconds ?? 0) > 180 && (forecast.etaSeconds ?? 999) < 240, "forecaster should compute memory threshold ETA")
    try check(forecast.whyNow.contains("threshold ETA"), "forecast should explain why now")
    try check(forecast.recommendedAction.action == .inspect, "leaking forecast should remain advisory inspect")
}

private func riskForecasterSuppressesQuietNoise() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 1_000 * 1_048_576
    let family = forecastFamily(
        pid: 206,
        parentPID: 999,
        memory: 120 * 1_048_576,
        cpu: 1,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 0.2,
            cpuSlopePerMinute: 0,
            memoryPoints: [118, 121, 119, 120].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 6, level: .quiet, reasons: ["quiet dev process"])
    )

    let forecast = forecastWithFreshMeasurements(
        family: family,
        settings: settings,
        now: Date(timeIntervalSince1970: 13_000)
    )

    try check(forecast.state == .quiet, "forecaster should suppress noisy quiet samples")
    try check(forecast.confidence <= 0.46, "quiet forecasts should not overstate confidence")
}

private func riskForecasterDetectsStaleAndRecurringFamilies() throws {
    let stale = forecastFamily(
        pid: 207,
        parentPID: 1,
        start: 1,
        memory: 650 * 1_048_576,
        cpu: 0,
        trend: .empty,
        score: GhostScore(value: 10, level: .quiet, reasons: ["quiet dev process"])
    )
    let staleForecast = forecastWithFreshMeasurements(
        family: stale,
        settings: .aggressive,
        now: Date(timeIntervalSince1970: 20_000)
    )
    try check(staleForecast.state == .stale, "forecaster should detect long-running detached dev trees")
    try check(staleForecast.staleLikelihood >= 0.65, "stale likelihood should be visible")

    let recurringBase = forecastFamily(
        pid: 208,
        parentPID: 999,
        memory: 180 * 1_048_576,
        cpu: 2,
        trend: .empty,
        score: GhostScore(value: 8, level: .quiet, reasons: ["quiet dev process"])
    )
    let baseline = FamilyBaseline(
        signature: recurringBase.signature,
        sampleCount: 20,
        meanMemoryBytes: 160 * 1_048_576,
        peakMemoryBytes: 220 * 1_048_576,
        meanCPUPercent: 2,
        peakCPUPercent: 8,
        meanLeakVelocityMegabytesPerMinute: 0,
        incidentCount: 3,
        firstSeenAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 2)
    )
    let recurring = recurringBase.enriched(baseline: baseline, recentIncidentCount: 3)
    let recurringForecast = forecastWithFreshMeasurements(
        family: recurring,
        settings: .aggressive,
        now: Date(timeIntervalSince1970: 20_000)
    )
    try check(recurringForecast.state == .quiet, "historical incidents alone must not escalate currently quiet measurements")
    try check(recurringForecast.recurrenceRisk >= 0.59 && recurringForecast.recurrenceRisk <= 0.61, "recurrence risk should count distinct recent incidents once")
}

private func riskForecasterDetectsLeakAcceleration() throws {
    let base = Date(timeIntervalSince1970: 20_840)
    let samples = [100, 140, 220, 340, 500, 700].enumerated().map { index, megabytes in
        TrendSample(
            date: base.addingTimeInterval(Double(index) * 30),
            memoryBytes: UInt64(megabytes) * 1_048_576,
            cpuPercent: 4
        )
    }
    let family = forecastFamily(
        pid: 209,
        memory: 700 * 1_048_576,
        cpu: 4,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 20,
            cpuSlopePerMinute: 0,
            memoryPoints: samples.map { Double($0.memoryBytes) },
            samples: samples
        ),
        score: GhostScore(value: 12, level: .quiet, reasons: ["quiet dev process"])
    )
    let forecast = forecastWithFreshMeasurements(
        family: family,
        settings: .aggressive,
        now: Date(timeIntervalSince1970: 21_000)
    )

    try check(forecast.state == .runaway, "accelerating leak should become runaway even before fixed thresholds")
    try check(forecast.leakAccelerationMegabytesPerMinute2 > 80, "forecast should expose leak acceleration")
}

private func trendWindowRegressionResistsEndpointSpikes() throws {
    var trend = TrendWindow()
    let identity = ProcessIdentity(pid: 300, startTimeSeconds: 10, startTimeMicroseconds: 0)
    let base = Date(timeIntervalSince1970: 2_000)
    for (index, megabytes) in [100, 100, 100, 100].enumerated() {
        _ = trend.update(identity: identity, memoryBytes: UInt64(megabytes) * 1_048_576, cpuPercent: 3, at: base.addingTimeInterval(Double(index) * 30))
    }
    let metrics = trend.update(identity: identity, memoryBytes: 400 * 1_048_576, cpuPercent: 3, at: base.addingTimeInterval(120))

    // Endpoint math would claim 150 MB/min from one spiky sample; the
    // regression stays lower and flags the poor fit.
    try check(metrics.memoryVelocityMegabytesPerMinute < 130, "regression should damp a single endpoint spike")
    try check(metrics.memoryFitQuality < 0.6, "spiky series should report weak fit quality")
    try check(metrics.sampleCount == 5, "trend metrics should expose the window sample count")

    var cleanTrend = TrendWindow()
    let cleanIdentity = ProcessIdentity(pid: 301, startTimeSeconds: 10, startTimeMicroseconds: 0)
    var cleanMetrics = TrendMetrics.empty
    for (index, megabytes) in [100, 150, 200, 250, 300].enumerated() {
        cleanMetrics = cleanTrend.update(identity: cleanIdentity, memoryBytes: UInt64(megabytes) * 1_048_576, cpuPercent: 3, at: base.addingTimeInterval(Double(index) * 30))
    }
    try check(Int(cleanMetrics.memoryVelocityMegabytesPerMinute.rounded()) == 100, "regression should recover the true slope of a clean leak")
    try check(cleanMetrics.memoryFitQuality > 0.95, "clean linear leak should earn high fit quality")
}

private func riskForecasterDiscountsNoisyImminentForecasts() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let noisy = forecastFamily(
        pid: 210,
        memory: 400 * 1_048_576,
        cpu: 4,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 60,
            cpuSlopePerMinute: 0,
            memoryPoints: [400, 260, 480, 300, 400].map { Double($0 * 1_048_576) },
            memoryFitQuality: 0.1
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let noisyForecast = forecastWithFreshMeasurements(
        family: noisy,
        settings: settings,
        now: Date(timeIntervalSince1970: 12_500)
    )
    try check(noisyForecast.horizon == .unknown && noisyForecast.etaSeconds == nil, "unreliable growth must not produce a threshold ETA")

    let steady = forecastFamily(
        pid: 211,
        memory: 400 * 1_048_576,
        cpu: 4,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 60,
            cpuSlopePerMinute: 0,
            memoryPoints: [200, 250, 300, 350, 400].map { Double($0 * 1_048_576) },
            memoryFitQuality: 0.95
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let steadyForecast = forecastWithFreshMeasurements(
        family: steady,
        settings: settings,
        now: Date(timeIntervalSince1970: 12_500)
    )
    try check(steadyForecast.horizon == .imminent, "clean trends should keep the imminent horizon")
    try check(steadyForecast.confidence > noisyForecast.confidence, "confidence should reward clean trend fits")
}

private func memoryPatternAnalyzerClassifiesShapes() throws {
    func bytes(_ megabytes: [Double]) -> [Double] {
        megabytes.map { $0 * 1_048_576 }
    }

    let sawtooth = MemoryPatternAnalysis.analyze(points: bytes([300, 380, 310, 390, 320, 400, 330]), fitQuality: 0.3)
    try check(sawtooth.pattern == .sawtooth, "repeated reclaim dips should classify as sawtooth")
    try check(!sawtooth.pattern.indicatesAccumulation, "sawtooth should not count as accumulation")

    let climb = MemoryPatternAnalysis.analyze(points: bytes([200, 240, 280, 320, 360]), fitQuality: 0.98)
    try check(climb.pattern == .steadyClimb, "monotonic growth with clean fit should classify as steady climb")
    try check(climb.pattern.indicatesAccumulation, "steady climb should count as accumulation")

    let step = MemoryPatternAnalysis.analyze(points: bytes([200, 202, 201, 520, 522]), fitQuality: 0.6)
    try check(step.pattern == .stepJump, "one dominant jump should classify as step jump")

    let flat = MemoryPatternAnalysis.analyze(points: bytes([400, 402, 401, 403, 400]), fitQuality: 0.1)
    try check(flat.pattern == .flat, "narrow range should classify as flat")

    let warming = MemoryPatternAnalysis.analyze(points: bytes([100, 200]), fitQuality: 1)
    try check(warming.pattern == .unknown, "fewer than four samples should stay unknown")
}

private func riskForecasterTreatsSawtoothAsChurn() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let family = forecastFamily(
        pid: 212,
        memory: 300 * 1_048_576,
        cpu: 4,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 60,
            cpuSlopePerMinute: 0,
            memoryPoints: [300, 380, 310, 390, 320, 400, 330].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let forecast = forecastWithFreshMeasurements(
        family: family,
        settings: settings,
        now: Date(timeIntervalSince1970: 12_500)
    )
    try check(forecast.state == .warming, "sawtooth churn should not be promoted to leaking")
    try check(forecast.whyNow.contains("churn"), "forecast should explain the churn pattern")
}

private func systemPressureBoostsLargeFamilies() throws {
    let family = forecastFamily(
        pid: 220,
        memory: 1_610_612_736,
        cpu: 3,
        trend: .empty,
        score: GhostScore(value: 10, level: .quiet, reasons: ["quiet dev process"])
    )
    let intelligence = RadarIntelligence()
    let now = Date(timeIntervalSince1970: 20_000)
    let nominal = intelligence.enrich(
        family: freshMeasurements(family, at: now),
        context: RadarContext(baselines: [:], recentIncidentCounts: [:], rules: []),
        settings: .aggressive,
        now: now
    )
    let pressured = intelligence.enrich(
        family: freshMeasurements(family, at: now),
        context: RadarContext(
            baselines: [:],
            recentIncidentCounts: [:],
            rules: [],
            systemPressure: SystemMemoryPressure(
                level: .critical,
                usedFraction: 0.95,
                totalBytes: 17_179_869_184,
                availableBytes: 858_993_459,
                compressedBytes: 4_294_967_296
            )
        ),
        settings: .aggressive,
        now: now
    )
    try check(pressured.score.value >= nominal.score.value + 10, "critical host pressure should boost large families")
    try check(pressured.score.reasons.joined(separator: " ").contains("pressure"), "pressure boost should be explained in reasons")
    try check(pressured.score.level >= .watch, "gigabyte families under critical pressure should be at least watch")
}

private func familyVerdictSynthesizesJudgment() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let base = forecastFamily(
        pid: 221,
        memory: 300 * 1_048_576,
        cpu: 4,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 60,
            cpuSlopePerMinute: 0,
            memoryPoints: [300, 380, 310, 390, 320, 400, 330].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let forecast = forecastWithFreshMeasurements(
        family: base,
        settings: settings,
        now: Date(timeIntervalSince1970: 12_500)
    )
    let family = base.enriched(forecast: forecast)
    let panel = FamilyDetailPanelModel(family: family, previous: nil)
    try check(panel.memoryPattern.pattern == .sawtooth, "detail panel should expose the memory pattern")
    try check(panel.verdict.headline == "Churning, not leaking", "verdict should call out churn instead of leak")
    try check(!panel.verdict.detail.isEmpty, "verdict should carry a detail sentence")
}

private func riskForecasterRequiresSustainedCPUEvidence() throws {
    func cpuTrend(_ cpus: [Double]) -> TrendMetrics {
        let base = Date(timeIntervalSince1970: 12_000)
        let samples = cpus.enumerated().map { index, cpu in
            TrendSample(
                date: base.addingTimeInterval(Double(index) * 30),
                memoryBytes: 200 * 1_048_576,
                cpuPercent: cpu
            )
        }
        return TrendMetrics(
            memoryVelocityMegabytesPerMinute: 0,
            cpuSlopePerMinute: 0,
            memoryPoints: samples.map { Double($0.memoryBytes) },
            samples: samples
        )
    }
    let now = Date(timeIntervalSince1970: 12_500)

    // One transient spike inside the window must not read as a runaway.
    let spiky = forecastFamily(
        pid: 230,
        parentPID: 999,
        memory: 200 * 1_048_576,
        cpu: 4,
        trend: cpuTrend([3, 96, 4, 3, 4]),
        score: GhostScore(value: 8, level: .quiet, reasons: ["quiet dev process"])
    )
    let spikyForecast = forecastWithFreshMeasurements(family: spiky, settings: .aggressive, now: now)
    try check(spikyForecast.state == .quiet, "one CPU spike in the window should not become runaway")

    // A mostly-hot window that is still above threshold is sustained.
    let pegged = forecastFamily(
        pid: 231,
        parentPID: 999,
        memory: 200 * 1_048_576,
        cpu: 90,
        trend: cpuTrend([85, 90, 88, 86, 90]),
        score: GhostScore(value: 8, level: .quiet, reasons: ["quiet dev process"])
    )
    let peggedForecast = forecastWithFreshMeasurements(family: pegged, settings: .aggressive, now: now)
    try check(peggedForecast.state == .runaway, "a currently hot and mostly-hot CPU window should be runaway")
    try check(peggedForecast.whyNow.contains("CPU held above threshold"), "sustained CPU should be explained")

    let recovered = forecastFamily(pid: 235, parentPID: 999, memory: 200 * 1_048_576, cpu: 4,
        trend: cpuTrend([90, 90, 90, 90, 4]), score: GhostScore(value: 8, level: .quiet, reasons: []))
    let recoveredForecast = forecastWithFreshMeasurements(family: recovered, settings: .aggressive, now: now)
    try check(recoveredForecast.state == .quiet, "old high CPU must not keep a currently recovered process runaway")
}

private func startupGraceDelaysLeakCalls() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let trend = TrendMetrics(
        memoryVelocityMegabytesPerMinute: 60,
        cpuSlopePerMinute: 0,
        memoryPoints: [120, 180, 240, 300].map { Double($0 * 1_048_576) }
    )
    let now = Date(timeIntervalSince1970: 12_500)

    let fresh = forecastFamily(
        pid: 232,
        start: 12_440,
        memory: 300 * 1_048_576,
        cpu: 12,
        trend: trend,
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let freshForecast = forecastWithFreshMeasurements(family: fresh, settings: settings, now: now)
    try check(freshForecast.state == .warming, "a 60-second-old process should get startup grace instead of a leak call")
    try check(freshForecast.whyNow.contains("startup grace"), "grace window should be explained")

    let mature = forecastFamily(
        pid: 233,
        memory: 300 * 1_048_576,
        cpu: 12,
        trend: trend,
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let matureForecast = forecastWithFreshMeasurements(family: mature, settings: settings, now: now)
    try check(matureForecast.state >= .leaking, "grace must not suppress leaks in long-running processes")
}

private func decliningFamiliesEaseOff() throws {
    let base = forecastFamily(
        pid: 234,
        parentPID: 999,
        memory: 340 * 1_048_576,
        cpu: 2,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: -80,
            cpuSlopePerMinute: 0,
            memoryPoints: [500, 460, 420, 380, 340].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 30, level: .watch, reasons: ["was elevated"])
    )
    let forecast = forecastWithFreshMeasurements(
        family: base,
        settings: .aggressive,
        now: Date(timeIntervalSince1970: 12_500)
    )
    try check(forecast.state == .quiet, "families releasing memory should ease back to quiet")
    try check(forecast.whyNow.contains("released"), "recovery should be explained")

    let family = base.enriched(forecast: forecast)
    let panel = FamilyDetailPanelModel(family: family, previous: nil)
    try check(panel.verdict.headline == "Recovering", "verdict should recognize recovery")
}

private func selfUsageMonitorMeasuresOwnCost() throws {
    var monitor = SelfUsageMonitor(throttleThresholdPercent: 6)
    let first = monitor.sample()
    try check(first.footprintBytes > 1_048_576, "self usage should report the app's own footprint")

    // Burn CPU for at least 80 ms of wall time so the delta is measurable.
    let started = Date()
    var sink = 0.0
    while Date().timeIntervalSince(started) < 0.08 {
        for value in 0..<10_000 {
            sink += sin(Double(value))
        }
    }
    try check(sink != .infinity, "busy loop should complete")

    let second = monitor.sample()
    try check(second.cpuPercent > 5, "self usage should measure CPU burned between samples")
    try check(second.averageCPUPercent > 0, "self usage should keep a rolling average")
}

private func scannerDeadlineAndCachesBehave() throws {
    let budget = ScannerBudget.budget(for: .batterySaver)
    let deadline = SamplerDeadline(
        startedAt: Date(timeIntervalSince1970: 100),
        budgetMilliseconds: budget.targetMilliseconds
    )
    try check(!deadline.isExpired(now: Date(timeIntervalSince1970: 100.001)), "deadline should allow work inside budget")
    try check(deadline.isExpired(now: Date(timeIntervalSince1970: 101)), "deadline should expire once the scan crosses budget")

    let process = sample(pid: 215, name: "node", commandLine: "node server.js", memory: 64_000_000)
    let record = ProcessRecord(
        identity: process.identity,
        process: process,
        metricsFingerprint: 10,
        telemetryRefreshedAt: Date(timeIntervalSince1970: 1_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_000)
    )
    var cache = ProcessScanCache()
    cache.update(record)
    try check(!cache.shouldRefreshTelemetry(
        identity: process.identity,
        probeFingerprint: 10,
        now: Date(timeIntervalSince1970: 1_005),
        maxAge: 10,
        grace: 10,
        isPriority: false,
        force: false
    ), "unchanged quiet process should reuse cached telemetry")
    try check(!cache.shouldRefreshTelemetry(
        identity: process.identity,
        probeFingerprint: 11,
        now: Date(timeIntervalSince1970: 1_005),
        maxAge: 10,
        grace: 10,
        isPriority: false,
        force: false
    ), "changed cheap metrics should not force command/path telemetry inside the cache window")
    try check(cache.shouldRefreshTelemetry(
        identity: process.identity,
        probeFingerprint: 10,
        now: Date(timeIntervalSince1970: 1_030),
        maxAge: 10,
        grace: 10,
        isPriority: false,
        force: false
    ), "quiet telemetry should refresh after max age plus grace")
    try check(cache.shouldRefreshTelemetry(
        identity: process.identity,
        probeFingerprint: 10,
        now: Date(timeIntervalSince1970: 1_012),
        maxAge: 10,
        grace: 10,
        isPriority: true,
        force: false
    ), "priority telemetry should use the shorter max-age window")

    var forensics = ForensicsCache()
    let partial = ProcessForensics.unavailable(reason: "protected")
    forensics.update(partial, for: process.identity, at: Date(timeIntervalSince1970: 2_000))
    try check(forensics.negativeEntry(for: process.identity, now: Date(timeIntervalSince1970: 2_090), maxAge: 120)?.forensics == partial, "partial forensics should be negative-cached")

    var queue = ForensicsWorkQueue(identities: [process.identity, process.identity])
    try check(queue.pop() == process.identity, "forensics queue should return priority identity once")
    try check(queue.isEmpty, "forensics queue should de-duplicate identities")

    var cpu = CPUUsageTracker<ProcessIdentity>()
    _ = cpu.percent(key: process.identity, totalProcessorSeconds: 1, wallClock: Date(timeIntervalSince1970: 1))
    cpu.prune(keeping: [])
    let missing = cpu.percent(key: process.identity, totalProcessorSeconds: 2, wallClock: Date(timeIntervalSince1970: 2))
    try check(missing == nil, "CPU tracker pruning should drop old identity state")

    let policy = ProcessProbePolicy(
        richMetricIdentities: [process.identity],
        richMetricPIDs: [],
        quietRichMetricStride: 5,
        allowsRichMetrics: true
    )
    try check(policy.shouldReadRichMetrics(identity: process.identity, pid: process.pid, ordinal: 1, isPriority: false), "focused identity should be promoted to rich metrics")
    try check(!policy.shouldReadRichMetrics(identity: ProcessIdentity(pid: 216, startTimeSeconds: 1, startTimeMicroseconds: 0), pid: 216, ordinal: 1, isPriority: false), "stable quiet identities should skip rich metrics between strides")
    try check(policy.shouldReadRichMetrics(identity: ProcessIdentity(pid: 217, startTimeSeconds: 1, startTimeMicroseconds: 0), pid: 217, ordinal: 5, isPriority: false), "quiet identities should receive sparse rich probes by stride")
    try check(!ProcessProbePolicy(richMetricIdentities: [process.identity], richMetricPIDs: [], quietRichMetricStride: 1, allowsRichMetrics: false).shouldReadRichMetrics(identity: process.identity, pid: process.pid, ordinal: 0, isPriority: true), "pressure policy should disable rich probes")
}

private func scannerHealthFeedsDiagnostics() throws {
    let stats = SamplerStats(
        processCount: 10,
        commandRefreshCount: 1,
        commandCacheHitCount: 9,
        forensicsRefreshCount: 1,
        forensicsDeferredCount: 8,
        elapsedMilliseconds: 12,
        telemetryDeferredCount: 2,
        forensicsCacheHitCount: 1,
        forensicsNegativeCacheHitCount: 3,
        skippedPIDCount: 4,
        expensiveCallCount: 5,
        scannerWorkerCount: 2,
        skippedOptionalWorkCount: 6,
        scannerTaskCount: 3,
        tinyQueueSequentialCount: 1,
        didHitDeadline: true,
        laneCounts: [.cheapMetrics: 10, .richMetrics: 2, .telemetryCache: 9, .deadlineSkipped: 4],
        bsdReadCount: 10,
        taskInfoReadCount: 2,
        reusedRecordCount: 7,
        pidBufferCopyCount: 0,
        scratchpadReuseCount: 1
    )
    let health = ScannerHealthSnapshot(stats: stats, budget: ScannerBudget.budget(for: .batterySaver))
    let metrics = RadarPerformanceMetrics(
        mode: .batterySaver,
        pressureLevel: .nominal,
        lastRefresh: RefreshStats(
            startedAt: Date(timeIntervalSince1970: 1),
            sampleMilliseconds: 12,
            buildMilliseconds: 2,
            scoreMilliseconds: 1,
            storeMilliseconds: 0,
            publishMilliseconds: 1,
            totalMilliseconds: 16,
            processCount: 10,
            familyCount: 1
        ),
        averageRefreshMilliseconds: 18,
        nextRefreshInterval: 5,
        forensicsDeferredCount: 8,
        forensicsRefreshCount: 1,
        commandCacheHitCount: 9,
        storeBacklogCount: 0,
        lastStoreFlushDate: nil,
        budget: RadarPerformanceBudget.budget(for: .batterySaver),
        scannerHealth: health,
        taskInfoReadCount: 2,
        reusedProcessRecordCount: 7,
        hardwareOffenderCount: 2,
        hardwareDetectorMilliseconds: 1
    )
    let engine = EngineDiagnosticsViewModel(
        metrics: metrics,
        health: SamplerHealth(engineName: "test", lastSampleDate: nil, processCount: 10, familyCount: 1, errorMessage: nil),
        storeHealth: .empty,
        storeError: nil,
        summary: RadarSummary(statusText: "Quiet", level: .quiet, familyCount: 1, hotCount: 0, totalMemoryBytes: 1, topFamilyName: "node"),
        generatedAt: Date(timeIntervalSince1970: 2)
    )

    try check(engine.deadlineText == "Deadline hit", "engine diagnostics should expose scanner deadline state")
    try check(engine.cacheText.contains("9 command"), "engine diagnostics should expose cache hits")
    try check(engine.scannerLaneText.contains("Cheap scan"), "engine diagnostics should expose scanner lanes")
    try check(engine.scannerCostText.contains("2 rich"), "engine diagnostics should expose rich probe cost")
    try check(engine.scannerCostText.contains("2 task-info"), "engine diagnostics should expose task-info read cost")
    try check(engine.cacheText.contains("7 reused"), "engine diagnostics should expose reused process records")
    try check(engine.scannerCostText.contains("2 workers"), "engine diagnostics should expose scanner worker count")
    try check(engine.scannerCostText.contains("3 tasks"), "engine diagnostics should expose bounded task count")
    try check(engine.scannerCostText.contains("2 hardware"), "engine diagnostics should expose hardware offender count")
    try check(engine.diagnosticsReport.contains("Hardware offenders: 2"), "diagnostics report should include hardware detector count")
    try check(engine.smoothnessText.contains("0 ms publish"), "engine diagnostics should expose smoothness text")
}

private func gpuUsageTrackerComputesDeltaPercent() throws {
    var tracker = ProcessGPUUsageTracker()
    let first = tracker.update(
        rawNanosecondsByPID: [42: 1_000_000_000],
        now: Date(timeIntervalSince1970: 10)
    )
    let second = tracker.update(
        rawNanosecondsByPID: [42: 1_500_000_000],
        now: Date(timeIntervalSince1970: 11)
    )
    let disappeared = tracker.update(
        rawNanosecondsByPID: [:],
        now: Date(timeIntervalSince1970: 12)
    )

    try check(first.isEmpty, "first GPU sample should establish baseline without percent")
    try check(abs((second[42] ?? 0) - 50) < 0.001, "GPU tracker should convert nanosecond deltas to percent")
    try check(disappeared.isEmpty, "GPU tracker should clear disappeared GPU clients")
}

private func spikeRingBufferBoundsReports() throws {
    var ring = SpikeRingBuffer(limit: 2)
    ring.record(phase: "sample", milliseconds: 12, threshold: 20, at: Date(timeIntervalSince1970: 1))
    ring.record(phase: "publish", milliseconds: 24, threshold: 20, at: Date(timeIntervalSince1970: 2))
    ring.record(phase: "store", milliseconds: 38, threshold: 20, at: Date(timeIntervalSince1970: 3))
    let report = ring.report

    try check(report.hitchCount == 2, "spike ring should keep bounded recent hitches")
    try check(report.worstHitchMilliseconds == 38, "spike ring should expose worst hitch")
    try check(report.latestSpikePhase == "store", "spike ring should expose latest spike phase")
    try check(!report.recentSpikes.contains(where: { $0.contains("sample") }), "spike ring should evict old entries")
}

private func samplerExecutionPlanScalesAndCounts() throws {
    try check(NativeProcessSampler.recommendedWorkerCount(for: 0, mode: .balanced) == 0, "empty scan should not create workers")
    try check(NativeProcessSampler.recommendedWorkerCount(for: 100, mode: .balanced) == 1, "small scans should avoid task-group workers")
    try check(NativeProcessSampler.recommendedWorkerCount(for: 2_000, mode: .balanced) <= 5, "balanced scans should cap workers")
    try check(NativeProcessSampler.recommendedWorkerCount(for: 30_000, mode: .batterySaver) <= 3, "battery saver should cap worker fanout")
    try check(ScannerBudget.budget(for: .balanced).maxTelemetryRefreshes <= 16, "balanced scanner should cap command/path refresh bursts")

    let plan = SamplerExecutionPlan(
        workerCount: 1,
        telemetryJobCount: 2,
        forensicsJobCount: 0,
        scannerTaskCount: 0,
        tinyQueueSequentialCount: 1
    )
    try check(plan.tinyQueueSequentialCount == 1 && plan.scannerTaskCount == 0, "tiny queues should run sequentially instead of spawning tasks")
}

private func radarPublishPayloadSkipsUnchangedContentRebuild() throws {
    let family = hotFamily(pid: 230, memory: 700_000_000, cpu: 55)
    let summary = RadarSummary(
        statusText: "Watching",
        level: .watch,
        familyCount: 1,
        hotCount: 0,
        totalMemoryBytes: family.totalPhysicalFootprintBytes,
        topFamilyName: family.displayName
    )
    let first = RadarPublishPayload.build(
        families: [family],
        summary: summary,
        rules: RadarRule.builtIns(settings: .aggressive),
        incidents: [],
        health: SamplerHealth(engineName: "test", lastSampleDate: nil, processCount: 1, familyCount: 1, errorMessage: nil),
        storeHealth: .empty,
        storeError: nil,
        performance: .empty,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 2_300)
    )
    let second = RadarPublishPayload.build(
        families: [family],
        summary: summary,
        rules: RadarRule.builtIns(settings: .aggressive),
        incidents: [],
        health: SamplerHealth(engineName: "test", lastSampleDate: nil, processCount: 1, familyCount: 1, errorMessage: nil),
        storeHealth: .empty,
        storeError: nil,
        performance: .empty.updatingSmoothness(mainActorPublishMilliseconds: 4),
        previous: first.state.consoleSnapshot,
        generatedAt: Date(timeIntervalSince1970: 2_301)
    )

    try check(second.delta.mode == .diagnosticsOnly, "unchanged radar content should publish diagnostics-only")
    try check(second.delta.skippedContentRebuild, "diagnostics-only payload should skip full console/detail rebuild")
    try check(second.state.consoleSnapshot.contentRevision == first.state.consoleSnapshot.contentRevision, "diagnostics-only payload should keep content revision stable")
    try check(second.state.triageFamilies == first.state.triageFamilies, "diagnostics-only payload should reuse previous triage rows")
    try check(second.state.performanceMetrics.diagnosticsOnlyPublishCount == 1, "diagnostics-only publish should be counted")
    try check(second.state.performanceMetrics.uiCacheHitCount == 1, "diagnostics-only publish should count UI reuse")
    try check(second.state.performanceMetrics.uiPublishSkippedCount == 1, "diagnostics-only publish should count skipped UI model work")
    try check(second.state.viewModel.families.isEmpty, "diagnostics-only payload should not rebuild radar family rows")
    try check(second.state.detailViewModels.isEmpty, "diagnostics-only payload should not rebuild family detail view models")
}

private func menuBarStatusPresentationIsIconOnlyAndCompact() throws {
    let states = [
        RadarSummary(statusText: "Quiet", level: .quiet, familyCount: 0, hotCount: 0, totalMemoryBytes: 0, topFamilyName: nil),
        RadarSummary(statusText: "Warming No threshold ETA", level: .watch, familyCount: 2, hotCount: 0, totalMemoryBytes: 64_000_000, topFamilyName: "node"),
        RadarSummary(statusText: "2 hot", level: .hot, familyCount: 4, hotCount: 2, totalMemoryBytes: 2_000_000_000, topFamilyName: "node"),
        RadarSummary(statusText: "Leak 840 MB/min", level: .watch, familyCount: 2, hotCount: 0, totalMemoryBytes: 1_000_000_000, topFamilyName: "python", leakingCount: 1),
        RadarSummary(statusText: "Critical", level: .critical, familyCount: 3, hotCount: 3, totalMemoryBytes: 3_000_000_000, topFamilyName: "ollama")
    ]

    for summary in states {
        let presentation = MenuBarStatusPresentation(
            summary: summary,
            engineStatus: .empty,
            metrics: .empty
        )
        try check(presentation.title.isEmpty, "menu bar presentation should always be icon-only")
        try check(presentation.compactStateText.count <= 8, "popover state chip should stay compact")
        try check(!presentation.tooltip.contains("No threshold ETA"), "tooltip should normalize awkward ETA wording")
    }

    let warming = MenuBarStatusPresentation(
        summary: states[1],
        engineStatus: .empty,
        metrics: .empty
    )
    try check(warming.tooltip.contains("Warming, no ETA"), "warming tooltip should use readable ETA text")
    try check(warming.accessibilityLabel == "Ghost Process Sniper, Warming", "warming accessibility label should be concise")
    try check(warming.compactStateText == "Warm", "popover state chip should collapse warming text")
}

private func menuBarPresentationKeepsDiagnosticsOutOfTitle() throws {
    let summary = RadarSummary(
        statusText: "Leak 840 MB/min",
        level: .hot,
        familyCount: 5,
        hotCount: 2,
        totalMemoryBytes: 2_400_000_000,
        topFamilyName: "node",
        leakingCount: 1
    )
    let metrics = RadarPerformanceMetrics.empty.updatingSmoothness(
        mainActorPublishMilliseconds: 9,
        duplicateClusterCount: 3
    )
    let first = MenuBarStatusPresentation(
        summary: summary,
        engineStatus: .empty,
        metrics: metrics
    )
    let second = MenuBarStatusPresentation(
        summary: summary,
        engineStatus: .empty,
        metrics: metrics.updatingSmoothness(mainActorPublishMilliseconds: 15)
    )

    try check(first.title.isEmpty, "hot/leak diagnostics should never appear in menu bar title")
    try check(first.tooltip.contains("2 hot"), "tooltip should include hot count")
    try check(first.tooltip.contains("1 leaks"), "tooltip should include leak count")
    try check(first.tooltip.contains("3 duplicate clusters"), "tooltip should include duplicate cluster count")
    try check(first.renderKey == second.renderKey, "diagnostics-only publish cost changes should not invalidate status presentation")
}

private func refreshGateCoalescesOverlappingRequests() async throws {
    let gate = RefreshGate()
    let first = await gate.begin()
    let second = await gate.begin()
    let third = await gate.begin()
    let finished = await gate.finish()
    try check(first == .run, "first refresh should enter the gate")
    try check(second == .coalesced(1), "second refresh should coalesce while one is running")
    try check(third == .coalesced(2), "third refresh should increment coalesced count")
    try check(finished == 2, "finish should report coalesced refreshes")
    let inFlight = await gate.inFlight
    try check(!inFlight, "gate should clear in-flight state after finish")
}

private func radarRefreshWorkerPublishesStableOutcome() async throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 50_000_000
    let samples = [
        sample(pid: 560, name: "node", commandLine: "node server.js", memory: 120_000_000, cpu: 45, sampledAt: Date(timeIntervalSince1970: 9_500))
    ]
    let worker = RadarRefreshWorker(
        sampler: FakeSampler(samples: samples),
        store: nil,
        builder: ProcessFamilyBuilder(currentUserID: 501)
    )
    let outcome = try await worker.refresh(
        RefreshRequest(
            settings: settings,
            currentFamilies: [],
            currentIncidents: [],
            currentStoreHealth: .empty,
            previousRefresh: .empty,
            popoverVisible: false,
            focusedSignatureIDs: [],
            now: Date(timeIntervalSince1970: 9_500),
            startedAt: Date(timeIntervalSince1970: 9_500)
        )
    )

    try check(outcome.families.count == 1, "refresh worker should build families off the monitor facade")
    try check(outcome.summary.level >= .hot, "refresh worker should score the sampled process")
    try check(outcome.performance.refreshInFlight, "worker metrics should mark the refresh as in-flight until monitor publish")
    try check(outcome.model.families.map(\.familyKey) == outcome.families.map(\.familyKey), "worker model should match outcome families")
    try check(outcome.payload.state.consoleSnapshot.contentRevision == outcome.performance.contentRevision, "worker payload should carry a stable content revision")
    try check(outcome.payload.state.detailViewModels[outcome.families[0].familyKey] != nil, "worker payload should precompute detail view models off-main")
    try check(outcome.phaseTrace.totalMilliseconds >= outcome.phaseTrace.sampleMilliseconds, "worker should expose refresh phase trace")
}

private func radarSchedulerAdaptsCadence() throws {
    var scheduler = RadarScheduler()
    var settings = ThresholdSettings.aggressive
    settings.performanceMode = .balanced
    let quiet = RadarSummary(statusText: "Quiet", level: .quiet, familyCount: 0, hotCount: 0, totalMemoryBytes: 0, topFamilyName: nil)
    let hot = RadarSummary(statusText: "1 hot", level: .hot, familyCount: 1, hotCount: 1, totalMemoryBytes: 1, topFamilyName: "node")

    let quietInterval = scheduler.nextInterval(settings: settings, summary: quiet, lastRefresh: .empty, popoverVisible: false)
    let jitteredQuietInterval = scheduler.nextInterval(settings: settings, summary: quiet, lastRefresh: .empty, popoverVisible: false)
    let hotInterval = scheduler.nextInterval(settings: settings, summary: hot, lastRefresh: .empty, popoverVisible: false)
    let plan = scheduler.plan(settings: settings, families: [hotFamily(pid: 900, memory: 300_000_000, cpu: 95)], popoverVisible: false, now: Date())

    try check(quietInterval > hotInterval, "scheduler should back off quiet radar and tighten hot radar")
    try check(jitteredQuietInterval != quietInterval, "quiet scheduler cadence should add small jitter to avoid one-second alignment")
    try check(plan.maxForensicsPerRefresh >= 0, "scheduler should produce a bounded forensics plan")
    try check(plan.commandRefreshInterval >= 20, "quiet balanced plans should avoid frequent command/path sweeps")
}

private func radarSchedulerFocusesSelectedFamilies() throws {
    var scheduler = RadarScheduler()
    let family = hotFamily(pid: 905, memory: 90_000_000, cpu: 1, score: GhostScore(value: 8, level: .quiet, reasons: ["quiet dev process"]))
    let plan = scheduler.plan(
        settings: .aggressive,
        families: [family],
        popoverVisible: false,
        focusedSignatureIDs: [family.signature.id],
        now: Date(timeIntervalSince1970: 9_000)
    )

    try check(plan.includeForensicsFor.contains(family.root.identity), "focused family should receive fresh forensics even when quiet")
    try check(plan.probePolicy.richMetricIdentities.contains(family.root.identity), "focused family should receive rich metric promotion")
    try check(plan.reason == "focused-family", "focused plan should explain why forensics is requested")
}

private func radarPipelineDiffsAndHoldsLevels() throws {
    var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: 501))
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 100_000_000
    let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: RadarRule.builtIns(settings: settings))
    let hotProcesses = [sample(pid: 910, name: "node", commandLine: "node server.js", memory: 180_000_000, cpu: 90, sampledAt: Date(timeIntervalSince1970: 10_000))]
    let quietProcesses = [sample(pid: 910, name: "node", commandLine: "node server.js", memory: 10_000_000, cpu: 0, sampledAt: Date(timeIntervalSince1970: 10_005))]

    let first = pipeline.run(processes: hotProcesses, settings: settings, context: context, now: Date(timeIntervalSince1970: 10_000))
    let second = pipeline.run(processes: quietProcesses, settings: settings, context: context, now: Date(timeIntervalSince1970: 10_005))

    try check(first.diff.added.count == 1, "pipeline should detect newly seen process identity")
    try check(second.diff.changed.count == 1, "pipeline should detect metric changes")
    try check(second.families.first?.score.level ?? .quiet >= .watch, "hysteresis should avoid immediate hot-to-quiet flicker")
}

private func familyScoringCacheReusesUnchangedFamilies() throws {
    var cache = FamilyScoringCache()
    let family = hotFamily(pid: 920, memory: 300_000_000, cpu: 55)
    let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: RadarRule.builtIns(settings: .aggressive))

    try check(cache.cachedFamily(for: family, context: context) == nil, "empty scoring cache should miss")
    cache.store(family, context: context)
    try check(cache.cachedFamily(for: family, context: context) == family, "unchanged scoring inputs should reuse cached family")

    let changedContext = RadarContext(
        baselines: [:],
        recentIncidentCounts: [family.signature.id: 2],
        rules: RadarRule.builtIns(settings: .aggressive)
    )
    try check(cache.cachedFamily(for: family, context: changedContext) == nil, "incident context changes should invalidate cached score")
}

@MainActor
private func monitorPublishesRadarSummary() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 100_000_000
    let monitor = ProcessMonitor(
        sampler: FakeSampler(samples: []),
        builder: ProcessFamilyBuilder(currentUserID: 501),
        settings: settings,
        store: nil
    )
    monitor.ingest(
        [
            sample(pid: 300, name: "node", commandLine: "node api.js", memory: 150_000_000, sampledAt: Date(timeIntervalSince1970: 3_000)),
            sample(pid: 301, name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", commandLine: "Safari", memory: 20_000_000, sampledAt: Date(timeIntervalSince1970: 3_000))
        ],
        now: Date(timeIntervalSince1970: 3_000)
    )

    try check(monitor.families.count == 1, "dev radar should publish matching family")
    try check(monitor.summary.familyCount == 1, "summary should count family")
    try check(monitor.summary.level >= .hot, "summary should reflect hot threshold")
    try check(monitor.triageFamilies.count == 1, "monitor should publish stable triage view models")
    try check(monitor.detailViewModel(signatureID: monitor.families[0].signature.id) != nil, "monitor should publish family detail view models")
}

@MainActor
private func monitorPublishedStateObserversCanBeRemoved() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 100_000_000
    let monitor = ProcessMonitor(
        sampler: FakeSampler(samples: []),
        builder: ProcessFamilyBuilder(currentUserID: 501),
        settings: settings,
        store: nil
    )
    var publishCount = 0
    var lastSummary: RadarSummary?
    let id = monitor.addPublishedStateObserver { state in
        publishCount += 1
        lastSummary = state.summary
    }

    monitor.ingest(
        [sample(pid: 306, name: "node", commandLine: "node observer.js", memory: 150_000_000)],
        now: Date(timeIntervalSince1970: 3_060)
    )
    try check(publishCount == 1, "published-state observer should fire once per monitor publish")
    try check(lastSummary?.familyCount == 1, "published-state observer should receive the published state")

    monitor.removePublishedStateObserver(id)
    monitor.ingest(
        [sample(pid: 307, name: "node", commandLine: "node observer-2.js", memory: 160_000_000)],
        now: Date(timeIntervalSince1970: 3_070)
    )
    try check(publishCount == 1, "removed published-state observer should not fire")
}

@MainActor
private func monitorDiagnosticsOnlyPublishKeepsViewModelStable() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 100_000_000
    let process = sample(pid: 308, name: "node", commandLine: "node stable.js", memory: 150_000_000)
    let monitor = ProcessMonitor(
        sampler: FakeSampler(samples: []),
        builder: ProcessFamilyBuilder(currentUserID: 501),
        settings: settings,
        store: nil
    )

    monitor.ingest([process], now: Date(timeIntervalSince1970: 3_080))
    let firstViewModel = monitor.viewModel
    let firstPerformance = monitor.performanceMetrics
    monitor.ingest([process], now: Date(timeIntervalSince1970: 3_081))

    try check(monitor.consoleSnapshot.contentRevision == firstPerformance.contentRevision, "same content ingest should stay diagnostics-only")
    try check(monitor.performanceMetrics.diagnosticsOnlyPublishCount > firstPerformance.diagnosticsOnlyPublishCount, "same content ingest should count diagnostics-only publish")
    try check(monitor.viewModel == firstViewModel, "diagnostics-only monitor publish should avoid viewModel observable churn")
}

@MainActor
private func monitorPublishObserversCanMutateRegistrationDuringCallback() throws {
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 100_000_000
    let monitor = ProcessMonitor(
        sampler: FakeSampler(samples: []),
        builder: ProcessFamilyBuilder(currentUserID: 501),
        settings: settings,
        store: nil
    )
    var firstCount = 0
    var secondCount = 0
    var firstID: UUID?
    firstID = monitor.addPublishedStateObserver { _ in
        firstCount += 1
        if let firstID {
            monitor.removePublishedStateObserver(firstID)
        }
        _ = monitor.addPublishedStateObserver { _ in
            secondCount += 1
        }
    }

    monitor.ingest(
        [sample(pid: 309, name: "node", commandLine: "node mutable-observer.js", memory: 150_000_000)],
        now: Date(timeIntervalSince1970: 3_090)
    )
    try check(firstCount == 1, "observer should fire before removing itself")
    try check(secondCount == 0, "observer added during publish should not fire in the same notification pass")

    monitor.ingest(
        [sample(pid: 309, name: "node", commandLine: "node mutable-observer.js", memory: 150_000_000)],
        now: Date(timeIntervalSince1970: 3_091)
    )
    try check(firstCount == 1, "removed observer should stay removed")
    try check(secondCount == 1, "observer added during previous publish should fire on the next publish")
}

private func radarStorePersistsSettingsRulesAndIncidents() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 42_000_000

    try await store.saveSettings(settings)
    let loaded = try await store.loadSettings(defaults: .aggressive)
    try check(loaded.memoryBytes == settings.memoryBytes, "store should persist threshold settings")

    let rule = RadarRule(
        name: "Highlight node",
        match: RadarRuleMatch(commandContains: "node", minimumLevel: .watch),
        action: .highlight
    )
    try await store.saveRule(rule)
    let rules = try await store.loadRules(settings: settings)
    try check(rules.contains(where: { $0.id == rule.id }), "store should persist custom rules")

    let family = hotFamily(pid: 500, memory: 300_000_000, cpu: 95)
    let model = RadarModel(
        families: [family],
        summary: RadarSummary(
            statusText: "1 hot",
            level: .critical,
            familyCount: 1,
            hotCount: 1,
            totalMemoryBytes: family.totalPhysicalFootprintBytes,
            topFamilyName: family.displayName
        ),
        incidents: [],
        rules: rules,
        health: .starting,
        generatedAt: Date(timeIntervalSince1970: 5_000)
    )

    try await store.persist(model: model, settings: settings)
    let incidents = try await store.recentIncidents()
    try check(incidents.count == 1, "store should create an incident for hot families")
    try check(incidents.first?.familyName == "node", "incident should include family name")
}

private func radarStoreQueriesIncidentsAndTogglesRules() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    let settings = ThresholdSettings.aggressive
    let family = hotFamily(pid: 505, memory: 700_000_000, cpu: 95)
    let model = RadarModel(
        families: [family],
        summary: RadarSummary(statusText: "1 hot", level: .critical, familyCount: 1, hotCount: 1, totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName),
        incidents: [],
        rules: RadarRule.builtIns(settings: settings),
        health: .starting,
        generatedAt: Date(timeIntervalSince1970: 7_500)
    )

    try await store.persist(model: model, settings: settings)
    let stored = try await store.recentIncidents()
    let queried = IncidentQuery(text: "node", filter: .active, sort: .severity, limit: 5).apply(to: stored)
    try check(queried.count == 1, "store should query active incidents")

    let rule = RadarRule(
        name: "Notify node",
        isBuiltIn: false,
        match: RadarRuleMatch(commandContains: "node", minimumLevel: .watch),
        action: .notify
    )
    try await store.saveRule(rule)
    try await store.setRuleEnabled(id: rule.id, isEnabled: false)
    let disabled = try await store.loadRules(includeBuiltIns: false).first { $0.id == rule.id }
    try check(disabled?.isEnabled == false, "store should toggle custom rule enabled state")
}

private func radarStorePersistsForecastSnapshots() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let base = forecastFamily(
        pid: 506,
        memory: 320 * 1_048_576,
        cpu: 10,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 70,
            cpuSlopePerMinute: 0,
            memoryPoints: [200, 250, 290, 320].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    let forecast = forecastWithFreshMeasurements(
        family: base,
        settings: settings,
        now: Date(timeIntervalSince1970: 7_600)
    )
    let family = base.enriched(forecast: forecast)
    let model = RadarModel(
        families: [family],
        summary: RadarSummary(statusText: "Warming", level: .watch, familyCount: 1, hotCount: 0, totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName),
        incidents: [],
        rules: RadarRule.builtIns(settings: settings),
        health: .starting,
        generatedAt: Date(timeIntervalSince1970: 7_600)
    )

    try await store.persist(model: model, settings: settings)
    let forecasts = try await store.recentForecasts(limit: 5)
    let alerts = try await store.recentPredictiveAlerts(limit: 5)
    let diagnostics = try await store.exportDiagnosticsReport(settings: settings)

    try check(forecasts.first?.state == forecast.state, "store should persist latest forecast state additively")
    try check(forecasts.first?.whyNow == forecast.whyNow, "forecast query should preserve why-now text")
    try check(!alerts.isEmpty, "leaking predictive forecasts should create advisory alerts")
    try check(diagnostics.contains("Forecasts:"), "store diagnostics should include forecast table health")
}

private func radarStoreCoalescesRecommendationHistory() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    let base = forecastFamily(
        pid: 507,
        memory: 350 * 1_048_576,
        cpu: 10,
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 80,
            cpuSlopePerMinute: 0,
            memoryPoints: [220, 260, 310, 350].map { Double($0 * 1_048_576) }
        ),
        score: GhostScore(value: 18, level: .quiet, reasons: ["dev process warming"])
    )
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 500 * 1_048_576
    let forecast = forecastWithFreshMeasurements(
        family: base,
        settings: settings,
        now: Date(timeIntervalSince1970: 7_700)
    )
    let family = base.enriched(forecast: forecast)
    let model = RadarModel(
        families: [family],
        summary: RadarSummary(statusText: "Leak soon", level: .hot, familyCount: 1, hotCount: 1, totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName),
        incidents: [],
        rules: RadarRule.builtIns(settings: settings),
        health: .starting,
        generatedAt: Date(timeIntervalSince1970: 7_700)
    )

    try await store.persist(model: model, settings: settings)
    try await store.persist(model: model, settings: settings)
    let health = await store.storeHealth()

    try check(health.coalescingStats.recommendationSkippedCount >= 1, "store should skip duplicate recommendation history inside cooldown")
    try check(health.coalescingStats.forecastWrites == 1, "store should upsert one forecast per signature")
}

@MainActor
private func monitorDebouncesSettingsPersistence() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 123_000_000
    let monitor = ProcessMonitor(
        sampler: FakeSampler(samples: []),
        settings: settings,
        store: store
    )

    monitor.settings.memoryBytes = 321_000_000
    monitor.saveSettingsDebounced(delay: 0)
    try await Task.sleep(nanoseconds: 60_000_000)
    let loaded = try await store.loadSettings(defaults: .aggressive)

    try check(loaded.memoryBytes == 321_000_000, "monitor should persist settings via debounced save")
}

private func radarStoreBatchesQueuedWrites() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    let settings = ThresholdSettings.aggressive
    let family = hotFamily(pid: 510, memory: 300_000_000, cpu: 90)
    let model = RadarModel(
        families: [family],
        summary: RadarSummary(statusText: "1 hot", level: .hot, familyCount: 1, hotCount: 1, totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName),
        incidents: [],
        rules: RadarRule.builtIns(settings: settings),
        health: .starting,
        generatedAt: Date(timeIntervalSince1970: 7_000)
    )

    _ = try await store.enqueue(model: model, settings: settings, now: Date(timeIntervalSince1970: 7_000))
    let queued = try await store.enqueue(model: model, settings: settings, now: Date(timeIntervalSince1970: 7_001))
    try check(queued.backlogCount == 1, "store should keep rapid follow-up writes queued")
    try await store.flush(now: Date(timeIntervalSince1970: 7_002))
    let flushed = await store.storeHealth()
    try check(flushed.backlogCount == 0, "store flush should drain queued models")
    try check(flushed.lastFlushDate != nil, "store health should expose flush time")
}

private func radarStoreSkipsUnchangedSettingsAndBatchesContext() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    let settings = ThresholdSettings.aggressive

    try await store.saveSettings(settings)
    try await store.saveSettings(settings)
    let healthAfterSettings = await store.storeHealth()
    try check(healthAfterSettings.skippedSettingsWriteCount >= 1, "store should skip unchanged settings writes")

    let families = [
        hotFamily(pid: 515, memory: 300_000_000, cpu: 90),
        hotFamily(pid: 516, memory: 260_000_000, cpu: 30)
    ]
    _ = try await store.context(for: families, settings: settings, now: Date(timeIntervalSince1970: 8_000))
    let healthAfterContext = await store.storeHealth()
    try check(healthAfterContext.lastContextMilliseconds >= 0, "store health should expose batched context timing")
}

private func radarStoreCachesQuietRuleContext() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    let family = hotFamily(pid: 518, memory: 400_000_000, cpu: 12)
    let rule = RadarRule(
        name: "Quiet node check",
        match: RadarRuleMatch(commandContains: "node", minimumLevel: .quiet),
        action: .highlight
    )

    try await store.saveRule(rule)
    _ = try await store.context(for: [family], settings: .aggressive, now: Date(timeIntervalSince1970: 8_100))
    let firstHealth = await store.storeHealth()
    _ = try await store.context(for: [family], settings: .aggressive, now: Date(timeIntervalSince1970: 8_101))
    let secondHealth = await store.storeHealth()

    try check(secondHealth.rulesCacheHitCount > firstHealth.rulesCacheHitCount, "quiet context refresh should reuse cached rule composition")
}

private func radarIntelligenceEscalatesBaselineAnomalies() throws {
    let intelligence = RadarIntelligence()
    let family = hotFamily(pid: 520, memory: 420_000_000, cpu: 15, score: GhostScore(value: 32, level: .watch, reasons: ["dev process"]))
    let baseline = FamilyBaseline(
        signature: family.signature,
        sampleCount: 8,
        meanMemoryBytes: 100_000_000,
        peakMemoryBytes: 120_000_000,
        meanCPUPercent: 5,
        peakCPUPercent: 8,
        meanLeakVelocityMegabytesPerMinute: 0,
        incidentCount: 2,
        firstSeenAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 2)
    )
    let context = RadarContext(
        baselines: [family.signature.id: baseline],
        recentIncidentCounts: [family.signature.id: 2],
        rules: RadarRule.builtIns(settings: .aggressive)
    )

    let enriched = intelligence.enrich(
        families: [freshMeasurements(family, at: Date(timeIntervalSince1970: 5_000))],
        context: context,
        settings: .aggressive,
        now: Date(timeIntervalSince1970: 5_000)
    )

    try check(enriched.first?.score.level ?? .quiet >= .hot, "baseline anomaly should escalate level")
    try check(enriched.first?.score.reasons.contains(where: { $0.contains("usual memory") }) == true, "baseline reason should explain memory anomaly")
}

private func culpritAnalysisExplainsLikelyCause() throws {
    let family = hotFamily(pid: 525, memory: 520_000_000, cpu: 25)
    let analysis = CulpritAnalysis(family: family)
    try check(analysis.kind == .nodeServer, "culprit analysis should classify node family")
    try check(analysis.likelyCause.lowercased().contains("node"), "culprit analysis should explain likely cause")
    try check(!analysis.nextAction.isEmpty, "culprit analysis should suggest a next action")

    let goRoot = sample(pid: 601, name: "my-go-backend", executablePath: "/Users/dev/project/bin/my-go-backend", commandLine: "./bin/my-go-backend", memory: 200_000_000, cpu: 10)
    let goFamily = ProcessFamily(
        root: goRoot,
        members: [goRoot],
        totalResidentMemoryBytes: 200_000_000,
        totalPhysicalFootprintBytes: 200_000_000,
        totalCPUPercent: 10,
        devConfidence: 0.9,
        commandHints: [],
        trend: TrendMetrics(memoryVelocityMegabytesPerMinute: 0, cpuSlopePerMinute: 0, memoryPoints: []),
        score: GhostScore(value: 50, level: .watch, reasons: []),
        ownedIdentities: [goRoot.identity],
        protectedPIDs: [],
        baseline: nil,
        recentIncidentCount: 0
    )
    let goAnalysis = CulpritAnalysis(family: goFamily)
    try check(goAnalysis.kind == .goService, "culprit analysis should classify Go family")
    try check(goAnalysis.likelyCause.lowercased().contains("go"), "culprit analysis should explain likely cause for Go")

    let rustRoot = sample(pid: 602, name: "my-rust-service", executablePath: "/Users/dev/project/target/debug/my-rust-service", commandLine: "./target/debug/my-rust-service", memory: 150_000_000, cpu: 5)
    let rustFamily = ProcessFamily(
        root: rustRoot,
        members: [rustRoot],
        totalResidentMemoryBytes: 150_000_000,
        totalPhysicalFootprintBytes: 150_000_000,
        totalCPUPercent: 5,
        devConfidence: 0.9,
        commandHints: [],
        trend: TrendMetrics(memoryVelocityMegabytesPerMinute: 0, cpuSlopePerMinute: 0, memoryPoints: []),
        score: GhostScore(value: 40, level: .watch, reasons: []),
        ownedIdentities: [rustRoot.identity],
        protectedPIDs: [],
        baseline: nil,
        recentIncidentCount: 0
    )
    let rustAnalysis = CulpritAnalysis(family: rustFamily)
    try check(rustAnalysis.kind == .rustService, "culprit analysis should classify Rust family")
    try check(rustAnalysis.likelyCause.lowercased().contains("rust"), "culprit analysis should explain likely cause for Rust")

    let bunRoot = sample(pid: 603, name: "bun", commandLine: "bun run server.ts", memory: 120_000_000, cpu: 12)
    let bunFamily = ProcessFamily(
        root: bunRoot,
        members: [bunRoot],
        totalResidentMemoryBytes: 120_000_000,
        totalPhysicalFootprintBytes: 120_000_000,
        totalCPUPercent: 12,
        devConfidence: 0.9,
        commandHints: [],
        trend: TrendMetrics(memoryVelocityMegabytesPerMinute: 0, cpuSlopePerMinute: 0, memoryPoints: []),
        score: GhostScore(value: 45, level: .watch, reasons: []),
        ownedIdentities: [bunRoot.identity],
        protectedPIDs: [],
        baseline: nil,
        recentIncidentCount: 0
    )
    let bunAnalysis = CulpritAnalysis(family: bunFamily)
    try check(bunAnalysis.kind == .bunServer, "culprit analysis should classify Bun family")
    try check(bunAnalysis.likelyCause.lowercased().contains("bun"), "culprit analysis should explain likely cause for Bun")

    let panel = FamilyDetailPanelModel(family: family, previous: nil)
    try check(panel.culprit.kind == .nodeServer, "detail panel should precompute culprit analysis")
}

private func radarRuleEngineMatchesAdvisoryRules() throws {
    let engine = RadarRuleEngine()
    let family = hotFamily(pid: 530, memory: 200_000_000, cpu: 10)
    let rule = RadarRule(
        name: "Inspect node command",
        match: RadarRuleMatch(commandContains: "server.js", minimumLevel: .watch),
        action: .inspect
    )
    let suggestions = engine.suggestions(for: family, rules: [rule], now: Date(timeIntervalSince1970: 5_000))

    try check(suggestions.map(\.type) == [.inspect], "rule engine should return matching advisory action")

    let ignore = RadarRule(
        name: "Ignore exact family",
        match: RadarRuleMatch(signatureID: family.signature.id, minimumLevel: .quiet),
        action: .ignore
    )
    let state = engine.alertState(for: family, suggestions: engine.suggestions(for: family, rules: [ignore], now: Date()), now: Date())
    try check(state.kind == .ignored, "ignore rule should suppress alert state")
}

@MainActor
private func monitorPersistsIncidentsWithInjectedStore() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try RadarStore(url: url)
    var settings = ThresholdSettings.aggressive
    settings.memoryBytes = 50_000_000
    let monitor = ProcessMonitor(
        sampler: FakeSampler(samples: [sample(pid: 550, name: "node", commandLine: "node server.js", memory: 120_000_000, cpu: 95, sampledAt: Date(timeIntervalSince1970: 6_000))]),
        builder: ProcessFamilyBuilder(currentUserID: 501),
        settings: settings,
        store: store
    )

    await monitor.refresh(now: Date(timeIntervalSince1970: 6_000))

    try check(monitor.families.count == 1, "monitor should publish family with injected store")
    try check(!monitor.incidents.isEmpty, "monitor should publish persisted incidents")
    try check(monitor.rules.contains(where: { $0.isBuiltIn }), "monitor should publish built-in rules")
}

private func radarPipelineHandlesLargeSamplesWithinBudget() throws {
    var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: 501))
    var settings = ThresholdSettings.aggressive
    settings.radarMode = .heavy
    let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: RadarRule.builtIns(settings: settings))

    let twoThousand = syntheticProcesses(count: 2_000, sampledAt: Date(timeIntervalSince1970: 8_000))
    let startSmall = Date()
    _ = pipeline.run(processes: twoThousand, settings: settings, context: context, now: Date(timeIntervalSince1970: 8_000))
    let smallMS = Date().timeIntervalSince(startSmall) * 1_000
    try check(smallMS < 1500, "2k-process pipeline should stay within debug budget, got \(Int(smallMS))ms")
 
    let tenThousand = syntheticProcesses(count: 10_000, sampledAt: Date(timeIntervalSince1970: 8_010))
    let startLarge = Date()
    _ = pipeline.run(processes: tenThousand, settings: settings, context: context, now: Date(timeIntervalSince1970: 8_010))
    let largeMS = Date().timeIntervalSince(startLarge) * 1_000
    try check(largeMS < 5_000, "10k-process pipeline should stay within debug budget, got \(Int(largeMS))ms")
 
    let thirtyThousand = syntheticProcesses(count: 30_000, sampledAt: Date(timeIntervalSince1970: 8_020))
    let startHuge = Date()
    _ = pipeline.run(processes: thirtyThousand, settings: settings, context: context, now: Date(timeIntervalSince1970: 8_020))
    let hugeMS = Date().timeIntervalSince(startHuge) * 1_000
    try check(hugeMS < 15_000, "30k-process pipeline should stay within debug budget, got \(Int(hugeMS))ms")
}

private func consoleSnapshotContentRevisionAvoidsGeneratedAtInvalidation() throws {
    let family = hotFamily(pid: 930, memory: 300_000_000, cpu: 20)
    let summary = RadarSummary(
        statusText: "Watching",
        level: .watch,
        familyCount: 1,
        hotCount: 0,
        totalMemoryBytes: family.totalPhysicalFootprintBytes,
        topFamilyName: family.displayName
    )
    let first = RadarConsoleSnapshot.build(
        families: [family],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 1)
    )
    let second = RadarConsoleSnapshot.build(
        families: [family],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty.updatingSmoothness(mainActorPublishMilliseconds: 4),
        health: .starting,
        storeHealth: StoreHealth(
            backlogCount: 1,
            pendingActionCount: 0,
            lastFlushDate: nil,
            lastPruneDate: nil,
            errorMessage: nil
        ),
        storeError: nil,
        previous: first,
        generatedAt: Date(timeIntervalSince1970: 2)
    )
    let metricVersionOnly = RadarConsoleSnapshot.build(
        families: [family.enriched(metricsVersion: family.metricsVersion + 10)],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: first,
        generatedAt: Date(timeIntervalSince1970: 3)
    )
    var state = RadarConsoleState.default
    state.focusedSelection = .family(family.familyKey)

    try check(first.contentRevision == second.contentRevision, "content revision should ignore generatedAt-only changes")
    try check(derivedKey(first, state) == derivedKey(second, state), "derived snapshot key should stay stable across diagnostics-only refreshes")
    try check(metricVersionOnly.contentRevision == first.contentRevision, "content revision should ignore raw per-refresh metricsVersion churn")
    try check(derivedKey(first, state) == derivedKey(metricVersionOnly, state), "metric-version-only refreshes should reuse derived snapshot rows")
    try check(second.generatedAt != first.generatedAt, "snapshot should still update engine/generatedAt diagnostics")
    try check(second.families == first.families, "unchanged content should reuse precomputed family rows")
    try check(second.compact.allRows == first.compact.allRows, "unchanged content should reuse compact family rows")
    try check(second.compact.detailModels == first.compact.detailModels, "unchanged content should reuse compact detail panels")
    try check(second.compact.engineStatus.backlogText != first.compact.engineStatus.backlogText, "compact engine status should update independently from compact rows")
}

private func radarSnapshotSurfacesDuplicateRowsAndStableRevision() throws {
    let family = hotFamily(pid: 940, memory: 180_000_000, cpu: 8)
    let first = sample(
        pid: 941,
        parentPID: 1,
        name: "miniwatch",
        executablePath: "/Users/dev/.local/bin/miniwatch",
        commandLine: "miniwatch --repo api",
        memory: 30_000_000,
        cpu: 3
    )
    let second = sample(
        pid: 942,
        parentPID: 1,
        start: 2,
        name: "miniwatch",
        executablePath: "/Users/dev/.local/bin/miniwatch",
        commandLine: "miniwatch --repo web",
        memory: 34_000_000,
        cpu: 2
    )
    let third = sample(
        pid: 943,
        parentPID: 1,
        start: 3,
        name: "miniwatch",
        executablePath: "/Users/dev/.local/bin/miniwatch",
        commandLine: "miniwatch --repo worker",
        memory: 36_000_000,
        cpu: 1
    )
    let smallerA = sample(
        pid: 944,
        parentPID: 1,
        name: "tiny-agent",
        executablePath: "/Users/dev/.local/bin/tiny-agent",
        commandLine: "tiny-agent a",
        memory: 12_000_000,
        cpu: 1
    )
    let smallerB = sample(
        pid: 945,
        parentPID: 1,
        start: 2,
        name: "tiny-agent",
        executablePath: "/Users/dev/.local/bin/tiny-agent",
        commandLine: "tiny-agent b",
        memory: 10_000_000,
        cpu: 1
    )
    let detector = DuplicateClusterDetector(currentUserID: 501)
    let classifications: [Int32: DevClassification] = [:]
    let duplicateSet = detector.detect(
        processes: [first, second, third, smallerA, smallerB],
        classifications: classifications
    )
    let summary = RadarSummary(
        statusText: "Watching",
        level: .watch,
        familyCount: 1,
        hotCount: 0,
        totalMemoryBytes: family.totalPhysicalFootprintBytes,
        topFamilyName: family.displayName
    )
    let baseline = RadarConsoleSnapshot.build(
        families: [family],
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 1)
    )
    let withDuplicates = RadarConsoleSnapshot.build(
        families: [family],
        duplicateClusters: duplicateSet.clusters,
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty.updatingSmoothness(duplicateClusterCount: duplicateSet.visibleClusters.count),
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: baseline,
        generatedAt: Date(timeIntervalSince1970: 2)
    )
    let diagnosticsOnly = RadarConsoleSnapshot.build(
        families: [family],
        duplicateClusters: duplicateSet.clusters,
        summary: summary,
        incidents: [],
        rules: RadarRule.builtIns(settings: .aggressive),
        metrics: .empty.updatingSmoothness(mainActorPublishMilliseconds: 3, duplicateClusterCount: duplicateSet.visibleClusters.count),
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: withDuplicates,
        generatedAt: Date(timeIntervalSince1970: 3)
    )
    var state = RadarConsoleState.default
    state.focusedSelection = .duplicates

    try check(withDuplicates.duplicateRows.count == 2, "snapshot should precompute duplicate rows")
    try check(withDuplicates.duplicateRows.map(\.countText) == ["3", "2"], "duplicate rows should sort by count, then memory, then CPU")
    try check(withDuplicates.compact.commandCenter.chips.contains(where: { $0.title == "Duplicates" && $0.value == "2" }), "overview should expose duplicate summary chip")
    try check(withDuplicates.contentRevision != baseline.contentRevision, "duplicate content should change snapshot revision")
    try check(diagnosticsOnly.contentRevision == withDuplicates.contentRevision, "diagnostics-only duplicate refresh should keep content revision stable")
    try check(ConsoleDerivedSnapshot.build(snapshot: withDuplicates, incidents: [], state: state).duplicateRows.count == 2, "derived snapshot should expose duplicate rows")
}

private func radarPublishPayloadPrecomputesViewState() throws {
    let family = hotFamily(pid: 931, memory: 800_000_000, cpu: 85)
    let summary = RadarSummary(
        statusText: "1 hot",
        level: .hot,
        familyCount: 1,
        hotCount: 1,
        totalMemoryBytes: family.totalPhysicalFootprintBytes,
        topFamilyName: family.displayName
    )
    let payload = RadarPublishPayload.build(
        families: [family],
        summary: summary,
        rules: RadarRule.builtIns(settings: .aggressive),
        incidents: [],
        health: SamplerHealth(engineName: "test", lastSampleDate: nil, processCount: 1, familyCount: 1, errorMessage: nil),
        storeHealth: .empty,
        storeError: nil,
        performance: .empty,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 3)
    )

    try check(payload.state.families.map(\.familyKey) == [family.familyKey], "publish payload should preserve families")
    try check(payload.state.consoleSnapshot.families.map(\.familyKey) == [family.familyKey], "publish payload should precompute console rows")
    try check(payload.state.detailViewModels[family.familyKey] != nil, "publish payload should precompute detail view models")
    try check(payload.state.performanceMetrics.contentRevision == payload.state.consoleSnapshot.contentRevision, "payload performance should share the snapshot content revision")
    try check(payload.state.engineDiagnostics == payload.state.consoleSnapshot.engine, "payload should publish engine diagnostics separately")
    try check(payload.state.engineStatus == payload.state.consoleSnapshot.compact.engineStatus, "payload should publish lightweight engine status separately")
    try check(payload.state.consoleSnapshot.compact.detailModels[family.familyKey] != nil, "payload should precompute compact detail models")
}

private func processKillerTerminatesKillPlanInTreeOrder() async throws {
    let root = process(pid: 10, parentPID: 1, userID: 501)
    let child = process(pid: 11, parentPID: 10, userID: 501)
    let foreign = process(pid: 12, parentPID: 10, userID: 0)
    let lookup = FakeLookup(samples: [root, child, foreign])
    let signaler = FakeSignaler()
    let killer = ProcessKiller(
        lookup: lookup,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )
    let plan = KillPlan(
        rootIdentity: root.identity,
        targetIdentities: [child.identity, root.identity],
        protectedPIDs: [foreign.pid],
        displayName: "generic"
    )

    let report = await killer.kill(plan: plan, forceKillDelay: 0)

    try check(report.gracefulPIDs == [11, 10], "killer should terminate child before root")
    try check(report.deniedPIDs == [12], "killer should keep protected child denied")
    try check(signaler.sent == [Signal(pid: 11, signal: SIGTERM), Signal(pid: 10, signal: SIGTERM)], "killer should send SIGTERM to owned identities")
}

private func processKillerEscalatesSurvivingIdentities() async throws {
    let target = process(pid: 20, parentPID: 1, userID: 501)
    let lookup = FakeLookup(samples: [target])
    let signaler = FakeSignaler(aliveAfterTerm: [20])
    let killer = ProcessKiller(
        lookup: lookup,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(report.gracefulPIDs == [20], "killer should send graceful termination")
    try check(report.forcedPIDs == [20], "killer should escalate surviving identity")
    try check(signaler.sent == [Signal(pid: 20, signal: SIGTERM), Signal(pid: 20, signal: SIGKILL)], "killer should send SIGTERM then SIGKILL")
}

private func processKillerRejectsRecycledPID() async throws {
    let original = process(pid: 30, parentPID: 1, userID: 501, start: 100)
    let recycled = process(pid: 30, parentPID: 1, userID: 501, start: 101)
    let signaler = FakeSignaler()
    let killer = ProcessKiller(
        lookup: FakeLookup(samples: [recycled]),
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: original.identity, targetIdentities: [original.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(report.recycledPIDs == [30], "recycled PID should be reported separately")
    try check(signaler.sent.isEmpty, "recycled PID must not be signaled")
}

private func processKillerDeniesForeignProcesses() async throws {
    let target = process(pid: 40, parentPID: 1, userID: 0)
    let signaler = FakeSignaler()
    let killer = ProcessKiller(
        lookup: FakeLookup(samples: [target]),
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "rootd"),
        forceKillDelay: 0
    )

    try check(report.deniedPIDs == [40], "foreign target should be denied")
    try check(signaler.sent.isEmpty, "foreign target should not be signaled")
}

private func processKillerPreviewsKillPlan() async throws {
    let owned = process(pid: 50, parentPID: 1, userID: 501)
    let foreign = process(pid: 51, parentPID: 1, userID: 0)
    let stale = ProcessIdentity(pid: 52, startTimeSeconds: 100, startTimeMicroseconds: 0)
    let recycled = process(pid: 52, parentPID: 1, userID: 501, start: 101)
    let killer = ProcessKiller(
        lookup: FakeLookup(samples: [owned, foreign, recycled]),
        signaler: FakeSignaler(),
        currentUserID: 501,
        sleeper: { _ in }
    )

    let preview = await killer.preview(
        plan: KillPlan(
            rootIdentity: owned.identity,
            targetIdentities: [owned.identity, foreign.identity, stale],
            protectedPIDs: [99],
            displayName: "generic"
        ),
        forceKillDelay: 1
    )

    try check(preview.targetPIDs == [50], "preview should include only owned live identities")
    try check(preview.deniedPIDs.contains(51), "preview should show denied foreign process")
    try check(preview.protectedPIDs == [99], "preview should keep protected PIDs visible")
    try check(preview.recycledPIDs == [52], "preview should detect recycled PID")
}

private func processKillerPreviewsNewOwnedDescendants() async throws {
    let root = process(pid: 60, parentPID: 1, userID: 501)
    let child = process(pid: 61, parentPID: 60, userID: 501)
    let grandchild = process(pid: 62, parentPID: 61, userID: 501)
    let signaler = FakeSignaler()
    let killer = ProcessKiller(
        lookup: FakeLookup(samples: [root, child, grandchild]),
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )
    let plan = KillPlan(
        rootIdentity: root.identity,
        targetIdentities: [root.identity],
        protectedPIDs: [],
        displayName: "generic"
    )

    let preview = await killer.preview(plan: plan, forceKillDelay: 0)
    let report = await killer.kill(plan: plan, forceKillDelay: 0)

    try check(preview.targetPIDs == [62, 61, 60], "preview should expand newly discovered owned descendants")
    try check(preview.canKill, "owned live tree with new descendants should remain killable")
    try check(preview.targetDiff.addedPIDs == [61, 62], "preview should surface newly discovered descendants as target drift")
    try check(report.gracefulPIDs == [62, 61, 60], "kill should signal deepest descendants before root")
    try check(signaler.sent == [Signal(pid: 62, signal: SIGTERM), Signal(pid: 61, signal: SIGTERM), Signal(pid: 60, signal: SIGTERM)], "signal order should be stable depth then PID")
}

private func processKillerSkipsExitedTargetsBeforeEscalation() async throws {
    let target = process(pid: 70, parentPID: 1, userID: 501)
    let lookup = ScriptedKillLookup(
        snapshots: [
            KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
            KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true),
            KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true)
        ]
    )
    let signaler = FakeSignaler(aliveAfterTerm: [70])
    let killer = ProcessKiller(
        lookup: lookup,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(signaler.sent == [Signal(pid: 70, signal: SIGTERM)], "exited identities should not be escalated")
    try check(report.forcedPIDs.isEmpty, "exited identities should not be force-killed")
    let policies = await lookup.policies()
    try check(policies == [.confirm, .verify, .verify], "kill should use confirm and verification snapshots, got \(policies.map(\.rawValue))")
}

private func processKillerDetectsRecycledPIDDuringEscalation() async throws {
    let target = process(pid: 80, parentPID: 1, userID: 501, start: 100)
    let recycled = process(pid: 80, parentPID: 1, userID: 501, start: 101)
    let lookup = ScriptedKillLookup(
        snapshots: [
            KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
            KillProcessSnapshot(processes: [recycled], policy: .verify, usedCheapPath: true),
            KillProcessSnapshot(processes: [recycled], policy: .verify, usedCheapPath: true)
        ]
    )
    let signaler = FakeSignaler(aliveAfterTerm: [80])
    let killer = ProcessKiller(
        lookup: lookup,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(signaler.sent == [Signal(pid: 80, signal: SIGTERM)], "recycled PID should not receive forced signal")
    try check(report.recycledPIDs == [80], "report should surface PID recycling during escalation")
    try check(report.targetResults.contains { $0.pid == 80 && $0.state == .recycled }, "final target state should show recycled")
}

private func processKillerUsesCheapSnapshotPolicy() async throws {
    let target = process(pid: 90, parentPID: 1, userID: 501)
    let sampler = PlanCaptureSampler(samples: [target])
    let lookup = DefaultProcessLookup(sampler: sampler)
    let preview = try await lookup.killSnapshot(policy: .preflight)
    let plans = await sampler.plans()

    try check(preview.usedCheapPath, "default lookup should mark kill snapshots as cheap")
    try check(plans.last?.allowsOptionalForensics == false, "kill snapshot should disable optional forensics")
    try check(plans.last?.maxForensicsPerRefresh == 0, "kill snapshot should not enqueue forensics")
    try check(plans.last?.scannerBudget.maxTelemetryRefreshes == 0, "kill snapshot should avoid command/path sweeps")
}

private func processKillerUsesDedicatedSnapshotProvider() async throws {
    let target = process(pid: 91, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(
        snapshots: [
            KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true, expensiveCallCount: 0),
            KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true, expensiveCallCount: 0),
            KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true, expensiveCallCount: 0)
        ]
    )
    let killer = ProcessKiller(
        snapshotProvider: provider,
        signaler: FakeSignaler(),
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )
    let policies = await provider.policies()

    try check(report.gracefulPIDs == [91], "dedicated provider kill should still signal owned target")
    try check(policies == [.confirm, .verify, .verify], "kill should request confirm and bounded verification snapshots from the dedicated provider")
}

private func processKillerSkipForceReportsSurvivors() async throws {
    let target = process(pid: 92, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .verify, usedCheapPath: true)
    ])
    let signaler = FakeSignaler(aliveAfterTerm: [92])
    let killer = ProcessKiller(
        snapshotProvider: provider,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0,
        skipForce: true
    )

    try check(report.skipForceRequested, "report should preserve explicit skip-force choice")
    try check(report.forcedPIDs.isEmpty, "skip-force should not send SIGKILL")
    try check(report.survivorPIDs == [92], "skip-force should report remaining live targets")
    try check(signaler.sent == [Signal(pid: 92, signal: SIGTERM)], "skip-force should send only SIGTERM")
}

private func processKillerRecordsMultiPassVerification() async throws {
    let target = process(pid: 93, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true)
    ])
    let signaler = FakeSignaler(aliveAfterTerm: [93])
    let killer = ProcessKiller(
        snapshotProvider: provider,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(report.forcedPIDs == [93], "live pre-force target should receive SIGKILL")
    try check(report.verificationPasses.map(\.stage) == ["pre-force", "post-force", "final-settle"], "kill should record bounded multi-pass verification")
    try check(report.targetResults.contains { $0.pid == 93 && $0.state == .forceKilled }, "final target result should classify force kill")
}

private func processKillerClassifiesExitedBeforeSignal() async throws {
    let target = process(pid: 94, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true)
    ])
    let killer = ProcessKiller(
        snapshotProvider: provider,
        signaler: FailingSignaler(errnoCode: ESRCH),
        currentUserID: 501,
        sleeper: { _ in }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(report.exitedBeforeSignalPIDs == [94], "ESRCH should be tracked as exited before signal")
    try check(report.targetResults.contains { $0.pid == 94 && $0.state == .exitedBeforeSignal }, "target result should expose exited-before-signal state")
}

private func processKillerReportsReclaimEstimate() async throws {
    let target = sample(pid: 96, parentPID: 1, userID: 501, name: "node", memory: 256 * 1_048_576, cpu: 12)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true)
    ])
    let killer = ProcessKiller(
        snapshotProvider: provider,
        signaler: FakeSignaler(),
        currentUserID: 501,
        sleeper: { _ in }
    )

    let preview = await killer.preview(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )
    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(preview.reclaimEstimate.memoryBytes == 256 * 1_048_576, "preview should estimate memory reclaim from cheap target metrics")
    try check(!preview.decisionEvidence.isEmpty, "preview should include decision evidence")
    try check(report.realizedMemoryReclaimBytes == 256 * 1_048_576, "report should carry realized reclaim estimate for terminated targets")
}

private func nativeKillSnapshotProviderUsesBSDGraphAndTargetMetrics() async throws {
    let provider = NativeKillSnapshotProvider()
    let initial = try await provider.snapshot(policy: .preflight)
    guard let current = initial.processes.first(where: { $0.pid == getpid() }) else {
        throw CheckFailure(message: "native kill graph did not include current process")
    }

    let request = KillSnapshotRequest(
        policy: .preflight,
        rootIdentity: current.identity,
        targetIdentities: [current.identity],
        budget: KillSnapshotBudget(targetMilliseconds: 30, maxHeavyMetricReads: 1)
    )
    let snapshot = try await provider.snapshot(request: request)
    let graphTarget = snapshot.graph?.processes.first(where: { $0.pid == getpid() })

    try check(snapshot.graph?.usedBSDInfoPath == true, "native kill snapshot should use PROC_PIDTBSDINFO graph path")
    try check(snapshot.graphReadCount > 0, "native kill graph should count cheap BSD reads")
    try check(snapshot.heavyMetricReadCount <= 1, "native kill graph should cap target-only heavy metrics")
    try check(graphTarget?.didReadHeavyMetrics == true, "selected target should receive heavy metrics")
    try check(snapshot.expensiveCallCount == snapshot.heavyMetricReadCount, "expensive count should only represent target heavy metrics")
}

private func killGraphArenaIndexesAndSlicesOwnedFamily() throws {
    let root = lite(pid: 170, parentPID: 1, userID: 501, processGroupID: 77)
    let child = lite(pid: 171, parentPID: 170, userID: 501, processGroupID: 77)
    let locked = lite(pid: 172, parentPID: 170, userID: 0, processGroupID: 77)
    let neighbor = lite(pid: 173, parentPID: 1, userID: 501, processGroupID: 77)
    let arena = KillGraphArena(processes: [neighbor, locked, child, root], sampledAt: Date(timeIntervalSince1970: 1), pidReadCount: 4)
    let plan = KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity], protectedPIDs: [], displayName: "node")
    let slice = arena.slice(plan: plan, currentUserID: 501)

    try check(arena.process(for: child.identity)?.pid == 171, "arena should provide O(1)-style identity lookup")
    try check(slice.targetMembers.map(\.process.pid).sorted() == [170, 171], "owned-family slice should include root and owned descendants")
    try check(slice.lockedMembers.map(\.process.pid) == [172], "owned-family slice should keep foreign descendants locked")
    try check(slice.nearbyCandidates.map(\.identity.pid) == [173], "arena should surface process-group neighbors without targeting them")
    try check(arena.hasRecycledPID(for: ProcessIdentity(pid: 170, startTimeSeconds: 999, startTimeMicroseconds: 0)), "arena should detect PID reuse")
}

private func nativeKillSnapshotProviderReturnsArenaStats() async throws {
    let provider = NativeKillSnapshotProvider()
    let snapshot = try await provider.snapshot(policy: .preflight)

    try check(snapshot.arena != nil, "native kill snapshot should return an arena-backed graph")
    try check(snapshot.arena?.stats.processCount ?? 0 > 0, "arena stats should include process count")
    try check(snapshot.arena?.stats.pidReadCount == snapshot.graphReadCount, "arena stats should preserve PID read count")
}

private func killGraphArenaReusesIndexesAndSortsNeighbors() throws {
    let root = lite(pid: 175, parentPID: 1, userID: 501, processGroupID: 175)
    let child = lite(pid: 176, parentPID: 175, userID: 501, processGroupID: 175)
    let neighborA = lite(pid: 178, parentPID: 1, userID: 501, processGroupID: 175)
    let neighborB = lite(pid: 177, parentPID: 1, userID: 501, processGroupID: 175)
    let arena = KillGraphArena(
        processes: [neighborA, child, root, neighborB],
        sampledAt: Date(timeIntervalSince1970: 10),
        pidReadCount: 4
    )
    let patchedChild = child.updatingHeavyMetrics(
        residentMemoryBytes: 512,
        physicalFootprintBytes: 512,
        virtualMemoryBytes: 1_024,
        totalProcessorSeconds: 3,
        threadCount: 4,
        isSystemProcess: false
    )
    let patched = arena.replacingProcesses(
        [neighborA, patchedChild, root, neighborB],
        patchedHeavyMetricCount: 1
    )
    let neighbors = patched.processGroupNeighbors(rootIdentity: root.identity, currentUserID: 501, excluding: Set([root.identity, child.identity]))

    try check(patched.stats.arenaReuseCount == 1, "heavy metric patching should reuse arena indexes instead of rebuilding")
    try check(patched.stats.patchedHeavyMetricCount == 1, "arena stats should count patched target-heavy metrics")
    try check(patched.process(for: child.identity)?.didReadHeavyMetrics == true, "patched arena should serve the updated process rows")
    try check(neighbors.map(\.pid) == [177, 178], "process-group buckets should be pre-sorted by PID")
}

private func nativeKillSnapshotProviderSupportsTargetOnlyVerification() async throws {
    let provider = NativeKillSnapshotProvider()
    let initial = try await provider.snapshot(policy: .preflight)
    guard let current = initial.processes.first(where: { $0.pid == getpid() }) else {
        throw CheckFailure(message: "native kill graph did not include current process for target-only verification")
    }
    let request = KillSnapshotRequest(
        policy: .verify,
        rootIdentity: current.identity,
        targetIdentities: [current.identity],
        includeHeavyMetricsForTargets: false,
        requiresCompleteGraph: false,
        conversionBudget: .targetsOnly,
        verificationMode: .targetOnly
    )
    let snapshot = try await provider.snapshot(request: request)

    try check(snapshot.request?.verificationMode == .targetOnly, "target-only verification should preserve request mode")
    try check(snapshot.graphReadCount <= 1, "target-only verification should avoid a full PID graph sweep")
    try check(snapshot.heavyMetricReadCount == 0, "target-only verification should avoid heavy task/rusage reads")
    try check(snapshot.targetConversionCount <= 1, "target-only verification should convert only requested target rows")
}

private func nativeKillSnapshotProviderLimitsProcessMetricConversion() async throws {
    let provider = NativeKillSnapshotProvider()
    let initial = try await provider.snapshot(policy: .preflight)
    guard let current = initial.processes.first(where: { $0.pid == getpid() }) else {
        throw CheckFailure(message: "native kill graph did not include current process for conversion check")
    }

    let request = KillSnapshotRequest(
        policy: .preflight,
        rootIdentity: current.identity,
        targetIdentities: [current.identity],
        budget: KillSnapshotBudget(targetMilliseconds: 30, maxHeavyMetricReads: 1),
        conversionBudget: KillSnapshotConversionBudget(maxConvertedProcesses: 2)
    )
    let snapshot = try await provider.snapshot(request: request)

    try check(snapshot.graphReadCount >= snapshot.targetConversionCount, "native kill graph should not convert more processes than it reads")
    try check(snapshot.targetConversionCount <= 2, "native kill graph should honor the conversion budget")
    try check(snapshot.graphReadCount > snapshot.targetConversionCount, "planned kill snapshots should avoid full graph ProcessMetrics conversion")
}

private func processKillerSurfacesProcessGroupNeighbors() async throws {
    let root = lite(pid: 181, parentPID: 1, userID: 501, processGroupID: 900)
    let child = lite(pid: 182, parentPID: 181, userID: 501, processGroupID: 900)
    let neighbor = lite(pid: 183, parentPID: 1, userID: 501, processGroupID: 900)
    let snapshot = graphSnapshot([root, child, neighbor])
    let defaultProvider = ScriptedKillSnapshotProvider(snapshots: [snapshot])
    let killer = ProcessKiller(
        snapshotProvider: defaultProvider,
        signaler: FakeSignaler(),
        currentUserID: 501,
        sleeper: { _ in }
    )

    let defaultPreview = await killer.preview(
        plan: KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )

    try check(defaultPreview.targetPIDs == [182, 181], "owned family scope should target root and owned descendants only")
    try check(defaultPreview.scopePreview.nearbyCandidates.map(\.identity.pid) == [183], "same-process-group neighbor should be nearby, not targeted")

    let groupProvider = ScriptedKillSnapshotProvider(snapshots: [snapshot])
    let groupKiller = ProcessKiller(
        snapshotProvider: groupProvider,
        signaler: FakeSignaler(),
        currentUserID: 501,
        sleeper: { _ in }
    )
    let groupPreview = await groupKiller.preview(
        plan: KillPlan(
            rootIdentity: root.identity,
            targetIdentities: [root.identity],
            protectedPIDs: [],
            displayName: "generic",
            scope: .ownedProcessGroupPreview
        ),
        forceKillDelay: 0
    )

    try check(Set(groupPreview.targetPIDs) == Set([181, 182, 183]), "process group preview should explicitly include same-user process group neighbors")
}

private func interventionPolicyEngineSimulatesStrategies() throws {
    let engine = InterventionPolicyEngine()
    let target = KillTarget(process: lite(pid: 174, parentPID: 1, userID: 501, processGroupID: 174, name: "vite"), depth: 0, state: .ready, reason: "owned", rootIdentity: ProcessIdentity(pid: 174, startTimeSeconds: 1, startTimeMicroseconds: 0))
    let metadata = KillFamilyMetadata(
        signatureID: "node|vite",
        displayName: "Vite",
        scoreValue: 72,
        scoreLevel: .hot,
        forecastState: .warming,
        devKindLabel: "Node server",
        memoryBytes: 512 * 1_048_576,
        cpuPercent: 35,
        childCount: 0,
        isBackgroundOrOrphan: false
    )
    let plan = KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "vite", familyMetadata: metadata, workload: viteWorkload(pid: 174))
    let evaluation = engine.evaluate(
        plan: plan,
        targets: [target],
        locked: [],
        stale: [],
        recycled: [],
        reclaim: KillReclaimEstimate(memoryBytes: 512 * 1_048_576, cpuPercent: 35, confidence: 0.8, sourceText: "test"),
        diff: .empty,
        nearbyCount: 0,
        forceKillDelay: 2
    )

    try check(evaluation.recommendation.strategy == .gentleDevServer, "policy engine should recommend gentle dev-server strategy for Node/Vite")
    try check(evaluation.simulation.expectedGracefulSuccess > evaluation.simulation.survivorRisk, "strategy simulation should estimate higher graceful success than survivor risk")
    try check(evaluation.profile.phases.map(\.signalName).prefix(2) == ["SIGINT", "SIGTERM"], "policy profile should model SIGINT then SIGTERM")
}

private func interventionPolicyEngineAppliesCalibration() throws {
    let engine = InterventionPolicyEngine()
    let target = KillTarget(
        process: lite(pid: 179, parentPID: 1, userID: 501, processGroupID: 179, name: "node"),
        depth: 0,
        state: .ready,
        reason: "owned",
        rootIdentity: ProcessIdentity(pid: 179, startTimeSeconds: 1, startTimeMicroseconds: 0)
    )
    let calibration = KillCalibrationSnapshot(
        signatureID: "node|api",
        devKind: "nodeServer",
        strategy: .gentleDevServer,
        operationCount: 6,
        gracefulSuccessRate: 0.92,
        forceRate: 0.03,
        survivorRate: 0.01,
        averageGraceSeconds: 0.72,
        reclaimAccuracy: 0.9,
        denialPenalty: 0,
        updatedAt: Date(timeIntervalSince1970: 25)
    )
    let metadata = KillFamilyMetadata(
        signatureID: "node|api",
        displayName: "Node API",
        scoreValue: 70,
        scoreLevel: .hot,
        forecastState: .warming,
        devKindLabel: "Node server",
        memoryBytes: 300_000_000,
        cpuPercent: 20,
        childCount: 0,
        isBackgroundOrOrphan: false
    )
    let plan = KillPlan(
        rootIdentity: target.identity,
        targetIdentities: [target.identity],
        protectedPIDs: [],
        displayName: "node",
        familyMetadata: metadata,
        workload: viteWorkload(pid: 179),
        strategyCalibrations: [.gentleDevServer: calibration]
    )

    let evaluation = engine.evaluate(
        plan: plan,
        targets: [target],
        locked: [],
        stale: [],
        recycled: [],
        reclaim: KillReclaimEstimate(memoryBytes: 300_000_000, cpuPercent: 20, confidence: 0.8, sourceText: "test"),
        diff: .empty,
        nearbyCount: 0,
        forceKillDelay: 2
    )

    try check(evaluation.calibration.operationCount == 6, "policy evaluation should carry calibration input")
    try check(evaluation.simulation.expectedGracefulSuccess > 0.76, "local graceful history should raise calibrated graceful odds")
    try check(evaluation.profile.verificationSchedule.graceSeconds < 2, "calibrated grace should tune below the generic force delay")
    try check(evaluation.profile.summary.contains("calibrated"), "strategy profile should explain local grace calibration")
}

private func processKillerRecommendsGentleDevServerStrategy() async throws {
    let target = process(pid: 184, parentPID: 1, userID: 501)
    let metadata = KillFamilyMetadata(
        signatureID: "node|server",
        displayName: "Vite",
        scoreValue: 72,
        scoreLevel: .hot,
        forecastState: .warming,
        devKindLabel: "Node server",
        memoryBytes: 512 * 1_048_576,
        cpuPercent: 35,
        childCount: 0,
        isBackgroundOrOrphan: false
    )
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .preflight, usedCheapPath: true)
    ])
    let killer = ProcessKiller(snapshotProvider: provider, signaler: FakeSignaler(), currentUserID: 501, sleeper: { _ in })

    let preview = await killer.preview(
        plan: KillPlan(
            rootIdentity: target.identity,
            targetIdentities: [target.identity],
            protectedPIDs: [],
            displayName: "vite",
            familyMetadata: metadata,
            workload: viteWorkload(pid: 184)
        ),
        forceKillDelay: 0
    )

    try check(preview.strategyRecommendation.strategy == .gentleDevServer, "Node/Vite dev servers should recommend a gentle SIGINT-first strategy")
    try check(preview.forcePolicyText.contains("SIGINT"), "gentle preview should explain SIGINT-first behavior")
    try check(preview.strategyProfile.phases.map(\.signalName).prefix(2) == ["SIGINT", "SIGTERM"], "gentle strategy profile should model SIGINT then SIGTERM")
    try check(!preview.whyKillEvidence.isEmpty, "preview should expose weighted why-kill factors")
}

private func killHistoryChangesStrategyRecommendation() async throws {
    let target = process(pid: 187, parentPID: 1, userID: 501)
    let history = KillHistorySummary(
        signatureID: "generic-history",
        operationCount: 4,
        gracefulSuccessRate: 0.1,
        forceRate: 0.75,
        survivorRate: 0.1,
        averageReclaimBytes: 400_000_000,
        commonDenialCount: 0
    )
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .preflight, usedCheapPath: true)
    ])
    let killer = ProcessKiller(snapshotProvider: provider, signaler: FakeSignaler(), currentUserID: 501, sleeper: { _ in })

    let preview = await killer.preview(
        plan: KillPlan(
            rootIdentity: target.identity,
            targetIdentities: [target.identity],
            protectedPIDs: [],
            displayName: "generic",
            killHistory: history
        ),
        forceKillDelay: 0
    )

    try check(preview.strategyRecommendation.strategy == .stubbornRunaway, "force-heavy kill history should recommend stubborn runaway strategy")
    try check(preview.whyWaitEvidence.contains { $0.title == "Force history" }, "preview should explain history-driven caution")
}

private func processKillerReactorUsesAdaptiveVerification() async throws {
    let target = process(pid: 189, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true)
    ])
    let signaler = FakeSignaler(aliveAfterTerm: [189])
    let killer = ProcessKiller(snapshotProvider: provider, signaler: signaler, currentUserID: 501, sleeper: { _ in })

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )
    let requests = await provider.requests()

    try check(requests.first?.verificationMode == .completeArena, "confirm must use a complete arena")
    try check(requests.dropFirst().contains { $0.verificationMode == .targetOnly }, "quiet verification stages should use target-only mode")
    try check(report.reactorReport.verificationModeCounts[KillVerificationMode.targetOnly.rawValue, default: 0] >= 1, "reactor report should count target-only verification")
    try check(report.reactorReport.signalWaves.map(\.stage).contains("graceful"), "reactor report should include graceful signal waves")
}

private func killGraceCoordinatorEndsEarlyOnExitEvidence() async throws {
    let coordinator = KillGraceCoordinator()
    let calls = Counter()
    let result = await coordinator.wait(
        seconds: 1.0,
        sleeper: { _ in
            await calls.increment()
        },
        skipForceCheck: { false },
        shouldEndEarly: { true }
    )

    try check(result.endedEarly, "grace coordinator should finish as soon as exit evidence is present")
    try check(result.waitedSeconds < 0.2, "early grace completion should not wait the full delay")
    let sleepTicks = await calls.value
    try check(sleepTicks == 0, "early grace completion should avoid unnecessary sleep ticks")
}

private func killInterventionReactorRecordsHintsWavesAndModes() async throws {
    let operationID = KillOperationID(rawValue: "reactor")
    let reactor = KillInterventionReactor(operationID: operationID)
    let identity = ProcessIdentity(pid: 190, startTimeSeconds: 1, startTimeMicroseconds: 0)
    await reactor.beginPhase("signal")
    await reactor.recordHint(
        KillWatcherHint(
            operationID: operationID,
            pid: 190,
            identity: identity,
            kind: .fork,
            message: "fork"
        )
    )
    await reactor.recordWave(
        KillSignalWave(
            stage: "graceful",
            signalName: "SIGTERM",
            targetPIDs: [190],
            sentCount: 1,
            failedCount: 0
        )
    )
    await reactor.recordVerification(mode: .eventTriggeredComplete)
    await reactor.recordEarlyExitSavings(0.4)
    await reactor.recordArenaStats(
        KillGraphArenaStats(
            processCount: 1,
            pidReadCount: 1,
            arenaBuildMilliseconds: 0.1,
            adjacencyBuildMilliseconds: 0.1,
            identityIndexCount: 1,
            processGroupBucketCount: 1,
            arenaReuseCount: 1,
            patchedHeavyMetricCount: 1,
            presortedNeighborBucketCount: 1
        )
    )
    await reactor.recordCalibration(
        KillStrategySimulation(
            strategy: .standard,
            expectedGracefulSuccess: 0.7,
            forceProbability: 0.2,
            survivorRisk: 0.04,
            expectedDurationSeconds: 1,
            summary: "test"
        )
    )
    await reactor.endPhase("signal")
    let report = await reactor.report()

    try check(report.watcherHints.first?.kind == .fork, "reactor should retain watcher hints")
    try check(report.signalWaves.first?.signalName == "SIGTERM", "reactor should retain signal waves")
    try check(report.verificationModeCounts[KillVerificationMode.eventTriggeredComplete.rawValue] == 1, "reactor should count event-triggered verification")
    try check(report.earlyExitSavingsSeconds == 0.4, "reactor should accumulate early grace savings")
    try check(report.arenaReuseCount == 1, "reactor should aggregate arena reuse stats")
    try check(report.calibratedGracefulOdds == 0.7, "reactor should retain calibrated odds for diagnostics")
}

private func processKillerStreamsOperationEventsInOrder() async throws {
    let target = process(pid: 185, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [], policy: .verify, usedCheapPath: true)
    ])
    let capture = EventCapture()
    let killer = ProcessKiller(snapshotProvider: provider, signaler: FakeSignaler(), currentUserID: 501, sleeper: { _ in })

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0,
        eventSink: { event in
            capture.append(event)
        }
    )
    let kinds = capture.events.map(\.kind)

    try check(kinds.prefix(2) == [.queued, .preflight], "event stream should begin queued and preflight")
    try check(kinds.contains(.targetUpdated), "event stream should include target row updates")
    try check(kinds.contains(.signaled), "event stream should include signal events")
    try check(kinds.last == .completed, "event stream should finish with completed")
    try check(report.eventHistory.map(\.kind) == kinds, "report should preserve the streamed event history")
}

private func processKillerHonorsLiveSkipForceControl() async throws {
    let target = process(pid: 186, parentPID: 1, userID: 501)
    let provider = ScriptedKillSnapshotProvider(snapshots: [
        KillProcessSnapshot(processes: [target], policy: .confirm, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .verify, usedCheapPath: true),
        KillProcessSnapshot(processes: [target], policy: .verify, usedCheapPath: true)
    ])
    let control = KillOperationControl()
    let signaler = FakeSignaler(aliveAfterTerm: [186])
    let killer = ProcessKiller(
        snapshotProvider: provider,
        signaler: signaler,
        currentUserID: 501,
        sleeper: { _ in
            await control.requestSkipForce()
        }
    )

    let report = await killer.kill(
        plan: KillPlan(rootIdentity: target.identity, targetIdentities: [target.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0.1,
        skipForceCheck: {
            await control.shouldSkipForce()
        }
    )

    try check(report.skipForceRequested, "live skip-force control should be checked during grace")
    try check(report.forcedPIDs.isEmpty, "live skip-force control should prevent SIGKILL")
    try check(signaler.sent == [Signal(pid: 186, signal: SIGTERM)], "live skip-force should send only the graceful signal")
}

private func killOperationStateMachineRecordsExitEvents() async throws {
    let operationID = KillOperationID(rawValue: "state-machine")
    let machine = KillOperationStateMachine(operationID: operationID)
    let identity = ProcessIdentity(pid: 188, startTimeSeconds: 1, startTimeMicroseconds: 0)
    let exit = KillExitEvent(
        operationID: operationID,
        pid: 188,
        identity: identity,
        kind: .exit,
        message: "Exit observed for node."
    )
    let update = await machine.recordExit(exit)
    let events = await machine.exitEventSnapshot()
    let states = await machine.targetStates()

    try check(update.pid == 188 && update.targetState == .terminated, "state machine should convert exit watcher events into target updates")
    try check(events == [exit], "state machine should retain watcher events for the final report")
    try check(states[188] == .terminated, "state machine should expose the latest target row state")
}

private func fakeKillPreviewBenchmarksStayBounded() async throws {
    try await syntheticKillPreviewBenchmark(processCount: 2_000, maxMilliseconds: 350)
    try await syntheticKillPreviewBenchmark(processCount: 10_000, maxMilliseconds: 1_600)
    try await syntheticKillPreviewBenchmark(processCount: 30_000, maxMilliseconds: 5_500)
}

private func syntheticKillPreviewBenchmark(processCount: Int, maxMilliseconds: Double) async throws {
    let root = lite(pid: 10_000, parentPID: 1, userID: 501, processGroupID: 10_000)
    let child = lite(pid: 10_001, parentPID: root.pid, userID: 501, processGroupID: 10_000)
    var processes = [root, child]
    if processCount > 2 {
        processes += (2..<processCount).map { offset in
            lite(
                pid: Int32(10_000 + offset),
                parentPID: 1,
                userID: offset.isMultiple(of: 7) ? 501 : 502,
                processGroupID: Int32(20_000 + offset),
                memory: 0
            )
        }
    }
    let provider = ScriptedKillSnapshotProvider(snapshots: [graphSnapshot(processes)])
    let killer = ProcessKiller(snapshotProvider: provider, signaler: FakeSignaler(), currentUserID: 501, sleeper: { _ in })
    let started = Date()
    let preview = await killer.preview(
        plan: KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity], protectedPIDs: [], displayName: "generic"),
        forceKillDelay: 0
    )
    let elapsed = Date().timeIntervalSince(started) * 1_000

    try check(elapsed < maxMilliseconds, "\(processCount)-process kill preview should stay under debug budget, got \(Int(elapsed))ms")
    try check(preview.targetPIDs == [10_001, 10_000], "synthetic preview should still target only the owned family")
    try check(preview.targetConversionCount == 0, "synthetic graph preview should not require full ProcessMetrics conversion")
}

private func radarStoreRecordsKillActions() async throws {
    let store = try RadarStore(url: temporaryStoreURL())
    let family = hotFamily(pid: 95, memory: 700_000_000, cpu: 75)
    let report = KillReport(displayName: "node", rootPID: 95, gracefulPIDs: [95])

    try await store.recordAction(kind: .kill, family: family, summary: report.diagnosticText, at: Date(timeIntervalSince1970: 20))
    try await store.flush(now: Date(timeIntervalSince1970: 20))
    let summaries = try await store.actionSummaries(kind: .kill)

    try check(summaries.first?.contains("Ghost Process Sniper Kill Report") == true, "store should persist actual kill actions")
}

private func radarStoreRecordsStructuredKillOperations() async throws {
    let store = try RadarStore(url: temporaryStoreURL())
    let family = hotFamily(pid: 97, memory: 700_000_000, cpu: 75)
    let report = KillReport(
        displayName: "node",
        rootPID: 97,
        gracefulPIDs: [97],
        timeline: KillExecutionTimeline(preflightMilliseconds: 1, signalMilliseconds: 2, verificationMilliseconds: 3, totalMilliseconds: 6),
        estimatedMemoryReclaimBytes: 700_000_000,
        realizedMemoryReclaimBytes: 700_000_000
    )

    try await store.recordKillOperation(report: report, family: family, at: Date(timeIntervalSince1970: 21))
    let records = try await store.recentKillOperations()
    let health = await store.storeHealth()

    try check(records.first?.rootPID == 97, "store should persist structured kill operations")
    try check(records.first?.realizedMemoryReclaimBytes == 700_000_000, "structured kill record should include reclaim")
    try check(health.lastKillOperationSummary?.contains("node") == true, "store health should surface last kill summary")
}

private func radarStoreRecordsKillEventsAndLearning() async throws {
    let store = try RadarStore(url: temporaryStoreURL())
    let family = hotFamily(pid: 98, memory: 900_000_000, cpu: 88)
    let operationID = KillOperationID(rawValue: "op-events")
    let report = KillReport(
        operationID: operationID,
        displayName: "node",
        rootPID: 98,
        gracefulPIDs: [98],
        forcedPIDs: [98],
        deniedPIDs: [199],
        survivorPIDs: [198],
        timeline: KillExecutionTimeline(preflightMilliseconds: 1, signalMilliseconds: 2, verificationMilliseconds: 3, totalMilliseconds: 6),
        realizedMemoryReclaimBytes: 900_000_000,
        eventHistory: [
            KillOperationEvent(operationID: operationID, kind: .queued, message: "queued"),
            KillOperationEvent(operationID: operationID, kind: .signaled, pid: 98, signalName: "SIGTERM", targetState: .terminated, message: "term sent"),
            KillOperationEvent(operationID: operationID, kind: .completed, message: "done")
        ],
        strategyUsed: .stubbornRunaway,
        scopeUsed: .ownedFamily
    )

    try await store.recordKillOperation(report: report, family: family, at: Date(timeIntervalSince1970: 22))
    let events = try await store.recentKillEvents(operationID: operationID)
    let history = try await store.killHistorySummary(signatureID: family.signature.id)
    let strategyHistory = try await store.killStrategyHistory(
        signatureID: family.signature.id,
        devKind: family.classification?.kind.rawValue
    )
    let diagnostics = try await store.exportKillDiagnostics()

    try check(events.map(\.kind) == [.queued, .signaled, .completed], "store should persist kill operation event history")
    try check(events[1].pid == 98 && events[1].targetState == .terminated, "stored kill events should preserve PID and target state")
    try check(history.operationCount == 1, "store should persist kill outcome learning rows")
    try check(history.forceRate == 1, "kill history should learn force rate")
    try check(history.survivorRate == 1, "kill history should learn survivor rate")
    try check(history.commonDenialCount == 1, "kill history should learn denial counts")
    try check(strategyHistory.operationCount == 1 && strategyHistory.forceRate == 1, "strategy history should query by signature/dev kind")
    try check(diagnostics.contains("Ghost Process Sniper Kill Diagnostics"), "store should export compact kill diagnostics")
}

private func radarStoreRecordsInterventionKernelTables() async throws {
    let store = try RadarStore(url: temporaryStoreURL())
    let family = hotFamily(pid: 99, memory: 800_000_000, cpu: 80)
    let operationID = KillOperationID(rawValue: "kernel-tables")
    let report = KillReport(
        operationID: operationID,
        displayName: "node",
        rootPID: 99,
        gracefulPIDs: [99],
        attempts: [
            KillAttempt(pid: 99, signal: SIGTERM, stage: "graceful", succeeded: true)
        ],
        timeline: KillExecutionTimeline(preflightMilliseconds: 1, signalMilliseconds: 2, verificationMilliseconds: 3, totalMilliseconds: 6),
        estimatedMemoryReclaimBytes: 800_000_000,
        realizedMemoryReclaimBytes: 780_000_000,
        finalGraphDelta: KillGraphDelta(
            previewTargetPIDs: [99],
            confirmTargetPIDs: [99],
            finalSurvivorPIDs: [],
            drift: .empty
        ),
        watcherEvents: [
            KillExitEvent(
                operationID: operationID,
                pid: 99,
                identity: ProcessIdentity(pid: 99, startTimeSeconds: 1, startTimeMicroseconds: 0),
                kind: .exit,
                message: "Exit observed for node.",
                observedAt: Date(timeIntervalSince1970: 23)
            )
        ],
        calibratedReclaimBytes: 780_000_000
    )

    try await store.recordKillOperation(report: report, family: family, at: Date(timeIntervalSince1970: 23))
    let signalCount = try await store.killSignalOutcomeCount(operationID: operationID)
    let deltaCount = try await store.killGraphDeltaCount(operationID: operationID)
    let exitCount = try await store.killExitEventCount(operationID: operationID)

    try check(signalCount == 1, "store should persist per-signal intervention outcomes")
    try check(deltaCount == 1, "store should persist graph delta intervention records")
    try check(exitCount == 1, "store should persist operation-local exit watcher events")
}

private func radarStoreRecordsKillCalibrationAggregates() async throws {
    let store = try RadarStore(url: temporaryStoreURL())
    let family = hotFamily(pid: 100, memory: 500_000_000, cpu: 50)
    let first = KillReport(
        operationID: KillOperationID(rawValue: "calibration-1"),
        displayName: "node",
        rootPID: 100,
        gracefulPIDs: [100],
        timeline: KillExecutionTimeline(preflightMilliseconds: 1, signalMilliseconds: 400, verificationMilliseconds: 2, totalMilliseconds: 403),
        estimatedMemoryReclaimBytes: 500_000_000,
        realizedMemoryReclaimBytes: 450_000_000,
        strategyUsed: .gentleDevServer
    )
    let second = KillReport(
        operationID: KillOperationID(rawValue: "calibration-2"),
        displayName: "node",
        rootPID: 100,
        gracefulPIDs: [100],
        forcedPIDs: [100],
        survivorPIDs: [100],
        timeline: KillExecutionTimeline(preflightMilliseconds: 1, signalMilliseconds: 800, verificationMilliseconds: 2, totalMilliseconds: 803),
        estimatedMemoryReclaimBytes: 500_000_000,
        realizedMemoryReclaimBytes: 100_000_000,
        strategyUsed: .gentleDevServer
    )

    try await store.recordKillOperation(report: first, family: family, at: Date(timeIntervalSince1970: 24))
    try await store.recordKillOperation(report: second, family: family, at: Date(timeIntervalSince1970: 25))
    let calibration = try await store.killCalibrationSnapshot(
        signatureID: family.signature.id,
        devKind: family.classification?.kind.rawValue,
        strategy: .gentleDevServer
    )

    try check(calibration.operationCount == 2, "store should update compact calibration aggregates additively")
    try check(calibration.forceRate > 0 && calibration.survivorRate > 0, "calibration aggregate should learn force and survivor rates")
    try check(calibration.averageGraceSeconds > 0, "calibration aggregate should learn observed grace timing")
    try check(calibration.reclaimAccuracy < 1, "calibration aggregate should track reclaim accuracy")
}

private struct CheckFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw CheckFailure(message: message)
    }
}

private struct FakeSampler: ProcessSampling {
    var samples: [ProcessMetrics]

    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        ProcessSampleBatch(
            processes: samples,
            sampledAt: plan.sampledAt,
            stats: SamplerStats(
                processCount: samples.count,
                commandRefreshCount: samples.count,
                commandCacheHitCount: 0,
                forensicsRefreshCount: plan.includeForensicsFor.count,
                forensicsDeferredCount: max(0, samples.count - plan.includeForensicsFor.count),
                elapsedMilliseconds: 0
            )
        )
    }
}

private actor PlanCaptureSampler: ProcessSampling {
    private let samples: [ProcessMetrics]
    private var capturedPlans: [SamplingPlan] = []

    init(samples: [ProcessMetrics]) {
        self.samples = samples
    }

    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        capturedPlans.append(plan)
        return ProcessSampleBatch(
            processes: samples,
            sampledAt: plan.sampledAt,
            stats: SamplerStats(
                processCount: samples.count,
                commandRefreshCount: 0,
                commandCacheHitCount: samples.count,
                forensicsRefreshCount: 0,
                forensicsDeferredCount: samples.count,
                elapsedMilliseconds: 0,
                expensiveCallCount: 0
            )
        )
    }

    func plans() -> [SamplingPlan] {
        capturedPlans
    }
}

private struct FakeLookup: ProcessLookup {
    var samples: [ProcessMetrics]

    func processes() async throws -> [ProcessMetrics] {
        samples
    }

    func killSnapshot(policy: KillSnapshotPolicy) async throws -> KillProcessSnapshot {
        KillProcessSnapshot(
            processes: samples,
            policy: policy,
            usedCheapPath: true,
            expensiveCallCount: 0
        )
    }
}

private actor ScriptedKillLookup: ProcessLookup {
    private var snapshots: [KillProcessSnapshot]
    private var seenPolicies: [KillSnapshotPolicy] = []

    init(snapshots: [KillProcessSnapshot]) {
        self.snapshots = snapshots
    }

    func processes() async throws -> [ProcessMetrics] {
        if snapshots.isEmpty {
            return []
        }
        return snapshots[0].processes
    }

    func killSnapshot(policy: KillSnapshotPolicy) async throws -> KillProcessSnapshot {
        seenPolicies.append(policy)
        guard !snapshots.isEmpty else {
            return KillProcessSnapshot(processes: [], policy: policy, usedCheapPath: true)
        }
        if snapshots.count == 1 {
            let snapshot = snapshots[0]
            return KillProcessSnapshot(
                processes: snapshot.processes,
                policy: policy,
                usedCheapPath: snapshot.usedCheapPath,
                expensiveCallCount: snapshot.expensiveCallCount
            )
        }
        let snapshot = snapshots.removeFirst()
        return KillProcessSnapshot(
            processes: snapshot.processes,
            policy: policy,
            usedCheapPath: snapshot.usedCheapPath,
            expensiveCallCount: snapshot.expensiveCallCount
        )
    }

    func policies() -> [KillSnapshotPolicy] {
        seenPolicies
    }
}

private actor ScriptedKillSnapshotProvider: KillSnapshotProviding {
    private var snapshots: [KillProcessSnapshot]
    private var seenPolicies: [KillSnapshotPolicy] = []
    private var seenRequests: [KillSnapshotRequest] = []

    init(snapshots: [KillProcessSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(request: KillSnapshotRequest) async throws -> KillProcessSnapshot {
        seenPolicies.append(request.policy)
        seenRequests.append(request)
        guard !snapshots.isEmpty else {
            return KillProcessSnapshot(processes: [], policy: request.policy, usedCheapPath: true, request: request)
        }
        if snapshots.count == 1 {
            let snapshot = snapshots[0]
            return KillProcessSnapshot(
                processes: snapshot.processes,
                policy: request.policy,
                usedCheapPath: snapshot.usedCheapPath,
                expensiveCallCount: snapshot.expensiveCallCount,
                request: request,
                graph: snapshot.graph,
                arena: snapshot.arena,
                graphReadCount: snapshot.graphReadCount,
                heavyMetricReadCount: snapshot.heavyMetricReadCount,
                didHitBudget: snapshot.didHitBudget,
                targetConversionCount: snapshot.targetConversionCount,
                skippedOptionalWorkCount: snapshot.skippedOptionalWorkCount
            )
        }
        let snapshot = snapshots.removeFirst()
        return KillProcessSnapshot(
            processes: snapshot.processes,
            policy: request.policy,
            usedCheapPath: snapshot.usedCheapPath,
            expensiveCallCount: snapshot.expensiveCallCount,
            request: request,
            graph: snapshot.graph,
            arena: snapshot.arena,
            graphReadCount: snapshot.graphReadCount,
            heavyMetricReadCount: snapshot.heavyMetricReadCount,
            didHitBudget: snapshot.didHitBudget,
            targetConversionCount: snapshot.targetConversionCount,
            skippedOptionalWorkCount: snapshot.skippedOptionalWorkCount
        )
    }

    func policies() -> [KillSnapshotPolicy] {
        seenPolicies
    }

    func requests() -> [KillSnapshotRequest] {
        seenRequests
    }
}

private struct Signal: Equatable {
    var pid: Int32
    var signal: Int32
}

private final class EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KillOperationEvent] = []

    var events: [KillOperationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: KillOperationEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class FakeSignaler: ProcessSignaling, @unchecked Sendable {
    private let aliveAfterTerm: Set<Int32>
    private(set) var sent: [Signal] = []

    init(aliveAfterTerm: Set<Int32> = []) {
        self.aliveAfterTerm = aliveAfterTerm
    }

    func send(signal: Int32, to pid: Int32) throws {
        sent.append(Signal(pid: pid, signal: signal))
    }

    func exists(pid: Int32) -> Bool {
        aliveAfterTerm.contains(pid)
    }
}

private final class FailingSignaler: ProcessSignaling, @unchecked Sendable {
    private let errnoCode: Int32

    init(errnoCode: Int32) {
        self.errnoCode = errnoCode
    }

    func send(signal: Int32, to pid: Int32) throws {
        throw SignalFailure(pid: pid, signal: signal, errnoCode: errnoCode, message: "simulated")
    }

    func exists(pid: Int32) -> Bool {
        false
    }
}

private func process(pid: Int32, parentPID: Int32, userID: UInt32, start: UInt64 = 1) -> ProcessMetrics {
    sample(
        pid: pid,
        parentPID: parentPID,
        userID: userID,
        start: start,
        name: "node",
        executablePath: "/usr/local/bin/node",
        commandLine: "node server.js",
        memory: 128,
        cpu: 0
    )
}

/// What the risk assessor needs to recognize a dev server: its real argv.
private func viteWorkload(pid: Int32) -> KillWorkloadProfile {
    KillWorkloadProfile(
        processes: [KillWorkloadProcess(pid: pid, parentPID: 1, name: "node", executablePath: "/usr/local/bin/node",
                                        commandLine: "node /app/node_modules/.bin/vite --port 5173", isRoot: true)],
        ancestors: [],
        parentIsLaunchd: true
    )
}

private func lite(
    pid: Int32,
    parentPID: Int32,
    userID: UInt32,
    start: UInt64 = 1,
    processGroupID: Int32,
    name: String = "node",
    memory: UInt64 = 128 * 1_048_576,
    cpu: Double = 0
) -> KillProcessLite {
    KillProcessLite(
        identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
        parentPID: parentPID,
        userID: userID,
        ownerName: userID == 501 ? "dev" : "root",
        name: name,
        status: 0,
        flags: 0,
        processGroupID: processGroupID,
        openFileCount: 4,
        residentMemoryBytes: memory,
        physicalFootprintBytes: memory,
        cpuPercent: cpu,
        didReadHeavyMetrics: false
    )
}

private func graphSnapshot(_ processes: [KillProcessLite]) -> KillProcessSnapshot {
    let graph = KillProcessGraph(
        processes: processes,
        sampledAt: Date(timeIntervalSince1970: 1),
        elapsedMilliseconds: 0.2,
        graphReadCount: processes.count,
        heavyMetricReadCount: 0,
        didHitBudget: false,
        usedBSDInfoPath: true
    )
    return KillProcessSnapshot(
        processes: [],
        sampledAt: graph.sampledAt,
        policy: .preflight,
        elapsedMilliseconds: graph.elapsedMilliseconds,
        usedCheapPath: true,
        expensiveCallCount: 0,
        graph: graph,
        arena: KillGraphArena(processes: processes, sampledAt: graph.sampledAt, pidReadCount: processes.count),
        graphReadCount: graph.graphReadCount,
        heavyMetricReadCount: graph.heavyMetricReadCount,
        didHitBudget: graph.didHitBudget,
        targetConversionCount: 0,
        skippedOptionalWorkCount: processes.count
    )
}

private func forecastFamily(
    pid: Int32,
    parentPID: Int32 = 1,
    start: UInt64 = 1_000,
    memory: UInt64,
    cpu: Double,
    trend: TrendMetrics,
    score: GhostScore,
    baseline: FamilyBaseline? = nil,
    recentIncidentCount: Int = 0
) -> ProcessFamily {
    let root = sample(
        pid: pid,
        parentPID: parentPID,
        start: start,
        name: "node",
        executablePath: "/usr/local/bin/node",
        commandLine: "node server.js",
        memory: memory,
        cpu: cpu
    )
    return ProcessFamily(
        root: root,
        members: [root],
        totalResidentMemoryBytes: memory,
        totalPhysicalFootprintBytes: memory,
        totalCPUPercent: cpu,
        devConfidence: 0.9,
        commandHints: ["server.js"],
        trend: trend,
        score: score,
        ownedIdentities: [root.identity],
        protectedPIDs: [],
        baseline: baseline,
        recentIncidentCount: recentIncidentCount
    )
}

private func hotFamily(
    pid: Int32,
    memory: UInt64,
    cpu: Double,
    score: GhostScore = GhostScore(value: 88, level: .critical, reasons: ["memory above threshold", "CPU above threshold"])
) -> ProcessFamily {
    let root = sample(
        pid: pid,
        name: "node",
        executablePath: "/usr/local/bin/node",
        commandLine: "node server.js",
        memory: memory,
        cpu: cpu
    )
    return ProcessFamily(
        root: root,
        members: [root],
        totalResidentMemoryBytes: memory,
        totalPhysicalFootprintBytes: memory,
        totalCPUPercent: cpu,
        devConfidence: 0.9,
        commandHints: ["server.js"],
        trend: TrendMetrics(
            memoryVelocityMegabytesPerMinute: 160,
            cpuSlopePerMinute: 10,
            memoryPoints: [Double(memory / 2), Double(memory)]
        ),
        score: score,
        ownedIdentities: [root.identity],
        protectedPIDs: []
    )
}

private func consoleSnapshot(_ families: [ProcessFamily]) -> RadarConsoleSnapshot {
    RadarConsoleSnapshot.build(
        families: families,
        summary: ProcessFamilyBuilder(currentUserID: 501).summary(for: families),
        incidents: [],
        rules: [],
        metrics: .empty,
        health: .starting,
        storeHealth: .empty,
        storeError: nil,
        previous: nil,
        generatedAt: Date(timeIntervalSince1970: 1)
    )
}

private func derivedKey(_ snapshot: RadarConsoleSnapshot, _ state: RadarConsoleState) -> ConsoleDerivedSnapshotKey {
    ConsoleDerivedSnapshotKey(ConsoleProjectionRequest(source: snapshot, incidents: [], state: state))
}

private func temporaryStoreURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("GhostProcessSniper-\(UUID().uuidString).sqlite")
}

private func syntheticProcesses(count: Int, sampledAt: Date = Date(timeIntervalSince1970: 1_000)) -> [ProcessMetrics] {
    (0..<count).map { index in
        let isDev = index % 7 == 0
        let name = isDev ? "node" : "worker-\(index)"
        let parent: Int32 = index % 5 == 0 ? 1 : Int32(max(1, 10_000 + index - 1))
        return sample(
            pid: Int32(10_000 + index),
            parentPID: parent,
            start: UInt64(1_000 + index),
            name: name,
            executablePath: isDev ? "/usr/local/bin/node" : "/usr/bin/true",
            commandLine: isDev ? "node server-\(index).js" : "worker-\(index)",
            memory: UInt64(12_000_000 + (index % 97) * 1_000_000),
            cpu: Double(index % 40),
            sampledAt: sampledAt
        )
    }
}

private func sample(
    pid: Int32 = 100,
    parentPID: Int32 = 1,
    userID: UInt32 = 501,
    start: UInt64 = 1,
    name: String,
    executablePath: String? = nil,
    commandLine: String? = nil,
    memory: UInt64 = 64,
    cpu: Double = 0,
    gpu: Double = 0,
    sampledAt: Date = Date(timeIntervalSince1970: 1_000)
) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
        parentPID: parentPID,
        userID: userID,
        ownerName: userID == 501 ? "user" : "root",
        name: name,
        executablePath: executablePath ?? "/usr/local/bin/\(name)",
        commandLine: commandLine ?? name,
        residentMemoryBytes: memory,
        physicalFootprintBytes: memory,
        virtualMemoryBytes: memory * 2,
        cpuPercent: cpu,
        gpuUsagePercent: gpu,
        totalProcessorSeconds: 0,
        threadCount: 1,
        isSystemProcess: userID == 0,
        sampledAt: sampledAt
    )
}

// Forecast-only fixtures explicitly represent measurements at the test clock.
// Production stale/missing-sample rejection is tested in PrecisionTelemetryTests.
private func forecastWithFreshMeasurements(family: ProcessFamily, settings: ThresholdSettings, now: Date) -> RiskForecast {
    FamilyRiskForecaster().forecast(family: freshMeasurements(family, at: now), settings: settings, now: now)
}

private func freshMeasurements(_ family: ProcessFamily, at date: Date) -> ProcessFamily {
    func measured(_ process: ProcessMetrics) -> ProcessMetrics {
        ProcessMetrics(identity: process.identity, parentPID: process.parentPID, userID: process.userID,
            ownerName: process.ownerName, name: process.name, executablePath: process.executablePath,
            commandLine: process.commandLine, residentMemoryBytes: process.residentMemoryBytes,
            physicalFootprintBytes: process.physicalFootprintBytes, virtualMemoryBytes: process.virtualMemoryBytes,
            cpuPercent: process.cpuPercent, gpuUsagePercent: process.gpuUsagePercent,
            totalProcessorSeconds: process.totalProcessorSeconds, threadCount: process.threadCount,
            isSystemProcess: process.isSystemProcess, sampledAt: date, forensics: process.forensics)
    }
    return ProcessFamily(root: measured(family.root), members: family.members.map(measured),
        totalResidentMemoryBytes: family.totalResidentMemoryBytes,
        totalPhysicalFootprintBytes: family.totalPhysicalFootprintBytes, totalCPUPercent: family.totalCPUPercent,
        totalGPUPercent: family.totalGPUPercent, devConfidence: family.devConfidence,
        commandHints: family.commandHints, trend: family.trend, score: family.score,
        ownedIdentities: family.ownedIdentities, protectedPIDs: family.protectedPIDs,
        signature: family.signature, baseline: family.baseline, forensics: family.forensics,
        suggestions: family.suggestions, alertState: family.alertState,
        recentIncidentCount: family.recentIncidentCount, forecast: family.forecast,
        lastScoredAt: date, classification: family.classification, duplicateCluster: family.duplicateCluster,
        hardwareSignals: family.hardwareSignals)
}
