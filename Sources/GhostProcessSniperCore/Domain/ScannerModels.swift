import Foundation

public enum ScanLane: String, Codable, CaseIterable, Hashable, Sendable {
    case cheapMetrics
    case telemetryCache
    case telemetryRefresh
    case richMetrics
    case forensicsQueue
    case forensicsCache
    case deadlineSkipped

    public var label: String {
        switch self {
        case .cheapMetrics: "Cheap scan"
        case .telemetryCache: "Telemetry cached"
        case .telemetryRefresh: "Telemetry refreshed"
        case .richMetrics: "Rich metrics"
        case .forensicsQueue: "Forensics queue"
        case .forensicsCache: "Forensics cached"
        case .deadlineSkipped: "Deadline skip"
        }
    }
}

public struct ScannerBudget: Equatable, Sendable {
    public let targetMilliseconds: Double
    public let optionalMilliseconds: Double
    public let maxTelemetryRefreshes: Int
    public let maxForensicsRefreshes: Int
    public let negativeForensicsTTL: TimeInterval
    public let staleTelemetryGrace: TimeInterval

    public init(
        targetMilliseconds: Double,
        optionalMilliseconds: Double,
        maxTelemetryRefreshes: Int,
        maxForensicsRefreshes: Int,
        negativeForensicsTTL: TimeInterval,
        staleTelemetryGrace: TimeInterval
    ) {
        self.targetMilliseconds = targetMilliseconds
        self.optionalMilliseconds = optionalMilliseconds
        self.maxTelemetryRefreshes = maxTelemetryRefreshes
        self.maxForensicsRefreshes = maxForensicsRefreshes
        self.negativeForensicsTTL = negativeForensicsTTL
        self.staleTelemetryGrace = staleTelemetryGrace
    }

    public static func budget(for mode: RadarPerformanceMode, pressure: SystemPressureLevel = .nominal) -> ScannerBudget {
        let base: ScannerBudget = switch mode {
        case .batterySaver:
            ScannerBudget(
                targetMilliseconds: 28,
                optionalMilliseconds: 8,
                maxTelemetryRefreshes: 8,
                maxForensicsRefreshes: 2,
                negativeForensicsTTL: 180,
                staleTelemetryGrace: 90
            )
        case .balanced:
            ScannerBudget(
                targetMilliseconds: 42,
                optionalMilliseconds: 14,
                maxTelemetryRefreshes: 16,
                maxForensicsRefreshes: 6,
                negativeForensicsTTL: 120,
                staleTelemetryGrace: 60
            )
        case .realtime:
            ScannerBudget(
                targetMilliseconds: 80,
                optionalMilliseconds: 30,
                maxTelemetryRefreshes: 48,
                maxForensicsRefreshes: 12,
                negativeForensicsTTL: 60,
                staleTelemetryGrace: 30
            )
        }

        let multiplier: Double = switch pressure {
        case .nominal: 1
        case .elevated: 0.8
        case .serious: 0.55
        case .critical: 0.35
        }

        return ScannerBudget(
            targetMilliseconds: max(10, base.targetMilliseconds * multiplier),
            optionalMilliseconds: max(0, base.optionalMilliseconds * multiplier),
            maxTelemetryRefreshes: max(4, Int(Double(base.maxTelemetryRefreshes) * multiplier)),
            maxForensicsRefreshes: pressure.allowsOptionalForensics ? max(0, Int(Double(base.maxForensicsRefreshes) * multiplier)) : 0,
            negativeForensicsTTL: base.negativeForensicsTTL,
            staleTelemetryGrace: base.staleTelemetryGrace
        )
    }
}

public struct CandidateSet: Equatable, Sendable {
    public let identities: Set<ProcessIdentity>
    public let pids: Set<Int32>
    public let reason: String

    public static let empty = CandidateSet(identities: [], pids: [], reason: "empty")

    public init(identities: Set<ProcessIdentity>, pids: Set<Int32>, reason: String) {
        self.identities = identities
        self.pids = pids
        self.reason = reason
    }

    public func contains(identity: ProcessIdentity, pid: Int32) -> Bool {
        identities.contains(identity) || pids.contains(pid)
    }
}

public struct ProcessProbePolicy: Equatable, Sendable {
    public let richMetricIdentities: Set<ProcessIdentity>
    public let richMetricPIDs: Set<Int32>
    public let allowsRichMetrics: Bool

    public static let balanced = ProcessProbePolicy(
        richMetricIdentities: [],
        richMetricPIDs: [],
        allowsRichMetrics: true
    )

    public init(
        richMetricIdentities: Set<ProcessIdentity>,
        richMetricPIDs: Set<Int32>,
        allowsRichMetrics: Bool
    ) {
        self.richMetricIdentities = richMetricIdentities
        self.richMetricPIDs = richMetricPIDs
        self.allowsRichMetrics = allowsRichMetrics
    }
}

