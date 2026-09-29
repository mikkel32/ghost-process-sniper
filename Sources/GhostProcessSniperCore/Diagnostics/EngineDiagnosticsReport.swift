import Foundation

extension EngineDiagnosticsViewModel {
    /// The Copy Diagnostics text, built only when asked for. It embeds the
    /// generation time, so keeping it in the published view model made
    /// every tick's diagnostics unequal and re-rendered every reader. It says
    /// which build and Mac it came from, and with `profile` the settings and
    /// limits in effect, so a report can be reproduced.
    public static func diagnosticsReport(
        metrics: RadarPerformanceMetrics,
        health: SamplerHealth,
        storeHealth: StoreHealth,
        storeError: String?,
        summary: RadarSummary,
        generatedAt: Date,
        profile: ResolvedThresholdProfile? = nil
    ) -> String {
        let engine = EngineDiagnosticsViewModel(
            metrics: metrics,
            health: health,
            storeHealth: storeHealth,
            storeError: storeError,
            summary: summary,
            generatedAt: generatedAt
        )
        let optimization = RadarOptimizationReport(scannerHealth: metrics.scannerHealth, metrics: metrics)
        var lines = ["Ghost Process Sniper Diagnostics", "Generated: \(generatedAt.formatted())"]
        lines += DiagnosticsIdentity.current().lines
        if let profile { lines += DiagnosticsIdentity.settingsLines(profile) }
        lines += [
            "State: \(summary.statusText)",
            "Families: \(summary.familyCount), hot: \(summary.hotCount), leaks: \(summary.leakingCount)",
            "Duplicates: \(metrics.duplicateClusterCount) clusters, \(metrics.promotedDuplicateCandidateCount) promoted candidates, detector \(Int(metrics.duplicateDetectorMilliseconds.rounded()))ms",
            "Hardware offenders: \(metrics.hardwareOffenderCount), detector \(Int(metrics.hardwareDetectorMilliseconds.rounded()))ms",
            "Processes: \(health.processCount)",
            "Refresh: \(engine.refreshCostText), average: \(engine.averageCostText), next: \(engine.nextRefreshText)",
            "Forensics: \(engine.forensicsText)",
            "Scanner: \(engine.deadlineText), lanes: \(engine.scannerLaneText)",
            "Probe cost: \(engine.scannerCostText)",
            "Smoothness: \(engine.smoothnessText), in flight: \(metrics.refreshInFlight), skipped optional: \(metrics.skippedOptionalWorkCount), status update: \(Int(metrics.statusUpdateMilliseconds.rounded())) ms, content rev: \(metrics.contentRevision.rawValue)",
            "Scanner tasks: \(metrics.scannerTaskCount), tiny sequential queues: \(metrics.tinyQueueSequentialCount), task-info reads: \(metrics.taskInfoReadCount), reused records: \(metrics.reusedProcessRecordCount), scratch reuse: \(metrics.samplerAllocationReuseCount)",
            "Recent spikes: \(metrics.smoothnessReport.recentSpikes.isEmpty ? "none" : metrics.smoothnessReport.recentSpikes.joined(separator: " | "))",
            "Cache: \(engine.cacheText), expensive calls: \(engine.expensiveCallText)",
            optimization.text,
            "Store backlog: \(engine.storeBacklogText)",
            "Store coalescing: \(engine.storeCoalescingText)",
            "Pressure: \(engine.pressureText)",
            "Health: \(engine.statusLine)"
        ]
        return lines.joined(separator: "\n")
    }
}
