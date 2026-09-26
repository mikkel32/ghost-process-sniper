import Foundation

public struct ProcessMonitorPublishedState: Equatable, Sendable {
    public let families: [ProcessFamily]
    public let summary: RadarSummary
    public let health: SamplerHealth
    public let incidents: [RadarIncident]
    public let rules: [RadarRule]
    public let model: RadarModel
    public let triageFamilies: [FamilyTriageViewModel]
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
        triageFamilies: [],
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
        triageFamilies: [FamilyTriageViewModel],
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
        self.triageFamilies = triageFamilies
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
            triageFamilies: triageFamilies,
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
        generatedAt: Date,
        detailSignatures: Set<String>? = nil,
        processes: [ProcessMetrics] = []
    ) -> RadarPublishPayload {
        let contentRevision = SnapshotContentRevision.compute(
            families: families,
            summary: summary,
            incidents: incidents,
            rules: rules,
            duplicateClusters: duplicateClusters
        )
        let revisedPerformance = performance.updatingSmoothness(contentRevision: contentRevision)
        if let previous, previous.contentRevision == contentRevision,
           previous.coversDetails(families: families, requested: detailSignatures) {
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
                    triageFamilies: previous.families,
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
        let snapshot = RadarConsoleSnapshot.build(
            families: families, duplicateClusters: duplicateClusters, summary: summary,
            incidents: incidents, rules: rules, metrics: revisedPerformance, health: health,
            storeHealth: storeHealth, storeError: storeError, previous: previous,
            generatedAt: generatedAt, detailSignatures: detailSignatures, processes: processes,
            contentRevision: contentRevision
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
                triageFamilies: triage,
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
