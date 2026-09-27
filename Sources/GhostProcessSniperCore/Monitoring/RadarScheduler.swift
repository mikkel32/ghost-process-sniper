import CoreGraphics
import Foundation

/// Everything the cadence and budget choice depend on, so both are pure.
public struct RadarSchedulingContext: Equatable, Sendable {
    /// The popover or the console is on screen.
    public var uiVisible: Bool
    public var power: PowerContext
    public var thermalPressure: SystemPressureLevel
    public var summaryLevel: GhostLevel
    /// Every hot family has been hot for over five minutes and was already
    /// alerted on, as with a long build the user knows about.
    public var hotSinceAlerted: Bool
    /// What this tick cost, for backing off when over budget.
    public var currentRefreshMilliseconds: Double
    /// Seconds since the last keyboard, mouse or trackpad input anywhere.
    public var userIdleSeconds: TimeInterval

    public init(
        uiVisible: Bool,
        power: PowerContext = .mains,
        thermalPressure: SystemPressureLevel = .nominal,
        summaryLevel: GhostLevel = .quiet,
        hotSinceAlerted: Bool = false,
        currentRefreshMilliseconds: Double = 0,
        userIdleSeconds: TimeInterval = 0
    ) {
        self.uiVisible = uiVisible
        self.power = power
        self.thermalPressure = thermalPressure
        self.summaryLevel = summaryLevel
        self.hotSinceAlerted = hotSinceAlerted
        self.currentRefreshMilliseconds = currentRefreshMilliseconds
        self.userIdleSeconds = userIdleSeconds
    }
}

public struct RadarScheduler: Sendable {
    private var systemPressure: SystemPressureLevel = .nominal
    private var power = PowerContext.mains
    private var powerReader: PowerContextReader
    private var effectivePerformanceMode: RadarPerformanceMode = .balanced
    /// When each currently hot family turned hot.
    private var hotSince: [String: Date] = [:]
    /// When each quiet developer process last had its ports read.
    private var portCensusStamps: [ProcessIdentity: Date] = [:]
    private var planCount: UInt64 = 0
    private let pressureProvider: @Sendable () -> SystemPressureLevel
    private let idleProvider: @Sendable () -> TimeInterval

    /// A family hot for this long, and already alerted on, is a known long
    /// job rather than news, so the hidden cadence relaxes.
    static let settledHotDuration: TimeInterval = 300

    public init() {
        pressureProvider = { Self.currentSystemPressure() }
        idleProvider = { Self.systemIdleSeconds() }
        powerReader = PowerContextReader()
    }

    init(
        pressureProvider: @escaping @Sendable () -> SystemPressureLevel,
        powerSource: @escaping @Sendable () -> PowerContext = { .mains },
        idleSource: @escaping @Sendable () -> TimeInterval = { 0 }
    ) {
        self.pressureProvider = pressureProvider
        idleProvider = idleSource
        powerReader = PowerContextReader(source: powerSource)
    }

    /// Seconds since the last input event in the login session. Reading it
    /// needs no permission and never sees which keys or where.
    public func userIdleSeconds() -> TimeInterval {
        idleProvider()
    }

    static func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// A console left on screen while nobody touches the Mac is a wall
    /// display, not an investigation: it refreshes at half, then a quarter,
    /// of the watched rate. The next tick after any input is back at the
    /// watched rate, so the lag is at most one relaxed interval (4 s).
    static func unattendedMultiplier(idleSeconds: TimeInterval) -> Double {
        if idleSeconds >= 120 { return 4 }
        if idleSeconds >= 30 { return 2 }
        return 1
    }

    public mutating func updateSystemPressure() -> SystemPressureLevel {
        systemPressure = pressureProvider()
        return systemPressure
    }

