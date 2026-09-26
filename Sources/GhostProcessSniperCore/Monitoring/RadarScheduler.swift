import Foundation

public struct RadarScheduler: Sendable {
    private var lastInterval: TimeInterval = 1
    private var lastPlan: SamplingPlan = .balanced(now: Date(timeIntervalSince1970: 0))
    private var systemPressure: SystemPressureLevel = .nominal
    private var effectivePerformanceMode: RadarPerformanceMode = .balanced
    private var cadenceStep: UInt64 = 0

    public init() {}

    public mutating func updateSystemPressure() -> SystemPressureLevel {
        systemPressure = Self.currentSystemPressure()
        return systemPressure
    }

    public mutating func plan(
        settings: ThresholdSettings,
        families: [ProcessFamily],
        popoverVisible: Bool,
        focusedSignatureIDs: Set<String> = [],
        now: Date
    ) -> SamplingPlan {
        let pressure = updateSystemPressure()
        let demand = FamilySamplingDemand(families: families, focusedKeys: focusedSignatureIDs)
        let mode = settings.resolvedPerformanceMode(
            summaryLevel: demand.highestLevel,
            popoverVisible: popoverVisible,
            systemPressure: pressure
        )
        effectivePerformanceMode = mode
        let budget = RadarPerformanceBudget.budget(for: mode)
        let scannerBudget = ScannerBudget.budget(for: mode, pressure: pressure)
        let maxForensics = pressure.allowsOptionalForensics ? min(budget.maxForensicsPerRefresh, scannerBudget.maxForensicsRefreshes) : 0
        let candidates = CandidateSet(
            identities: demand.candidateIdentities,
            pids: demand.candidatePIDs,
            reason: demand.reason
        )
        let probePolicy = ProcessProbePolicy(
            richMetricIdentities: candidates.identities,
            richMetricPIDs: candidates.pids,
            allowsRichMetrics: pressure != .critical
        )

        let commandInterval: TimeInterval = switch mode {
        case .batterySaver: popoverVisible ? 15 : 30
        case .balanced: popoverVisible ? 8 : 20
        case .realtime: 5
        }

        let plan = SamplingPlan(
            sampledAt: now,
            performanceMode: mode,
            commandRefreshInterval: commandInterval,
            includeForensicsFor: demand.forensicsIdentities,
            includeForensicsForPIDs: demand.forensicsPIDs,
            forceCommandRefresh: popoverVisible && now.timeIntervalSince(lastPlan.sampledAt) >= commandInterval,
            allowsOptionalForensics: pressure.allowsOptionalForensics,
            maxForensicsPerRefresh: maxForensics,
            reason: candidates.reason,
            scannerBudget: scannerBudget,
            candidateSet: candidates,
            probePolicy: probePolicy,
            metricsEnrichmentBudget: max(scannerBudget.maxTelemetryRefreshes, demand.hotFamilyCount * 4 + demand.focusedFamilyCount * 4),
            uiVisible: popoverVisible
        )
        lastPlan = plan
        return plan
    }

    public mutating func nextInterval(
        settings: ThresholdSettings,
        summary: RadarSummary,
        lastRefresh: RefreshStats,
        popoverVisible: Bool
    ) -> TimeInterval {
        let pressure = systemPressure
        let mode = settings.resolvedPerformanceMode(
            summaryLevel: summary.level,
            popoverVisible: popoverVisible,
            systemPressure: pressure
        )
        effectivePerformanceMode = mode
        let base: TimeInterval
        if summary.level >= .hot {
            base = 0.75
        } else if popoverVisible {
            base = mode == .realtime ? 0.75 : max(0.75, settings.refreshInterval)
        } else {
            base = switch mode {
            case .batterySaver: 5
            case .balanced: summary.level == .watch ? 2 : 3.5
            case .realtime: 1
            }
        }

        let pressureMultiplier: Double = switch pressure {
        case .nominal: 1
        case .elevated: 1.25
        case .serious: 1.75
        case .critical: 2.5
        }

        let budget = RadarPerformanceBudget.budget(for: mode)
        let overBudgetMultiplier = lastRefresh.totalMilliseconds > budget.targetRefreshMilliseconds ? 1.35 : 1
        cadenceStep &+= 1
        let jitter: TimeInterval
        if summary.level >= .hot || popoverVisible {
            jitter = 0
        } else {
            jitter = Double(cadenceStep % 5) * 0.07
        }
        let interval = min(8, max(0.5, base * pressureMultiplier * overBudgetMultiplier + jitter))
        lastInterval = interval
        return interval
    }

    public var currentPressure: SystemPressureLevel {
        systemPressure
    }

    public var currentPerformanceMode: RadarPerformanceMode {
        effectivePerformanceMode
    }

    private static func currentSystemPressure() -> SystemPressureLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .elevated
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .nominal
        }
    }
}