public struct ScannerCostLedger: Equatable, Sendable {
    public let cheapProbeCount: Int
    public let richMetricCount: Int
    public let bsdReadCount: Int
    public let taskInfoReadCount: Int
    public let reusedRecordCount: Int
    public let pidBufferCopyCount: Int
    public let scratchpadReuseCount: Int
    public let telemetryRefreshCount: Int
    public let forensicsRefreshCount: Int
    public let skippedCount: Int
    public let workerCount: Int
    public let skippedOptionalWorkCount: Int
    public let scannerTaskCount: Int
    public let tinyQueueSequentialCount: Int
    public let usageReadCount: Int
    public let usageFailedCount: Int
    public let bsdDeniedCount: Int

    public init(
        cheapProbeCount: Int,
        richMetricCount: Int,
        bsdReadCount: Int = 0,
        taskInfoReadCount: Int = 0,
        reusedRecordCount: Int = 0,
        pidBufferCopyCount: Int = 0,
        scratchpadReuseCount: Int = 0,
        telemetryRefreshCount: Int,
        forensicsRefreshCount: Int,
        skippedCount: Int,
        workerCount: Int = 0,
        skippedOptionalWorkCount: Int = 0,
        scannerTaskCount: Int = 0,
        tinyQueueSequentialCount: Int = 0,
        usageReadCount: Int = 0,
        usageFailedCount: Int = 0,
        bsdDeniedCount: Int = 0
    ) {
        self.cheapProbeCount = cheapProbeCount
        self.richMetricCount = richMetricCount
        self.bsdReadCount = bsdReadCount
        self.taskInfoReadCount = taskInfoReadCount
        self.reusedRecordCount = reusedRecordCount
        self.pidBufferCopyCount = pidBufferCopyCount
        self.scratchpadReuseCount = scratchpadReuseCount
        self.telemetryRefreshCount = telemetryRefreshCount
        self.forensicsRefreshCount = forensicsRefreshCount
        self.skippedCount = skippedCount
        self.workerCount = workerCount
        self.skippedOptionalWorkCount = skippedOptionalWorkCount
        self.scannerTaskCount = scannerTaskCount
        self.tinyQueueSequentialCount = tinyQueueSequentialCount
        self.usageReadCount = usageReadCount
        self.usageFailedCount = usageFailedCount
        self.bsdDeniedCount = bsdDeniedCount
    }

    public init(stats: SamplerStats) {
        self.init(
            cheapProbeCount: stats.laneCounts[.cheapMetrics, default: 0],
            richMetricCount: stats.laneCounts[.richMetrics, default: 0],
            bsdReadCount: stats.bsdReadCount,
            taskInfoReadCount: stats.taskInfoReadCount,
            reusedRecordCount: stats.reusedRecordCount,
            pidBufferCopyCount: stats.pidBufferCopyCount,
            scratchpadReuseCount: stats.scratchpadReuseCount,
            telemetryRefreshCount: stats.commandRefreshCount,
            forensicsRefreshCount: stats.forensicsRefreshCount,
            skippedCount: stats.skippedPIDCount,
            workerCount: stats.scannerWorkerCount,
            skippedOptionalWorkCount: stats.skippedOptionalWorkCount,
            scannerTaskCount: stats.scannerTaskCount,
            tinyQueueSequentialCount: stats.tinyQueueSequentialCount,
            usageReadCount: stats.usageReadCount,
            usageFailedCount: stats.usageFailedCount,
            bsdDeniedCount: stats.bsdDeniedCount
        )
    }
}

public struct ScannerHealthSnapshot: Equatable, Sendable {
    public let budget: ScannerBudget
    public let budgetTargetMilliseconds: Double
    public let elapsedMilliseconds: Double
    public let didHitDeadline: Bool
    public let laneCounts: [ScanLane: Int]
    public let expensiveCallCount: Int
    public let telemetryDeferredCount: Int
    public let forensicsNegativeCacheHitCount: Int
    public let skippedPIDCount: Int
    public let costLedger: ScannerCostLedger
    public let optimizationReport: String

    public static let starting = ScannerHealthSnapshot(
        budget: ScannerBudget.budget(for: .balanced),
        budgetTargetMilliseconds: 0,
        elapsedMilliseconds: 0,
        didHitDeadline: false,
        laneCounts: [:],
        expensiveCallCount: 0,
        telemetryDeferredCount: 0,
        forensicsNegativeCacheHitCount: 0,
        skippedPIDCount: 0,
        costLedger: ScannerCostLedger(
            cheapProbeCount: 0,
            richMetricCount: 0,
            bsdReadCount: 0,
            taskInfoReadCount: 0,
            reusedRecordCount: 0,
            pidBufferCopyCount: 0,
            scratchpadReuseCount: 0,
            telemetryRefreshCount: 0,
            forensicsRefreshCount: 0,
            skippedCount: 0,
            workerCount: 0,
            skippedOptionalWorkCount: 0,
            scannerTaskCount: 0,
            tinyQueueSequentialCount: 0
        ),
        optimizationReport: "Scanner warming up."
    )