    public mutating func plan(
        settings: ThresholdSettings,
        families: [ProcessFamily],
        uiVisible: Bool,
        focusedSignatureIDs: Set<String> = [],
        portCensusRequested: Bool = false,
        now: Date
    ) -> SamplingPlan {
        let pressure = updateSystemPressure()
        power = powerReader.context(now: now)
        planCount &+= 1
        let demand = FamilySamplingDemand(families: families, focusedKeys: focusedSignatureIDs, pass: planCount)
        let mode = settings.resolvedPerformanceMode(RadarSchedulingContext(
            uiVisible: uiVisible,
            power: power,
            thermalPressure: pressure,
            summaryLevel: demand.highestLevel
        ))
        effectivePerformanceMode = mode
        let budget = RadarPerformanceBudget.budget(for: mode)
        let scannerBudget = ScannerBudget.budget(for: mode, pressure: pressure)
        let maxForensics = pressure.allowsOptionalForensics ? min(budget.maxForensicsPerRefresh, scannerBudget.maxForensicsRefreshes) : 0
        let candidates = CandidateSet(
            identities: demand.candidateIdentities,
            pids: demand.candidatePIDs,
            reason: demand.reason
        )
        // CPU and memory are read for every process regardless; this only
        // bounds thread and VM reads, so even a critical thermal state keeps
        // the hot and focused cohort measured.
        let probePolicy = ProcessProbePolicy(
            richMetricIdentities: candidates.identities,
            richMetricPIDs: candidates.pids,
            allowsRichMetrics: true
        )
        let demandBudget = demand.hotFamilyCount * 4 + demand.focusedFamilyCount * 4
        let metricsBudget = pressure == .critical
            ? max(4, demandBudget)
            : max(scannerBudget.maxTelemetryRefreshes, demandBudget)
        let census = portCensusIdentities(
            demand: demand,
            limit: pressure.allowsOptionalForensics ? min(uiVisible ? 6 : 2, maxForensics) : 0,
            maxAge: uiVisible ? 15 : 60,
            now: now
        )

        return SamplingPlan(
            sampledAt: now,
            performanceMode: mode,
            commandRefreshInterval: SamplingPlan.telemetryRefreshInterval,
            includeForensicsFor: demand.forensicsIdentities,
            includeForensicsForPIDs: demand.forensicsPIDs,
            allowsOptionalForensics: pressure.allowsOptionalForensics,
            maxForensicsPerRefresh: maxForensics,
            reason: candidates.reason,
            scannerBudget: scannerBudget,
            candidateSet: candidates,
            probePolicy: probePolicy,
            metricsEnrichmentBudget: metricsBudget,
            uiVisible: uiVisible,
            hintedIdentities: demand.devIdentities,
            portCensusIdentities: census,
            portCensusAll: portCensusRequested
        )
    }

    /// Quiet developer processes whose ports are due, oldest read first, so a
    /// forgotten server on :3000 is answerable without being hot or focused.
    private mutating func portCensusIdentities(
        demand: FamilySamplingDemand,
        limit: Int,
        maxAge: TimeInterval,
        now: Date
    ) -> Set<ProcessIdentity> {
        portCensusStamps = portCensusStamps.filter { demand.devIdentities.contains($0.key) }
        guard limit > 0 else { return [] }
        let due = demand.devIdentities.filter { identity in
            !demand.forensicsIdentities.contains(identity) &&
                portCensusStamps[identity].map { now.timeIntervalSince($0) >= maxAge } ?? true
        }
        let picked = due.sorted {
            (portCensusStamps[$0] ?? .distantPast, $0.pid) < (portCensusStamps[$1] ?? .distantPast, $1.pid)
        }.prefix(limit)
        for identity in picked {
            portCensusStamps[identity] = now
        }
        return Set(picked)
    }

