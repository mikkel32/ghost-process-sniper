import Darwin
import Foundation

public enum ProcessSamplerError: Error, LocalizedError {
    case listFailed

    public var errorDescription: String? {
        switch self {
        case .listFailed:
            return "Unable to list processes with libproc."
        }
    }
}

public protocol ProcessSampling: Sendable {
    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch
}

public extension ProcessSampling {
    func sample() async throws -> [ProcessMetrics] {
        try await sample(plan: .balanced()).processes
    }
}

/// Every tick measures CPU and memory for each readable process, then spends
/// the tick deadline on telemetry, forensics and task info, most wanted first.
public actor NativeProcessSampler: ProcessSampling {
    private let source: any ProcessProbeSource
    private var cpuTracker = CPUUsageTracker<ProcessIdentity>()
    private var telemetryCache = ProcessTelemetryCache()
    private var forensicsCache = ForensicsCache()
    private var scanCache = ProcessScanCache()
    private var gpuUsageTracker = ProcessGPUUsageTracker()
    private var nameHints = DeveloperNameHints()
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)
    /// Reused buffers. A tick takes them for its whole run, so a reentrant
    /// call during an await starts from empty buffers instead of sharing.
    private var scratch: SamplerTick?
    private var lastCachePruneDate: Date?
    private var probePass: UInt64 = 0
    private var completedSampleCount = 0

    public init() {
        source = NativeProcessProbeSource()
    }

    init(source: any ProcessProbeSource) {
        self.source = source
    }

    public func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        let now = plan.sampledAt
        let startedAt = source.now()
        var tick = scratch.take() ?? SamplerTick()
        tick.reset(deadline: TickDeadline(startedAt: startedAt,
            budgetMilliseconds: plan.scannerBudget.targetMilliseconds + plan.scannerBudget.optionalMilliseconds))
        if tick.reused { tick.counters.scratchpadReuseCount += 1 }

        let pidCount = try source.listPIDs(into: &pidBuffer)
        tick.counters.expensiveCallCount += 1
        tick.counters.scannerWorkerCount = pidCount > 0 ? 1 : 0
        let pass = probePass
        probePass &+= 1
        let probe = ProcessProbeReader.read(pidBuffer, count: pidCount, plan: plan, source: source,
            deadline: tick.deadline, pass: pass, known: scanCache, hints: &nameHints,
            samples: &tick.rawSamples, priorities: &tick.rawPriorities)
        tick.counters.record(probe)

        tick.samples.reserveCapacity(tick.rawSamples.count)
        for raw in tick.rawSamples {
            var sample = measure(raw, counters: &tick.counters)
            sample.telemetry = cachedTelemetry(for: raw, sampleIndex: tick.samples.count, plan: plan, tick: &tick)
            sample.forensics = cachedForensics(for: raw, sampleIndex: tick.samples.count, plan: plan, tick: &tick)
            tick.samples.append(sample)
        }
        for index in tick.samples.indices {
            let identity = tick.samples[index].identity
            tick.identitiesByPID[identity.pid] = identity
            tick.indexByIdentity[identity] = index
        }
        let gpuSnapshot = gpuUsageTracker.sample(now: now, minimumInterval: Self.gpuRefreshInterval(for: plan.performanceMode),
                                                 identitiesByPID: tick.identitiesByPID)

        // Cold start and big backlogs get a one-off allowance so paths and argv
        // fill in within a few ticks instead of minutes.
        if !plan.telemetryDisabled, completedSampleCount < 3 || tick.telemetryJobs.count > 64 {
            tick.deadline.budgetMilliseconds += Self.backlogAllowanceMilliseconds
        }
        if !plan.telemetryDisabled {
            runPathLane(now: now, tick: &tick)
        }
        let refreshed = await runForensicsJobs(plan: plan, now: now, tick: &tick)
        runPortCensus(plan: plan, now: now, refreshed: refreshed, tick: &tick)
        if !plan.telemetryDisabled {
            await runArgumentLane(plan: plan, now: now, tick: &tick)
        }

        var processes: [ProcessMetrics] = []
        processes.reserveCapacity(tick.samples.count)
        for sample in tick.samples {
            let telemetry = sample.telemetry
                ?? .placeholder(name: sample.name, ownerName: UserNameResolver.name(for: sample.userID))
            let process = ProcessMetrics(
                identity: sample.identity,
                parentPID: sample.parentPID,
                userID: sample.userID,
                ownerName: telemetry.ownerName,
                name: telemetry.name,
                executablePath: telemetry.executablePath,
                commandLine: telemetry.commandLine,
                residentMemoryBytes: sample.residentMemoryBytes,
                physicalFootprintBytes: sample.physicalFootprintBytes,
                virtualMemoryBytes: sample.virtualMemoryBytes,
                cpuPercent: sample.cpu,
                gpuUsagePercent: gpuSnapshot.percentByPID[sample.identity.pid] ?? 0,
                totalProcessorSeconds: sample.totalProcessorSeconds,
                threadCount: sample.threadCount,
                isSystemProcess: sample.isSystemProcess,
                sampledAt: now,
                forensics: sample.forensics ?? .unavailable(reason: "forensics deferred"),
                measurementStatus: sample.measurementStatus,
                cpuMeasurementStatus: sample.cpuMeasurementStatus,
                gpuMeasurementStatus: gpuSnapshot.measuredAtByPID[sample.identity.pid]
                    .map { $0 == now ? .fresh : .cached($0) } ?? .unavailable,
                session: sample.session
            )
            scanCache.update(ProcessRecord(identity: sample.identity, process: process,
                telemetryRefreshedAt: telemetry.isPlaceholder ? .distantPast : telemetry.refreshedAt))
            processes.append(process)
        }

        let tickComplete = !tick.counters.didHitDeadline && tick.counters.skippedPIDCount == 0
        if shouldPruneCaches(now: now, processCount: processes.count, tickComplete: tickComplete) {
            let identities = Set(processes.map(\.identity))
            cpuTracker.prune(keeping: identities)
            telemetryCache.prune(keeping: identities)
            forensicsCache.prune(keeping: identities)
            scanCache.prune(keeping: identities)
            nameHints.prune(keeping: Set(tick.rawSamples.map(\.kernelName)))
            lastCachePruneDate = now
        } else {
            tick.counters.skippedOptionalWorkCount += 1
        }

        let elapsed = tick.deadline.elapsedMilliseconds(at: source.now())
        tick.counters.didHitDeadline = tick.counters.didHitDeadline || elapsed >= tick.deadline.budgetMilliseconds
        let stats = tick.counters.stats(processCount: processes.count, elapsedMilliseconds: elapsed)
        completedSampleCount += 1
        scratch = tick

        return ProcessSampleBatch(
            processes: processes,
            sampledAt: now,
            stats: stats,
            scannerHealth: ScannerHealthSnapshot(stats: stats, budget: plan.scannerBudget)
        )
    }

    // MARK: - CPU and memory

    private func measure(_ raw: RawProcessSample, counters: inout SamplingCounters) -> ActiveProcessSample {
        let lite = raw.liteRecord
        let identity = lite.identity
        let cached = scanCache.record(for: identity)?.process
        var cpu = cached?.cpuPercent ?? 0
        var cpuStatus: ProcessMeasurementStatus = cached?.cpuMeasurementDate.map { .cached($0) } ?? .unavailable
        var usage = raw.usage
        if let reading = usage {
            switch cpuTracker.reading(key: identity, processorSeconds: reading.cpuSeconds,
                                      uptimeNanoseconds: reading.sampledAtUptimeNanoseconds,
                                      startStamp: reading.processStartAbsoluteTime) {
            case .percent(let percent):
                cpu = percent
                cpuStatus = .fresh
            case .startMismatch:
                // The pid was reused between the BSD and usage reads.
                usage = nil
                counters.usageReadCount -= 1
                counters.usageFailedCount += 1
            case .baseline, .invalid:
                break
            }
        }

        let threadCount = raw.task?.threadCount ?? cached?.threadCount ?? 0
        let virtualBytes = raw.task?.virtualBytes ?? cached?.virtualMemoryBytes ?? 0
        if usage == nil, cached != nil { counters.reusedRecordCount += 1 }
        return ActiveProcessSample(
            identity: identity,
            measurementStatus: usage != nil ? .fresh : cached?.measurementDate.map { .cached($0) } ?? .unavailable,
            cpuMeasurementStatus: cpuStatus,
            parentPID: lite.parentPID,
            userID: lite.userID,
            name: lite.name,
            openFileCount: lite.openFileCount,
            residentMemoryBytes: usage?.residentBytes ?? cached?.residentMemoryBytes ?? 0,
            physicalFootprintBytes: usage?.physicalFootprintBytes ?? cached?.physicalFootprintBytes ?? 0,
            virtualMemoryBytes: virtualBytes,
            threadCount: threadCount,
            isSystemProcess: lite.isSystemProcess,
            totalProcessorSeconds: usage?.cpuSeconds ?? cached?.totalProcessorSeconds ?? 0,
            cpu: cpu,
            isPriority: raw.priority > 0,
            // The session never changes after setsid, so getsid runs once per
            // identity and later passes reuse the cached value.
            session: lite.session(sessionID: cached?.sessionID ?? source.sessionID(raw.pid))
        )
    }

    // MARK: - Telemetry

    private func cachedTelemetry(for raw: RawProcessSample, sampleIndex: Int, plan: SamplingPlan,
                                 tick: inout SamplerTick) -> ProcessTelemetryCache.Entry? {
        let identity = raw.liteRecord.identity
        var entry = telemetryCache.entry(for: identity)
        var rank = raw.priority
        if let old = entry, !old.kernelName.isEmpty, !raw.kernelName.isEmpty, old.kernelName != raw.kernelName {
            // Identity survives exec; a new kernel name is the cheap signal that
            // the path, argv and working directory all changed.
            telemetryCache.remove(identity)
            forensicsCache.remove(identity)
            entry = nil
            rank = 3
        }
        if let entry, entry.argumentsRead, !scanCache.shouldRefreshTelemetry(
            identity: identity,
            now: plan.sampledAt,
            maxAge: plan.commandRefreshInterval,
            grace: plan.scannerBudget.staleTelemetryGrace,
            isPriority: raw.priority > 0
        ) {
            tick.counters.commandCacheHitCount += 1
            tick.counters.count(.telemetryCache)
            return entry
        }
        tick.telemetryJobs.append(TelemetryJob(
            pid: raw.pid, identity: identity, sampleIndex: sampleIndex, userID: raw.liteRecord.userID,
            kernelName: raw.kernelName, priorityRank: rank, needsPath: entry == nil,
            neverRead: entry?.argumentsRead != true, refreshedAt: entry?.refreshedAt ?? .distantPast,
            executablePath: entry?.executablePath ?? ""))
        // A real entry keeps serving until the argv lane gets to it.
        return entry
    }

    /// Paths are cheap and decide app and bundle recognition, so every
    /// identity without one gets it this tick, deadline permitting.
    private func runPathLane(now: Date, tick: inout SamplerTick) {
        for index in tick.telemetryJobs.indices where tick.telemetryJobs[index].needsPath {
            if tick.deadline.isExpired(at: source.now()) {
                tick.counters.didHitDeadline = true
                return
            }
            let job = tick.telemetryJobs[index]
            let path = source.executablePath(job.pid)
            tick.counters.expensiveCallCount += 1
            let entry = SamplerJobs.entry(for: job, path: path, arguments: nil, argumentsRead: false, now: now)
            telemetryCache.update(entry, for: job.identity)
            tick.samples[job.sampleIndex].telemetry = entry
            tick.telemetryJobs[index].needsPath = false
            tick.telemetryJobs[index].executablePath = path
        }
    }

    /// argv runs most wanted first while the deadline allows, and never fewer
    /// than the budget's telemetry floor.
    private func runArgumentLane(plan: SamplingPlan, now: Date, tick: inout SamplerTick) async {
        guard !tick.telemetryJobs.isEmpty else { return }
        tick.telemetryJobs.sort(by: SamplerJobs.argumentOrder)
        let jobs = tick.telemetryJobs
        let floor = plan.scannerBudget.maxTelemetryRefreshes
        // Fan out only when someone is watching and the queue is long enough
        // to repay the task-group overhead; otherwise stay on the actor.
        let parallel = plan.uiVisible && jobs.count > Self.sequentialJobLimit
        let batchSize = parallel ? Self.maxParallelJobCount(for: plan.performanceMode) : 1
        if !parallel { tick.counters.tinyQueueSequentialCount += 1 }
        var next = 0
        while next < jobs.count, next < floor || !tick.deadline.isExpired(at: source.now()) {
            let end = min(jobs.count, next + batchSize)
            if parallel {
                tick.counters.scannerTaskCount += end - next
                for result in await SamplerJobs.readArguments(jobs[next..<end], source: source, now: now) {
                    apply(result, tick: &tick)
                }
            } else {
                apply(SamplerJobs.readArguments(jobs[next], source: source, now: now), tick: &tick)
            }
            next = end
        }
        let deferred = jobs.count - next
        if deferred > 0 {
            tick.counters.didHitDeadline = true
            tick.counters.telemetryDeferredCount += deferred
            tick.counters.skippedOptionalWorkCount += deferred
            tick.counters.count(.deadlineSkipped, by: deferred)
        }
    }

    private func apply(_ result: TelemetryResult, tick: inout SamplerTick) {
        telemetryCache.update(result.entry, for: result.job.identity)
        tick.samples[result.job.sampleIndex].telemetry = result.entry
        tick.counters.commandRefreshCount += 1
        tick.counters.expensiveCallCount += result.job.needsPath ? 3 : 2
        tick.counters.count(.telemetryRefresh)
    }

    // MARK: - Forensics

    private func cachedForensics(for raw: RawProcessSample, sampleIndex: Int, plan: SamplingPlan,
                                 tick: inout SamplerTick) -> ProcessForensics? {
        let identity = raw.liteRecord.identity
        let now = plan.sampledAt
        let isPriority = raw.priority > 0
        let entry = forensicsCache.entry(for: identity)
        if let entry, !entry.isPortsOnly, now.timeIntervalSince(entry.refreshedAt) <= Self.freshForensicsAge {
            tick.counters.forensicsCacheHitCount += 1
            tick.counters.count(.forensicsCache)
            return entry.forensics
        }
        if let negative = forensicsCache.negativeEntry(for: identity, now: now,
                                                       maxAge: plan.scannerBudget.negativeForensicsTTL) {
            tick.counters.forensicsNegativeCacheHitCount += 1
            tick.counters.count(.forensicsCache)
            return negative.forensics
        }
        guard isPriority else {
            // Quiet processes keep what is known, so their ports stay searchable.
            if let entry, entry.isPortsOnly || !entry.forensics.isPartial,
               now.timeIntervalSince(entry.portsRefreshedAt) <= Self.quietForensicsMaxAge {
                tick.counters.forensicsCacheHitCount += 1
                tick.counters.count(.forensicsCache)
                return entry.forensics
            }
            tick.counters.forensicsDeferredCount += 1
            tick.counters.skippedOptionalWorkCount += 1
            return .unavailable(reason: "forensics deferred for quiet process")
        }
        if tick.deadline.isExpired(at: source.now()) {
            tick.counters.didHitDeadline = true
            tick.counters.forensicsDeferredCount += 1
            tick.counters.count(.deadlineSkipped)
            return entry?.forensics ?? .unavailable(reason: "forensics deferred by scanner deadline")
        }
        // Stale-while-revalidate: a server that bound its port after the last
        // read gets re-read instead of showing "no ports" for its whole life.
        tick.forensicsJobs.append(ForensicsJob(pid: raw.pid, identity: identity, sampleIndex: sampleIndex,
            neverRead: entry == nil || entry?.isPortsOnly == true, refreshedAt: entry?.refreshedAt ?? .distantPast))
        return entry?.forensics
    }

    /// Returns the sample indices that got a full forensics read.
    private func runForensicsJobs(plan: SamplingPlan, now: Date, tick: inout SamplerTick) async -> Set<Int> {
        guard !tick.forensicsJobs.isEmpty else { return [] }
        tick.forensicsJobs.sort(by: SamplerJobs.forensicsOrder)
        var accepted: [ForensicsJob] = []
        for job in tick.forensicsJobs {
            let wanted = plan.allowsOptionalForensics && accepted.count < plan.maxForensicsPerRefresh &&
                (plan.includeForensicsFor.contains(job.identity) || plan.includeForensicsForPIDs.contains(job.pid))
            let reason: String
            if !wanted {
                reason = plan.allowsOptionalForensics ? "forensics deferred" : "forensics paused under system pressure"
            } else if tick.deadline.isExpired(at: source.now()) {
                tick.counters.didHitDeadline = true
                tick.counters.count(.deadlineSkipped)
                reason = "forensics deferred by scanner deadline"
            } else {
                accepted.append(job)
                continue
            }
            tick.counters.forensicsDeferredCount += 1
            tick.counters.skippedOptionalWorkCount += 1
            if tick.samples[job.sampleIndex].forensics == nil {
                tick.samples[job.sampleIndex].forensics = .unavailable(reason: reason)
            }
        }

        let results: [ForensicsResult]
        if plan.uiVisible, accepted.count > Self.sequentialJobLimit {
            tick.counters.scannerTaskCount += accepted.count
            results = await SamplerJobs.readForensics(accepted[...], source: source)
        } else {
            if !accepted.isEmpty { tick.counters.tinyQueueSequentialCount += 1 }
            results = accepted.map { SamplerJobs.readForensics($0, source: source) }
        }
        var refreshed = Set<Int>()
        for result in results {
            forensicsCache.update(result.forensics, for: result.job.identity, at: now)
            tick.samples[result.job.sampleIndex].forensics = result.forensics
            tick.counters.forensicsRefreshCount += 1
            tick.counters.expensiveCallCount += result.expensiveCallCount
            tick.counters.count(.forensicsQueue)
            refreshed.insert(result.job.sampleIndex)
        }
        return refreshed
    }

    /// Listening ports only: no cwd, no vnode reads. Background census covers
    /// the few quiet developer processes the plan names; an explicit request
    /// covers every same-user process with open files, under its own cap.
    private func runPortCensus(plan: SamplingPlan, now: Date, refreshed: Set<Int>, tick: inout SamplerTick) {
        if plan.portCensusAll {
            let cap = TickDeadline(startedAt: source.now(), budgetMilliseconds: Self.fullCensusMilliseconds)
            let user = source.effectiveUserID
            for index in tick.samples.indices where !refreshed.contains(index) {
                guard tick.samples[index].userID == user, tick.samples[index].openFileCount > 0 else { continue }
                if cap.isExpired(at: source.now()) {
                    tick.counters.didHitDeadline = true
                    return
                }
                censusPorts(at: index, now: now, tick: &tick)
            }
            return
        }
        guard plan.allowsOptionalForensics else { return }
        var remaining = plan.maxForensicsPerRefresh
        for identity in plan.portCensusIdentities where remaining > 0 {
            guard let index = tick.indexByIdentity[identity], !refreshed.contains(index) else { continue }
            if tick.deadline.isExpired(at: source.now()) {
                tick.counters.didHitDeadline = true
                return
            }
            censusPorts(at: index, now: now, tick: &tick)
            remaining -= 1
        }
    }

    private func censusPorts(at index: Int, now: Date, tick: inout SamplerTick) {
        let identity = tick.samples[index].identity
        tick.counters.expensiveCallCount += 1
        guard let ports = source.listeningPorts(identity.pid) else { return }
        tick.samples[index].forensics = forensicsCache.mergePorts(ports, for: identity, at: now)
        tick.counters.portCensusCount += 1
    }

    // MARK: - Policy

    private static let sequentialJobLimit = 8
    private static let backlogAllowanceMilliseconds = 30.0
    private static let fullCensusMilliseconds = 40.0
    private static let freshForensicsAge: TimeInterval = 60
    private static let quietForensicsMaxAge: TimeInterval = 600
    /// Deadline ticks skip pruning, but a machine that always hits the
    /// deadline must still shed exited identities.
    private static let forcedPruneInterval: TimeInterval = 60

    nonisolated private static func maxParallelJobCount(for mode: RadarPerformanceMode) -> Int {
        switch mode {
        case .batterySaver: 3
        case .balanced: 4
        case .realtime: 8
        }
    }

    nonisolated private static func gpuRefreshInterval(for mode: RadarPerformanceMode) -> TimeInterval {
        switch mode {
        case .batterySaver: 15
        case .balanced: 8
        case .realtime: 2
        }
    }

    private func shouldPruneCaches(now: Date, processCount: Int, tickComplete: Bool) -> Bool {
        guard processCount > 0, let lastCachePruneDate else {
            return true
        }
        let elapsed = now.timeIntervalSince(lastCachePruneDate)
        guard tickComplete else {
            return elapsed >= Self.forcedPruneInterval
        }
        return elapsed >= (processCount > 2_000 ? 5 : 10)
    }
}
