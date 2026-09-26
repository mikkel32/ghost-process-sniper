import Darwin
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

public struct SamplerDeadline: Equatable, Sendable {
    public let startedAt: Date
    public let budgetMilliseconds: Double

    public init(startedAt: Date, budgetMilliseconds: Double) {
        self.startedAt = startedAt
        self.budgetMilliseconds = budgetMilliseconds
    }

    public func elapsedMilliseconds(now: Date = Date()) -> Double {
        now.timeIntervalSince(startedAt) * 1_000
    }

    public func isExpired(now: Date = Date()) -> Bool {
        elapsedMilliseconds(now: now) >= budgetMilliseconds
    }
}

public struct ProcessProbe: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let residentMemoryBytes: UInt64
    public let physicalFootprintBytes: UInt64
    public let virtualMemoryBytes: UInt64
    public let cpuPercent: Double
    public let totalProcessorSeconds: TimeInterval
    public let threadCount: Int
    public let isSystemProcess: Bool

    public var pid: Int32 { identity.pid }

    public var fingerprint: UInt64 {
        var hasher = Hasher()
        hasher.combine(parentPID)
        hasher.combine(userID)
        hasher.combine(residentMemoryBytes / 8_388_608)
        hasher.combine(physicalFootprintBytes / 8_388_608)
        hasher.combine(Int(cpuPercent.rounded()))
        hasher.combine(threadCount)
        hasher.combine(isSystemProcess)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

public struct ProcessLiteRecord: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let name: String
    public let processGroupID: Int32
    public let status: UInt32
    public let flags: UInt32
    public let openFileCount: Int
    public let sampledAt: Date

    public var pid: Int32 { identity.pid }
    public var isSystemProcess: Bool { (flags & UInt32(PROC_FLAG_SYSTEM)) != 0 }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        name: String,
        processGroupID: Int32,
        status: UInt32,
        flags: UInt32,
        openFileCount: Int,
        sampledAt: Date
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.processGroupID = processGroupID
        self.status = status
        self.flags = flags
        self.openFileCount = openFileCount
        self.sampledAt = sampledAt
    }

    public var fingerprint: UInt64 {
        var hasher = Hasher()
        hasher.combine(parentPID)
        hasher.combine(userID)
        hasher.combine(processGroupID)
        hasher.combine(status)
        hasher.combine(flags)
        hasher.combine(openFileCount)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

public struct ProcessGraphLiteBatch: Equatable, Sendable {
    public let records: [ProcessLiteRecord]
    public let sampledAt: Date
    public let bsdReadCount: Int
    public let pidBufferCopyCount: Int

    public init(records: [ProcessLiteRecord], sampledAt: Date, bsdReadCount: Int, pidBufferCopyCount: Int) {
        self.records = records
        self.sampledAt = sampledAt
        self.bsdReadCount = bsdReadCount
        self.pidBufferCopyCount = pidBufferCopyCount
    }
}

public struct ProcessMetricsEnrichmentPolicy: Equatable, Sendable {
    public let richMetricBudget: Int
    public let unknownProcessStride: Int
    public let trueCheapScanEnabled: Bool

    public init(
        richMetricBudget: Int,
        unknownProcessStride: Int,
        trueCheapScanEnabled: Bool
    ) {
        self.richMetricBudget = max(0, richMetricBudget)
        self.unknownProcessStride = max(1, unknownProcessStride)
        self.trueCheapScanEnabled = trueCheapScanEnabled
    }
}

public struct ScannerScratchpad: Equatable, Sendable {
    public let rawSampleCapacity: Int
    public let activeSampleCapacity: Int
    public let telemetryJobCapacity: Int
    public let forensicsJobCapacity: Int
    public let reuseCount: Int

    public static let empty = ScannerScratchpad(
        rawSampleCapacity: 0,
        activeSampleCapacity: 0,
        telemetryJobCapacity: 0,
        forensicsJobCapacity: 0,
        reuseCount: 0
    )

    public init(
        rawSampleCapacity: Int,
        activeSampleCapacity: Int,
        telemetryJobCapacity: Int,
        forensicsJobCapacity: Int,
        reuseCount: Int
    ) {
        self.rawSampleCapacity = rawSampleCapacity
        self.activeSampleCapacity = activeSampleCapacity
        self.telemetryJobCapacity = telemetryJobCapacity
        self.forensicsJobCapacity = forensicsJobCapacity
        self.reuseCount = reuseCount
    }
}

public struct ScannerAllocationStats: Equatable, Sendable {
    public let pidBufferCopyCount: Int
    public let scratchpadReuseCount: Int
    public let reusedRecordCount: Int

    public static let empty = ScannerAllocationStats(
        pidBufferCopyCount: 0,
        scratchpadReuseCount: 0,
        reusedRecordCount: 0
    )

    public init(pidBufferCopyCount: Int, scratchpadReuseCount: Int, reusedRecordCount: Int) {
        self.pidBufferCopyCount = pidBufferCopyCount
        self.scratchpadReuseCount = scratchpadReuseCount
        self.reusedRecordCount = reusedRecordCount
    }
}

public struct ProcessRecord: Equatable, Sendable {
    public let identity: ProcessIdentity
    public var process: ProcessMetrics
    public var metricsFingerprint: UInt64
    public var telemetryRefreshedAt: Date
    public var lastSeenAt: Date
    public var classification: DevClassification?

    public init(
        identity: ProcessIdentity,
        process: ProcessMetrics,
        metricsFingerprint: UInt64,
        telemetryRefreshedAt: Date,
        lastSeenAt: Date,
        classification: DevClassification? = nil
    ) {
        self.identity = identity
        self.process = process
        self.metricsFingerprint = metricsFingerprint
        self.telemetryRefreshedAt = telemetryRefreshedAt
        self.lastSeenAt = lastSeenAt
        self.classification = classification
    }
}

public struct ProcessScanCache: Sendable {
    private var records: [ProcessIdentity: ProcessRecord] = [:]

    public init() {}

    public func record(for identity: ProcessIdentity) -> ProcessRecord? {
        records[identity]
    }

    public func contains(_ identity: ProcessIdentity) -> Bool {
        records[identity] != nil
    }

    public func metricsFingerprint(for identity: ProcessIdentity) -> UInt64? {
        records[identity]?.metricsFingerprint
    }

    public mutating func update(_ record: ProcessRecord) {
        records[record.identity] = record
    }

    public mutating func prune(keeping identities: Set<ProcessIdentity>) {
        records = records.filter { identities.contains($0.key) }
    }

    public func shouldRefreshTelemetry(
        identity: ProcessIdentity,
        probeFingerprint: UInt64,
        now: Date,
        maxAge: TimeInterval,
        grace: TimeInterval,
        isPriority: Bool,
        force: Bool
    ) -> Bool {
        guard let record = records[identity] else {
            return true
        }
        let _ = probeFingerprint
        if force {
            return true
        }
        let age = now.timeIntervalSince(record.telemetryRefreshedAt)
        let refreshAge = isPriority ? maxAge : maxAge + grace
        return age > refreshAge
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

public struct ForensicsWorkQueue: Equatable, Sendable {
    private var identities: [ProcessIdentity]

    public init(identities: [ProcessIdentity]) {
        var seen = Set<ProcessIdentity>()
        self.identities = identities.filter { seen.insert($0).inserted }
    }

    public mutating func pop() -> ProcessIdentity? {
        identities.isEmpty ? nil : identities.removeFirst()
    }

    public var isEmpty: Bool {
        identities.isEmpty
    }
}

public struct ProcessProbePolicy: Equatable, Sendable {
    public let richMetricIdentities: Set<ProcessIdentity>
    public let richMetricPIDs: Set<Int32>
    public let quietRichMetricStride: Int
    public let allowsRichMetrics: Bool

    public static let balanced = ProcessProbePolicy(
        richMetricIdentities: [],
        richMetricPIDs: [],
        quietRichMetricStride: 6,
        allowsRichMetrics: true
    )

    public init(
        richMetricIdentities: Set<ProcessIdentity>,
        richMetricPIDs: Set<Int32>,
        quietRichMetricStride: Int,
        allowsRichMetrics: Bool
    ) {
        self.richMetricIdentities = richMetricIdentities
        self.richMetricPIDs = richMetricPIDs
        self.quietRichMetricStride = max(1, quietRichMetricStride)
        self.allowsRichMetrics = allowsRichMetrics
    }

    public func shouldReadRichMetrics(identity: ProcessIdentity, pid: Int32, ordinal: Int, isPriority: Bool) -> Bool {
        guard allowsRichMetrics else {
            return false
        }
        if isPriority || richMetricIdentities.contains(identity) || richMetricPIDs.contains(pid) {
            return true
        }
        return ordinal % quietRichMetricStride == 0
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
        tinyQueueSequentialCount: Int = 0
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
            tinyQueueSequentialCount: stats.tinyQueueSequentialCount
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
            optimizationReport: "Scanner \(Int(stats.elapsedMilliseconds.rounded()))ms / \(Int(budget.targetMilliseconds.rounded()))ms. \(laneSummary). BSD reads: \(stats.bsdReadCount). Task info: \(stats.taskInfoReadCount). Reused: \(stats.reusedRecordCount)."
        )
    }
}

public struct FamilyScoringCache: Sendable {
    private struct Entry: Sendable {
        var fingerprint: UInt64
        var family: ProcessFamily
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func cachedFamily(for family: ProcessFamily, context: RadarContext) -> ProcessFamily? {
        let fingerprint = Self.fingerprint(family: family, context: context)
        guard let entry = entries[family.familyKey], entry.fingerprint == fingerprint else {
            return nil
        }
        // Reuse derived judgments, never the old process readings or forensics.
        // A stable score must not freeze measurement timestamps and then make
        // a continuously sampled family appear stale.
        let cached = entry.family
        return family.enriched(
            score: cached.score,
            baseline: cached.baseline,
            suggestions: cached.suggestions,
            alertState: cached.alertState,
            recentIncidentCount: cached.recentIncidentCount,
            forecast: cached.forecast,
            lastScoredAt: cached.lastScoredAt == nil ? nil : family.root.sampledAt
        )
    }

    public mutating func store(_ family: ProcessFamily, context: RadarContext) {
        entries[family.familyKey] = Entry(
            fingerprint: Self.fingerprint(family: family, context: context),
            family: family
        )
    }

    public mutating func prune(keeping signatureIDs: Set<String>) {
        entries = entries.filter { signatureIDs.contains($0.key) }
    }

    public static func fingerprint(family: ProcessFamily, context: RadarContext) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(context.systemPressure.level)
        hasher.combine(family.signature.id)
        hasher.combine(family.members.map(\.identity))
        hasher.combine(family.hasRecentMeasurements(at: family.root.sampledAt))
        hasher.combine(family.trend.hasSustainedHistory)
        hasher.combine(min(4, family.trend.sampleCount))
        hasher.combine(Int((family.trend.memoryFitQuality * 10).rounded()))
        hasher.combine(family.totalPhysicalFootprintBytes / 4_194_304)
        hasher.combine(Int(family.totalCPUPercent.rounded()))
        hasher.combine(Int(family.totalGPUPercent.rounded()))
        hasher.combine(family.hardwareSignals.map(\.reason))
        hasher.combine(Int(family.trend.memoryVelocityMegabytesPerMinute.rounded()))
        hasher.combine(Int(family.root.sampledAt.timeIntervalSince1970 / 300))
        hasher.combine(family.score.value.rounded())
        if let baseline = context.baselines[family.signature.id] {
            hasher.combine(baseline.measurementVersion)
            hasher.combine(baseline.sampleCount)
            hasher.combine(Int(baseline.meanMemoryBytes.rounded()))
            hasher.combine(baseline.incidentCount)
        }
        hasher.combine(context.recentIncidentCounts[family.signature.id, default: 0])
        for rule in context.rules {
            hasher.combine(rule.id)
            hasher.combine(rule.isEnabled)
            hasher.combine(rule.action.rawValue)
            hasher.combine(rule.expiresAt?.timeIntervalSince1970 ?? 0)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

public struct CulpritAnalysis: Equatable, Sendable {
    public let kind: DevProcessKind
    public let likelyCause: String
    public let nextAction: String
    public let repoHint: String?
    public let evidence: [String]

    public init(
        family: ProcessFamily,
        classifier: DevProcessClassifier = DevProcessClassifier(),
        classification providedClassification: DevClassification? = nil
    ) {
        let classification = providedClassification ?? family.classification ?? classifier.classification(for: family)
        kind = classification.kind
        repoHint = Self.repoHint(for: family)
        let hasCredibleForecast = family.forecastIsCredibleEarlyWarning
        let hasCredibleEscalation = family.forecastIsCredibleEscalation
        let forecastActionDetail = family.presentedForecastRecommendation.detail

        var evidence = [classification.reason]
        for signal in family.hardwareSignals.prefix(3) {
            evidence.append(signal.reason)
        }
        if family.trend.memoryVelocityMegabytesPerMinute > 0 {
            evidence.append("Memory rising \(Int(family.trend.memoryVelocityMegabytesPerMinute.rounded())) MB/min")
        }
        if family.totalCPUPercent >= 50 {
            evidence.append("CPU burst \(Int(family.totalCPUPercent.rounded()))%")
        }
        if family.childCount >= 4 {
            evidence.append("\(family.childCount) children in tree")
        }
        if hasCredibleForecast {
            evidence.append("\(family.forecastPresentationText), ETA \(family.forecast.etaText)")
            evidence.append(family.forecast.whyNow)
        } else if family.forecast.state >= .warming {
            evidence.append("Forecast is still collecting evidence")
        }
        if let cwd = family.forensics.currentDirectory {
            evidence.append("cwd \(cwd)")
        }
        self.evidence = Array(evidence.prefix(5))

        switch classification.kind {
        case .nodeServer:
            likelyCause = hasCredibleEscalation ? "Node dev server is trending toward a leak" : (family.trend.memoryVelocityMegabytesPerMinute > 0 ? "Node dev server or watcher memory growth" : "JavaScript dev server consuming resources")
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if this server is stale." : "Inspect tree and stop the owning terminal/app.")
        case .electronApp:
            likelyCause = hasCredibleForecast ? "Electron helper tree is heating up before a hard threshold" : (family.childCount >= 4 ? "Electron renderer/helper fanout" : "Electron app helper using memory")
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect renderer tree and close or restart the owning app."
        case .pythonService:
            likelyCause = "Python service, notebook, or worker process is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.trend.memoryVelocityMegabytesPerMinute > 0 ? "Inspect cwd and restart the service before it crosses the threshold." : "Inspect command and stop it from its terminal if expected.")
        case .dockerHelper:
            likelyCause = "Container or VM helper is backing a dev workload"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect ports and project path, then stop the compose/VM workload if stale."
        case .localModelRunner:
            likelyCause = "Local model runner has a large resident footprint"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect model command and unload or restart the runner when idle."
        case .javaServer:
            likelyCause = "JVM build or server process is holding memory"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect command and restart the Gradle/Maven/server process if stale."
        case .rubyServer:
            likelyCause = "Ruby/Rails service is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect cwd and stop the server if the project is no longer in use."
        case .swiftBuild:
            likelyCause = "Swift build toolchain work is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Let active builds finish; kill only stale compiler trees."
        case .goService:
            likelyCause = "Go compiler or backend service is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect ports and Kill Tree if the backend service is stale." : "Inspect running Go binary or live-reloading watcher.")
        case .rustService:
            likelyCause = "Rust build target or active server process is running"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command and Kill Tree if target binary is orphaned." : "Let Cargo compilation complete or restart active server.")
        case .bunServer:
            likelyCause = "Bun server runtime is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if the Bun server is stale." : "Inspect process tree and stop the server.")
        case .denoServer:
            likelyCause = "Deno secure JavaScript runtime is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if Deno server is stale." : "Inspect process and stop it via terminal.")
        case .phpService:
            likelyCause = "PHP service, Laravel server, or composer background task is running"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect cwd and Kill Tree if PHP/Artisan command is orphaned." : "Stop the artisan server or PHP-FPM process manually.")
        case .elixirService:
            likelyCause = "Elixir/Phoenix backend service or mix build is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect and Kill Tree if Phoenix server is orphaned." : "Stop the mix server or IEx session.")
        case .dotnetService:
            likelyCause = ".NET service, dotnet watch reloader, or build target is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if dotnet reloader is stale." : "Terminate the active dotnet session or reload server.")
        case .cliTool:
            likelyCause = "Developer CLI process is still running in the background"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect and Kill Tree if this command is stale." : "Inspect owner before taking action.")
        case .unknownHeavy:
            if let signal = family.hardwareSignals.first {
                likelyCause = "Unclassified process is creating \(signal.kind.label.lowercased())"
                nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect owner, path, and open resources before deciding whether to kill."
            } else {
                likelyCause = "Unknown heavy process crossed radar heuristics"
                nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect path, ports, and owner before deciding whether to kill."
            }
        }
    }

    private static func repoHint(for family: ProcessFamily) -> String? {
        if let cwd = family.forensics.currentDirectory, !cwd.isEmpty {
            return cwd
        }
        let command = family.root.commandLine
        for marker in ["package.json", "Package.swift", "manage.py", "Cargo.toml", "pom.xml", "build.gradle"] where command.contains(marker) {
            return marker
        }
        let path = family.root.executablePath
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
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
