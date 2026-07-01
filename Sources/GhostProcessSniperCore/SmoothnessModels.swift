import Foundation

public struct SnapshotContentRevision: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public static let zero = SnapshotContentRevision(rawValue: 0)

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func compute(
        families: [ProcessFamily],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        duplicateClusters: [DuplicateProcessCluster] = []
    ) -> SnapshotContentRevision {
        var hasher = Hasher()
        hasher.combine(summary.statusText)
        hasher.combine(summary.level)
        hasher.combine(summary.familyCount)
        hasher.combine(summary.hotCount)
        hasher.combine(summary.leakingCount)
        hasher.combine(summary.suggestionCount)
        for family in families {
            hasher.combine(family.familyKey)
            hasher.combine(family.signatureVersion)
            hasher.combine(family.childCount)
            hasher.combine(family.isKillable)
            hasher.combine(metricBucket(for: family.totalPhysicalFootprintBytes, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(percentBucket(for: family.totalCPUPercent, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(percentBucket(for: family.totalGPUPercent, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(leakBucket(for: family.trend.memoryVelocityMegabytesPerMinute, level: family.score.level, forecast: family.forecast.state))
            hasher.combine(family.score.level)
            hasher.combine(Int(family.score.value.rounded()))
            hasher.combine(family.hardwareSignals.map(\.reason))
            hasher.combine(family.forecast.state)
            hasher.combine(Int((family.forecast.confidence * 100).rounded()))
            hasher.combine(family.alertState.kind)
            hasher.combine(family.suggestions.count)
            hasher.combine(family.protectedPIDs)
        }
        for incident in incidents {
            hasher.combine(incident.id)
            hasher.combine(incident.level)
            hasher.combine(incident.resolvedAt)
            hasher.combine(incident.occurrenceCount)
            hasher.combine(Int(incident.maxScore.rounded()))
        }
        for rule in rules {
            hasher.combine(rule.id)
            hasher.combine(rule.isEnabled)
            hasher.combine(rule.action.rawValue)
            hasher.combine(rule.expiresAt)
        }
        for cluster in duplicateClusters where !cluster.isInternalToSingleFamily {
            hasher.combine(cluster.id)
            hasher.combine(cluster.memberCount)
            hasher.combine(cluster.independentRootCount)
            hasher.combine(metricBucket(for: cluster.totalPhysicalFootprintBytes, level: .watch, forecast: .quiet))
            hasher.combine(percentBucket(for: cluster.totalCPUPercent, level: .watch, forecast: .quiet))
            hasher.combine(cluster.representativePIDs)
            hasher.combine(cluster.relatedFamilyKeys)
        }
        return SnapshotContentRevision(rawValue: UInt64(bitPattern: Int64(hasher.finalize())))
    }

    private static func metricBucket(for bytes: UInt64, level: GhostLevel, forecast: ForecastState) -> UInt64 {
        let hot = level >= .hot || forecast >= .leaking
        let bucketSize: UInt64 = hot ? 4 * 1_048_576 : 32 * 1_048_576
        return bytes / bucketSize
    }

    private static func percentBucket(for percent: Double, level: GhostLevel, forecast: ForecastState) -> Int {
        let hot = level >= .hot || forecast >= .leaking
        let bucketSize = hot ? 1.0 : 5.0
        return Int((percent / bucketSize).rounded(.down))
    }

    private static func leakBucket(for megabytesPerMinute: Double, level: GhostLevel, forecast: ForecastState) -> Int {
        let hot = level >= .hot || forecast >= .leaking
        let bucketSize = hot ? 5.0 : 20.0
        return Int((megabytesPerMinute / bucketSize).rounded(.down))
    }
}

public struct RefreshPhaseTrace: Equatable, Sendable {
    public let sampleMilliseconds: Double
    public let buildMilliseconds: Double
    public let scoreMilliseconds: Double
    public let storeMilliseconds: Double
    public let publishMilliseconds: Double
    public let totalMilliseconds: Double

    public static let empty = RefreshPhaseTrace(
        sampleMilliseconds: 0,
        buildMilliseconds: 0,
        scoreMilliseconds: 0,
        storeMilliseconds: 0,
        publishMilliseconds: 0,
        totalMilliseconds: 0
    )

    public init(
        sampleMilliseconds: Double,
        buildMilliseconds: Double,
        scoreMilliseconds: Double,
        storeMilliseconds: Double,
        publishMilliseconds: Double,
        totalMilliseconds: Double
    ) {
        self.sampleMilliseconds = sampleMilliseconds
        self.buildMilliseconds = buildMilliseconds
        self.scoreMilliseconds = scoreMilliseconds
        self.storeMilliseconds = storeMilliseconds
        self.publishMilliseconds = publishMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }

    public init(stats: RefreshStats) {
        self.init(
            sampleMilliseconds: stats.sampleMilliseconds,
            buildMilliseconds: stats.buildMilliseconds,
            scoreMilliseconds: stats.scoreMilliseconds,
            storeMilliseconds: stats.storeMilliseconds,
            publishMilliseconds: stats.publishMilliseconds,
            totalMilliseconds: stats.totalMilliseconds
        )
    }

    public var slowestPhase: (name: String, milliseconds: Double) {
        [
            ("sample", sampleMilliseconds),
            ("build", buildMilliseconds),
            ("score", scoreMilliseconds),
            ("store", storeMilliseconds),
            ("publish", publishMilliseconds)
        ].max { $0.1 < $1.1 } ?? ("unknown", totalMilliseconds)
    }
}

public struct RadarSmoothnessReport: Equatable, Sendable {
    public let hitchCount: Int
    public let worstHitchMilliseconds: Double
    public let latestSpikePhase: String
    public let recentSpikes: [String]

    public static let empty = RadarSmoothnessReport(
        hitchCount: 0,
        worstHitchMilliseconds: 0,
        latestSpikePhase: "none",
        recentSpikes: []
    )

    public init(
        hitchCount: Int,
        worstHitchMilliseconds: Double,
        latestSpikePhase: String,
        recentSpikes: [String]
    ) {
        self.hitchCount = hitchCount
        self.worstHitchMilliseconds = worstHitchMilliseconds
        self.latestSpikePhase = latestSpikePhase
        self.recentSpikes = recentSpikes
    }

    public func merging(_ other: RadarSmoothnessReport) -> RadarSmoothnessReport {
        RadarSmoothnessReport(
            hitchCount: hitchCount + other.hitchCount,
            worstHitchMilliseconds: max(worstHitchMilliseconds, other.worstHitchMilliseconds),
            latestSpikePhase: other.latestSpikePhase == "none" ? latestSpikePhase : other.latestSpikePhase,
            recentSpikes: Array((recentSpikes + other.recentSpikes).suffix(8))
        )
    }
}

public struct SpikeRingBuffer: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let date: Date
        public let phase: String
        public let milliseconds: Double

        public init(date: Date, phase: String, milliseconds: Double) {
            self.date = date
            self.phase = phase
            self.milliseconds = milliseconds
        }
    }

    private let limit: Int
    private var entries: [Entry]

    public init(limit: Int = 8) {
        self.limit = max(1, limit)
        self.entries = []
    }

    public mutating func record(
        phase: String,
        milliseconds: Double,
        threshold: Double,
        at date: Date = Date(),
        logToOS: Bool = true
    ) {
        guard milliseconds >= threshold else {
            return
        }
        entries.append(Entry(date: date, phase: phase, milliseconds: milliseconds))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        if logToOS {
            RadarLogger.performance.notice("Smoothness spike \(phase, privacy: .public) \(milliseconds, privacy: .public)ms")
        }
    }

    public mutating func record(trace: RefreshPhaseTrace, threshold: Double, at date: Date = Date()) {
        let phase = trace.slowestPhase
        record(phase: phase.name, milliseconds: phase.milliseconds, threshold: threshold, at: date)
    }

    public var report: RadarSmoothnessReport {
        let worst = entries.map(\.milliseconds).max() ?? 0
        let latest = entries.last?.phase ?? "none"
        let lines = entries.map { entry in
            "\(entry.phase) \(Int(entry.milliseconds.rounded()))ms at \(entry.date.formatted(date: .omitted, time: .standard))"
        }
        return RadarSmoothnessReport(
            hitchCount: entries.count,
            worstHitchMilliseconds: worst,
            latestSpikePhase: latest,
            recentSpikes: lines
        )
    }
}

@MainActor
public final class MainActorHitchMonitor {
    private var task: Task<Void, Never>?
    private var spikes = SpikeRingBuffer(limit: 8)
    private var heartbeatInterval: TimeInterval = 0.25
    private var thresholdMilliseconds: Double = 120

    public init() {}

    public func start(
        interval: TimeInterval = 0.25,
        thresholdMilliseconds: Double = 120
    ) {
        stop()
        heartbeatInterval = max(0.05, interval)
        self.thresholdMilliseconds = thresholdMilliseconds
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let warmupEnd = Date().addingTimeInterval(2)
            var expected = Date().addingTimeInterval(self.heartbeatInterval)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                let now = Date()
                let drift = max(0, now.timeIntervalSince(expected) * 1_000)
                if now >= warmupEnd {
                    self.spikes.record(
                        phase: "main actor heartbeat",
                        milliseconds: drift,
                        threshold: self.thresholdMilliseconds,
                        at: now,
                        logToOS: false
                    )
                }
                expected = now.addingTimeInterval(self.heartbeatInterval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func recordPublish(milliseconds: Double) {
        spikes.record(phase: "main actor publish", milliseconds: milliseconds, threshold: 16)
    }

    public var report: RadarSmoothnessReport {
        spikes.report
    }
}

public struct SamplerExecutionPlan: Equatable, Sendable {
    public let workerCount: Int
    public let telemetryJobCount: Int
    public let forensicsJobCount: Int
    public let scannerTaskCount: Int
    public let tinyQueueSequentialCount: Int

    public static let empty = SamplerExecutionPlan(
        workerCount: 0,
        telemetryJobCount: 0,
        forensicsJobCount: 0,
        scannerTaskCount: 0,
        tinyQueueSequentialCount: 0
    )

    public init(
        workerCount: Int,
        telemetryJobCount: Int,
        forensicsJobCount: Int,
        scannerTaskCount: Int,
        tinyQueueSequentialCount: Int
    ) {
        self.workerCount = workerCount
        self.telemetryJobCount = telemetryJobCount
        self.forensicsJobCount = forensicsJobCount
        self.scannerTaskCount = scannerTaskCount
        self.tinyQueueSequentialCount = tinyQueueSequentialCount
    }
}

public struct ProcessMonitorPublishedState: Equatable, Sendable {
    public let families: [ProcessFamily]
    public let summary: RadarSummary
    public let health: SamplerHealth
    public let incidents: [RadarIncident]
    public let rules: [RadarRule]
    public let model: RadarModel
    public let viewModel: RadarViewModel
    public let triageFamilies: [FamilyTriageViewModel]
    public let detailViewModels: [String: FamilyDetailViewModel]
    public let consoleSnapshot: RadarConsoleSnapshot
    public let engineDiagnostics: EngineDiagnosticsViewModel
    public let engineStatus: EngineStatusSnapshot
    public let performanceMetrics: RadarPerformanceMetrics
    public let scannerHealth: ScannerHealthSnapshot
    public let storeHealth: StoreHealth
    public let storeError: String?

    public static let empty = ProcessMonitorPublishedState(
        families: [],
        summary: .empty,
        health: .starting,
        incidents: [],
        rules: [],
        model: .empty,
        viewModel: .empty,
        triageFamilies: [],
        detailViewModels: [:],
        consoleSnapshot: .empty,
        engineDiagnostics: .empty,
        engineStatus: .empty,
        performanceMetrics: .empty,
        scannerHealth: .starting,
        storeHealth: .empty,
        storeError: nil
    )

    public init(
        families: [ProcessFamily],
        summary: RadarSummary,
        health: SamplerHealth,
        incidents: [RadarIncident],
        rules: [RadarRule],
        model: RadarModel,
        viewModel: RadarViewModel,
        triageFamilies: [FamilyTriageViewModel],
        detailViewModels: [String: FamilyDetailViewModel],
        consoleSnapshot: RadarConsoleSnapshot,
        engineDiagnostics: EngineDiagnosticsViewModel = .empty,
        engineStatus: EngineStatusSnapshot = .empty,
        performanceMetrics: RadarPerformanceMetrics,
        scannerHealth: ScannerHealthSnapshot,
        storeHealth: StoreHealth,
        storeError: String?
    ) {
        self.families = families
        self.summary = summary
        self.health = health
        self.incidents = incidents
        self.rules = rules
        self.model = model
        self.viewModel = viewModel
        self.triageFamilies = triageFamilies
        self.detailViewModels = detailViewModels
        self.consoleSnapshot = consoleSnapshot
        self.engineDiagnostics = engineDiagnostics
        self.engineStatus = engineStatus
        self.performanceMetrics = performanceMetrics
        self.scannerHealth = scannerHealth
        self.storeHealth = storeHealth
        self.storeError = storeError
    }

    public func updating(
        performanceMetrics: RadarPerformanceMetrics? = nil,
        consoleSnapshot: RadarConsoleSnapshot? = nil,
        engineDiagnostics: EngineDiagnosticsViewModel? = nil,
        engineStatus: EngineStatusSnapshot? = nil,
        storeError: String? = nil
    ) -> ProcessMonitorPublishedState {
        ProcessMonitorPublishedState(
            families: families,
            summary: summary,
            health: health,
            incidents: incidents,
            rules: rules,
            model: model,
            viewModel: viewModel,
            triageFamilies: triageFamilies,
            detailViewModels: detailViewModels,
            consoleSnapshot: consoleSnapshot ?? self.consoleSnapshot,
            engineDiagnostics: engineDiagnostics ?? self.engineDiagnostics,
            engineStatus: engineStatus ?? self.engineStatus,
            performanceMetrics: performanceMetrics ?? self.performanceMetrics,
            scannerHealth: scannerHealth,
            storeHealth: storeHealth,
            storeError: storeError ?? self.storeError
        )
    }
}

public enum RadarPublishMode: String, Codable, Equatable, Sendable {
    case contentChanged
    case diagnosticsOnly
}

public struct RadarPublishDelta: Equatable, Sendable {
    public let mode: RadarPublishMode
    public let previousRevision: SnapshotContentRevision
    public let nextRevision: SnapshotContentRevision
    public let skippedContentRebuild: Bool

    public static let contentChanged = RadarPublishDelta(
        mode: .contentChanged,
        previousRevision: .zero,
        nextRevision: .zero,
        skippedContentRebuild: false
    )

    public init(
        mode: RadarPublishMode,
        previousRevision: SnapshotContentRevision,
        nextRevision: SnapshotContentRevision,
        skippedContentRebuild: Bool
    ) {
        self.mode = mode
        self.previousRevision = previousRevision
        self.nextRevision = nextRevision
        self.skippedContentRebuild = skippedContentRebuild
    }
}

public struct RadarPublishPayload: Equatable, Sendable {
    public let state: ProcessMonitorPublishedState
    public let generatedAt: Date
    public let delta: RadarPublishDelta

    public init(
        state: ProcessMonitorPublishedState,
        generatedAt: Date,
        delta: RadarPublishDelta = .contentChanged
    ) {
        self.state = state
        self.generatedAt = generatedAt
        self.delta = delta
    }

    public static func build(
        families: [ProcessFamily],
        duplicateClusters: [DuplicateProcessCluster] = [],
        summary: RadarSummary,
        rules: [RadarRule],
        incidents: [RadarIncident],
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        performance: RadarPerformanceMetrics,
        previous: RadarConsoleSnapshot?,
        generatedAt: Date
    ) -> RadarPublishPayload {
        let contentRevision = SnapshotContentRevision.compute(
            families: families,
            summary: summary,
            incidents: incidents,
            rules: rules,
            duplicateClusters: duplicateClusters
        )
        let revisedPerformance = performance.updatingSmoothness(contentRevision: contentRevision)
        if let previous, previous.contentRevision == contentRevision {
            let diagnosticsPerformance = revisedPerformance.updatingSmoothness(
                uiCacheHitCount: revisedPerformance.uiCacheHitCount + 1,
                uiPublishSkippedCount: revisedPerformance.uiPublishSkippedCount + 1,
                diagnosticsOnlyPublishCount: revisedPerformance.diagnosticsOnlyPublishCount + 1,
                contentPublishSkippedCount: revisedPerformance.contentPublishSkippedCount + 1
            )
            let engine = EngineDiagnosticsViewModel(
                metrics: diagnosticsPerformance,
                health: health,
                storeHealth: storeHealth,
                storeError: storeError,
                summary: summary,
                generatedAt: generatedAt
            )
            let snapshot = previous.updatingEngine(engine, health: health, generatedAt: generatedAt)
            return RadarPublishPayload(
                state: ProcessMonitorPublishedState(
                    families: families,
                    summary: summary,
                    health: health,
                    incidents: incidents,
                    rules: rules,
                    model: RadarModel(
                        families: families,
                        duplicateClusters: duplicateClusters,
                        summary: summary,
                        incidents: incidents,
                        rules: rules,
                        health: health,
                        generatedAt: generatedAt
                    ),
                    viewModel: RadarViewModel(
                        summary: summary,
                        families: [],
                        performance: diagnosticsPerformance,
                        generatedAt: generatedAt
                    ),
                    triageFamilies: previous.families,
                    detailViewModels: [:],
                    consoleSnapshot: snapshot,
                    engineDiagnostics: engine,
                    engineStatus: snapshot.compact.engineStatus,
                    performanceMetrics: diagnosticsPerformance,
                    scannerHealth: diagnosticsPerformance.scannerHealth,
                    storeHealth: storeHealth,
                    storeError: storeError
                ),
                generatedAt: generatedAt,
                delta: RadarPublishDelta(
                    mode: .diagnosticsOnly,
                    previousRevision: previous.contentRevision,
                    nextRevision: contentRevision,
                    skippedContentRebuild: true
                )
            )
        }
        let model = RadarModel(
            families: families,
            duplicateClusters: duplicateClusters,
            summary: summary,
            incidents: incidents,
            rules: rules,
            health: health,
            generatedAt: generatedAt
        )
        let viewModel = RadarViewModel(
            summary: summary,
            families: families.map(RadarFamilyViewModel.init(family:)),
            performance: revisedPerformance,
            generatedAt: generatedAt
        )
        var details: [String: FamilyDetailViewModel] = [:]
        var bestBySignature: [String: FamilyDetailViewModel] = [:]
        details.reserveCapacity(families.count * 2)
        for family in families {
            let detail = FamilyDetailViewModel(family: family)
            details[family.familyKey] = detail
            if let current = bestBySignature[family.signature.id] {
                if detail.score > current.score || (detail.score == current.score && detail.memoryBytes > current.memoryBytes) {
                    bestBySignature[family.signature.id] = detail
                }
            } else {
                bestBySignature[family.signature.id] = detail
            }
        }
        for (signatureID, detail) in bestBySignature where details[signatureID] == nil {
            details[signatureID] = detail
        }
        let snapshot = RadarConsoleSnapshot.build(
            families: families,
            duplicateClusters: duplicateClusters,
            summary: summary,
            incidents: incidents,
            rules: rules,
            metrics: revisedPerformance,
            health: health,
            storeHealth: storeHealth,
            storeError: storeError,
            previous: previous,
            generatedAt: generatedAt
        )
        let triage = snapshot.families
        let engineDiagnostics = snapshot.engine
        let engineStatus = snapshot.compact.engineStatus
        return RadarPublishPayload(
            state: ProcessMonitorPublishedState(
                families: families,
                summary: summary,
                health: health,
                incidents: incidents,
                rules: rules,
                model: model,
                viewModel: viewModel,
                triageFamilies: triage,
                detailViewModels: details,
                consoleSnapshot: snapshot,
                engineDiagnostics: engineDiagnostics,
                engineStatus: engineStatus,
                performanceMetrics: revisedPerformance,
                scannerHealth: revisedPerformance.scannerHealth,
                storeHealth: storeHealth,
                storeError: storeError
            ),
            generatedAt: generatedAt,
            delta: RadarPublishDelta(
                mode: .contentChanged,
                previousRevision: previous?.contentRevision ?? .zero,
                nextRevision: contentRevision,
                skippedContentRebuild: false
            )
        )
    }
}