    /// Seconds until the next tick. Someone watching gets about one second
    /// (stretching when nobody has touched the Mac for a while);
    /// hidden, the radar slows with calm, battery, Low Power Mode, heat and
    /// its own cost. Timer tolerance, not jitter, spreads hidden wake-ups.
    public mutating func nextInterval(settings: ThresholdSettings, context: RadarSchedulingContext) -> TimeInterval {
        let mode = settings.resolvedPerformanceMode(context)
        effectivePerformanceMode = mode
        let base = Self.baseInterval(settings: settings, mode: mode, context: context)
        let pressureMultiplier: Double = switch context.thermalPressure {
        case .nominal: 1
        case .elevated: 1.25
        case .serious: 1.75
        case .critical: 2.5
        }
        let budget = RadarPerformanceBudget.budget(for: mode)
        let overBudgetMultiplier = context.currentRefreshMilliseconds > budget.targetRefreshMilliseconds ? 1.35 : 1
        return min(8, max(0.5, base * pressureMultiplier * overBudgetMultiplier))
    }

    static func baseInterval(
        settings: ThresholdSettings,
        mode: RadarPerformanceMode,
        context: RadarSchedulingContext
    ) -> TimeInterval {
        let level = context.summaryLevel
        if context.uiVisible {
            let watched: TimeInterval = level >= .hot ? 0.75 : (mode == .realtime ? 1 : max(1, settings.refreshInterval))
            return watched * unattendedMultiplier(idleSeconds: context.userIdleSeconds)
        }
        if context.power.lowPowerMode {
            return level >= .hot ? 3 : level == .watch ? 4 : 6
        }
        var base: TimeInterval
        if mode == .realtime {
            // Only an explicit choice runs realtime while hidden.
            base = level >= .hot ? 0.75 : 1
        } else if level >= .hot {
            base = context.hotSinceAlerted ? 2.5 : 1
        } else {
            base = level == .watch ? 2 : 3.5
        }
        if mode == .batterySaver || (context.power.onBattery && mode != .realtime) {
            base *= 1.5
        }
        return base
    }

    /// While hidden, stretches the cadence so the radar's own average CPU
    /// settles near twice the mode's idle target. Never while someone is
    /// watching: then the cost is mostly the UI they asked for.
    static func selfThrottled(
        _ interval: TimeInterval,
        selfAverageCPUPercent: Double,
        targetIdleCPUPercent: Double,
        uiVisible: Bool
    ) -> TimeInterval {
        let ceiling = 2 * targetIdleCPUPercent
        guard !uiVisible, ceiling > 0, selfAverageCPUPercent > ceiling else {
            return interval
        }
        return max(interval, min(8, interval * selfAverageCPUPercent / ceiling))
    }

    /// Tracks how long each family has been hot and reports whether every
    /// hot family is a settled, already-alerted one. A family the hysteresis
    /// is holding keeps its clock, so a build that runs hot in bursts can
    /// still settle.
    public mutating func noteHotFamilies(_ families: [ProcessFamily], now: Date) -> Bool {
        var next: [String: Date] = [:]
        var anyHot = false
        var allSettled = true
        for family in families {
            let key = family.familyKey
            if family.score.level >= .hot {
                let since = hotSince[key] ?? now
                next[key] = since
                anyHot = true
                if family.alertState.kind == .new || now.timeIntervalSince(since) <= Self.settledHotDuration {
                    allSettled = false
                }
            } else if let since = hotSince[key], family.score.reasons.contains(RadarHysteresis.holdReason) {
                next[key] = since
            }
        }
        hotSince = next
        return anyHot && allSettled
    }

    /// The level that sets the scanning pace. A family with nothing against
    /// it but its size does not speed scans up: a 2.5 GB chat app open all
    /// day kept the hidden radar at a hot family's one-second pace.
    static func schedulingLevel(_ families: [ProcessFamily]) -> GhostLevel {
        families.reduce(GhostLevel.quiet) { level, family in
            guard !family.hasOnlySizeAgainstIt else { return level }
            let escalates = family.forecastIsCredibleEscalation
            return max(level, max(family.score.level, escalates ? family.forecast.state.level : .quiet))
        }
    }

    public var currentPower: PowerContext {
        power
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