    public init(
        budget: ScannerBudget,
        budgetTargetMilliseconds: Double,
        elapsedMilliseconds: Double,
        didHitDeadline: Bool,
        laneCounts: [ScanLane: Int],
        expensiveCallCount: Int,
        telemetryDeferredCount: Int,
        forensicsNegativeCacheHitCount: Int,
        skippedPIDCount: Int,
        costLedger: ScannerCostLedger,
        optimizationReport: String
    ) {
        self.budget = budget
        self.budgetTargetMilliseconds = budgetTargetMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.didHitDeadline = didHitDeadline
        self.laneCounts = laneCounts
        self.expensiveCallCount = expensiveCallCount
        self.telemetryDeferredCount = telemetryDeferredCount
        self.forensicsNegativeCacheHitCount = forensicsNegativeCacheHitCount
        self.skippedPIDCount = skippedPIDCount
        self.costLedger = costLedger
        self.optimizationReport = optimizationReport
    }

    public init(stats: SamplerStats, budget: ScannerBudget) {
        let laneSummary = ScanLane.allCases
            .map { "\($0.label): \(stats.laneCounts[$0, default: 0])" }
            .joined(separator: ", ")
        self.init(
            budget: budget,
            budgetTargetMilliseconds: budget.targetMilliseconds,
            elapsedMilliseconds: stats.elapsedMilliseconds,
            didHitDeadline: stats.didHitDeadline,
            laneCounts: stats.laneCounts,
            expensiveCallCount: stats.expensiveCallCount,
            telemetryDeferredCount: stats.telemetryDeferredCount,
            forensicsNegativeCacheHitCount: stats.forensicsNegativeCacheHitCount,
            skippedPIDCount: stats.skippedPIDCount,
            costLedger: ScannerCostLedger(stats: stats),
            optimizationReport: "Scanner \(Int(stats.elapsedMilliseconds.rounded()))ms / \(Int(budget.targetMilliseconds.rounded()))ms. \(laneSummary). BSD reads: \(stats.bsdReadCount). Task info: \(stats.taskInfoReadCount). Reused: \(stats.reusedRecordCount). Usage: \(stats.usageReadCount), failed \(stats.usageFailedCount). Other users' processes not visible: \(stats.bsdDeniedCount)."
        )
    }
}

public struct RadarOptimizationReport: Equatable, Sendable {
    public let title: String
    public let lines: [String]

    public init(scannerHealth: ScannerHealthSnapshot, metrics: RadarPerformanceMetrics) {
        title = scannerHealth.didHitDeadline ? "Scanner budget constrained" : "Scanner within budget"
        lines = [
            "Refresh \(Int(metrics.lastRefresh.totalMilliseconds.rounded())) ms, average \(Int(metrics.averageRefreshMilliseconds.rounded())) ms",
            "Scanner \(Int(scannerHealth.elapsedMilliseconds.rounded())) / \(Int(scannerHealth.budgetTargetMilliseconds.rounded())) ms",
            "Probe lanes cheap \(scannerHealth.costLedger.cheapProbeCount), BSD \(scannerHealth.costLedger.bsdReadCount), task-info \(scannerHealth.costLedger.taskInfoReadCount), reused \(scannerHealth.costLedger.reusedRecordCount), workers \(scannerHealth.costLedger.workerCount), tasks \(scannerHealth.costLedger.scannerTaskCount), tiny sequential \(scannerHealth.costLedger.tinyQueueSequentialCount), skipped \(scannerHealth.costLedger.skippedCount)",
            "Hardware detector \(metrics.hardwareOffenderCount) offenders in \(Int(metrics.hardwareDetectorMilliseconds.rounded())) ms",
            "Allocations PID copies \(scannerHealth.costLedger.pidBufferCopyCount), scratch reuse \(scannerHealth.costLedger.scratchpadReuseCount)",
            "Expensive calls \(scannerHealth.expensiveCallCount), deferred telemetry \(scannerHealth.telemetryDeferredCount)",
            "Forensics negative-cache hits \(scannerHealth.forensicsNegativeCacheHitCount), skipped optional work \(scannerHealth.costLedger.skippedOptionalWorkCount), skipped PIDs \(scannerHealth.skippedPIDCount)"
        ]
    }

    public var text: String {
        ([title] + lines).joined(separator: "\n")
    }
}
