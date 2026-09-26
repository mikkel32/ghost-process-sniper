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

struct RawProcessSample: Sendable {
    let pid: pid_t
    let liteRecord: ProcessLiteRecord
    let taskInfo: proc_taskallinfo?
    let usage: rusage_info_v4?
    let preliminaryPriority: Bool
}

struct ParallelProbeResult: Sendable {
    let samples: [RawProcessSample]
    let cheapMetricsCount: Int
    let richMetricsCount: Int
    let skippedCount: Int
    let expensiveCallCount: Int
    let bsdReadCount: Int
    let taskInfoReadCount: Int
    let didHitDeadline: Bool
}

struct TelemetryJob: Sendable {
    let pid: pid_t
    let identity: ProcessIdentity
    let userID: UInt32
    let priorityRank: Int
}

struct ForensicsJob: Sendable {
    let pid: pid_t
    let identity: ProcessIdentity
    let priorityRank: Int
}

struct TelemetryResult: Sendable {
    let identity: ProcessIdentity
    let entry: ProcessTelemetryCache.Entry
}

struct ForensicsResult: Sendable {
    let identity: ProcessIdentity
    let forensics: ProcessForensics
    let expensiveCallCount: Int
}

public actor NativeProcessSampler: ProcessSampling {
    private var cpuTracker = CPUUsageTracker<ProcessIdentity>()
    private var telemetryCache = ProcessTelemetryCache()
    private var forensicsCache = ForensicsCache()
    private var scanCache = ProcessScanCache()
    private var gpuUsageTracker = ProcessGPUUsageTracker()
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)
    private var telemetryJobsScratch: [TelemetryJob] = []
    private var forensicsJobsScratch: [ForensicsJob] = []
    private var lastCachePruneDate: Date?
    private var probePass: UInt64 = 0

    public init() {}

    public func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        let now = plan.sampledAt
        let start = Date()
        let deadline = SamplerDeadline(
            startedAt: start,
            budgetMilliseconds: plan.scannerBudget.targetMilliseconds + plan.scannerBudget.optionalMilliseconds
        )
        var counters = SamplingCounters()
        let pidCount = try listPIDCount(counters: &counters)
        let pass = probePass
        probePass &+= 1
        counters.scannerWorkerCount = pidCount > 0 ? 1 : 0
        // One pass on the actor. BSD reads cost microseconds per PID, and
        // chunking the list across tasks split the rich budget evenly per
        // chunk, starving focused PIDs that happened to share a chunk.
        let probe = ProcessProbeReader.read(
            pidBuffer,
            startIndex: 0,
            endIndex: pidCount,
            plan: plan,
            deadline: deadline,
            pass: pass,
            budget: plan.metricsEnrichmentBudget
        )
        counters.skippedPIDCount += probe.skippedCount
        counters.expensiveCallCount += probe.expensiveCallCount
        counters.richMetricRefreshCount += probe.richMetricsCount
        counters.bsdReadCount += probe.bsdReadCount
        counters.taskInfoReadCount += probe.taskInfoReadCount
        counters.count(.cheapMetrics, by: probe.cheapMetricsCount)
        counters.count(.richMetrics, by: probe.richMetricsCount)
        if probe.didHitDeadline {
            counters.didHitDeadline = true
            counters.count(.deadlineSkipped, by: probe.skippedCount)
        }

        var activeSamples: [ActiveProcessSample] = []
        counters.scratchpadReuseCount += 1
        telemetryJobsScratch.removeAll(keepingCapacity: true)
        forensicsJobsScratch.removeAll(keepingCapacity: true)
        telemetryJobsScratch.reserveCapacity(min(pidCount, plan.scannerBudget.maxTelemetryRefreshes * 2))
        forensicsJobsScratch.reserveCapacity(min(pidCount, plan.maxForensicsPerRefresh * 2 + 8))

        for rawSample in probe.samples {
            let pid = rawSample.pid
            let liteRecord = rawSample.liteRecord
            let taskInfo = rawSample.taskInfo
            let usage = rawSample.usage
            let preliminaryPriority = rawSample.preliminaryPriority

            let identity = liteRecord.identity
            let cachedRecord = scanCache.record(for: identity)
            let totalProcessorSeconds: TimeInterval
            let cpu: Double
            let cpuMeasurementStatus: ProcessMeasurementStatus
            let residentMemoryBytes: UInt64
            let physicalFootprintBytes: UInt64
            let virtualMemoryBytes: UInt64
            let threadCount: Int
            let isSystemProcess: Bool

            if let taskInfo {
                totalProcessorSeconds = processorSeconds(taskInfo: taskInfo, usage: usage)
                let measuredCPU = cpuTracker.percent(
                    key: identity,
                    totalProcessorSeconds: totalProcessorSeconds,
                    wallClock: now
                )
                if let measuredCPU, measuredCPU.isFinite, measuredCPU >= 0 {
                    cpu = measuredCPU
                    cpuMeasurementStatus = .fresh
                } else if let cachedDate = cachedRecord?.process.cpuMeasurementDate {
                    cpu = cachedRecord?.process.cpuPercent ?? 0
                    cpuMeasurementStatus = .cached(cachedDate)
                } else {
                    cpu = 0
                    cpuMeasurementStatus = .unavailable
                }
                residentMemoryBytes = usage?.ri_resident_size ?? taskInfo.ptinfo.pti_resident_size
                physicalFootprintBytes = usage?.ri_phys_footprint ?? taskInfo.ptinfo.pti_resident_size
                virtualMemoryBytes = taskInfo.ptinfo.pti_virtual_size
                threadCount = Int(taskInfo.ptinfo.pti_threadnum)
                isSystemProcess = (taskInfo.pbsd.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0
            } else if let cached = cachedRecord {
                counters.reusedRecordCount += 1
                totalProcessorSeconds = cached.process.totalProcessorSeconds
                cpu = cached.process.cpuPercent
                cpuMeasurementStatus = cached.process.cpuMeasurementDate.map { .cached($0) } ?? .unavailable
                residentMemoryBytes = cached.process.residentMemoryBytes
                physicalFootprintBytes = cached.process.physicalFootprintBytes
                virtualMemoryBytes = cached.process.virtualMemoryBytes
                threadCount = cached.process.threadCount
                isSystemProcess = liteRecord.isSystemProcess
            } else {
                totalProcessorSeconds = 0
                cpu = 0
                cpuMeasurementStatus = .unavailable
                residentMemoryBytes = 0
                physicalFootprintBytes = 0
                virtualMemoryBytes = 0
                threadCount = 0
                isSystemProcess = liteRecord.isSystemProcess
            }

            let isPriority = preliminaryPriority

            var sampleItem = ActiveProcessSample(
                identity: identity,
                measurementStatus: taskInfo != nil ? .fresh : cachedRecord?.process.measurementDate.map { .cached($0) } ?? .unavailable,
                cpuMeasurementStatus: cpuMeasurementStatus,
                parentPID: liteRecord.parentPID,
                userID: liteRecord.userID,
                residentMemoryBytes: residentMemoryBytes,
                physicalFootprintBytes: physicalFootprintBytes,
                virtualMemoryBytes: virtualMemoryBytes,
                threadCount: threadCount,
                isSystemProcess: isSystemProcess,
                totalProcessorSeconds: totalProcessorSeconds,
                cpu: cpu,
                isPriority: isPriority,
                telemetry: nil,
                forensics: nil
            )

            // TELEMETRY CACHE CHECK
            if !scanCache.shouldRefreshTelemetry(
                identity: identity,
                now: now,
                maxAge: plan.commandRefreshInterval,
                grace: plan.scannerBudget.staleTelemetryGrace,
                isPriority: isPriority,
                force: plan.forceCommandRefresh
            ),
               let cached = telemetryCache.entry(for: identity) {
                counters.commandCacheHitCount += 1
                counters.count(.telemetryCache)
                sampleItem.telemetry = cached
            } else if rawSample.taskInfo == nil,
                      let cached = cachedRecord,
                      !plan.forceCommandRefresh {
                counters.commandCacheHitCount += 1
                counters.count(.telemetryCache)
                sampleItem.telemetry = ProcessTelemetryCache.Entry(
                    name: cached.process.name,
                    executablePath: cached.process.executablePath,
                    commandLine: cached.process.commandLine,
                    ownerName: cached.process.ownerName,
                    refreshedAt: cached.telemetryRefreshedAt
                )
            } else {
                telemetryJobsScratch.append(TelemetryJob(pid: pid, identity: identity, userID: liteRecord.userID, priorityRank: isPriority ? 2 : 0))
            }

            // FORENSICS CACHE CHECK
            if let cached = forensicsCache.entry(for: identity, now: now, maxAge: 60) {
                counters.forensicsCacheHitCount += 1
                counters.count(.forensicsCache)
                sampleItem.forensics = cached.forensics
            } else if let negative = forensicsCache.negativeEntry(
                for: identity,
                now: now,
                maxAge: plan.scannerBudget.negativeForensicsTTL
            ) {
                counters.forensicsNegativeCacheHitCount += 1
                counters.count(.forensicsCache)
                sampleItem.forensics = negative.forensics
            } else if !isPriority {
                counters.forensicsDeferredCount += 1
                counters.skippedOptionalWorkCount += 1
                sampleItem.forensics = .unavailable(reason: "forensics deferred for quiet process")
            } else if deadline.isExpired() {
                counters.didHitDeadline = true
                counters.forensicsDeferredCount += 1
                counters.count(.deadlineSkipped)
                sampleItem.forensics = .unavailable(reason: "forensics deferred by scanner deadline")
            } else if let cached = forensicsCache.entry(for: identity) {
                counters.forensicsCacheHitCount += 1
                counters.count(.forensicsCache)
                sampleItem.forensics = cached.forensics
            } else {
                forensicsJobsScratch.append(ForensicsJob(pid: pid, identity: identity, priorityRank: isPriority ? 2 : 0))
            }

            activeSamples.append(sampleItem)
        }

        var identitiesByPID: [Int32: ProcessIdentity] = [:]
        identitiesByPID.reserveCapacity(activeSamples.count)
        for sample in activeSamples { identitiesByPID[sample.identity.pid] = sample.identity }
        let gpuSnapshot = gpuUsageTracker.sample(
            now: now,
            minimumInterval: Self.gpuRefreshInterval(for: plan.performanceMode),
            identitiesByPID: identitiesByPID
        )

        let activeIndexByIdentity = Dictionary(
            uniqueKeysWithValues: activeSamples.enumerated().map { ($0.element.identity, $0.offset) }
        )

        var activeTelemetryJobs: [TelemetryJob] = []
        var activeForensicsJobs: [ForensicsJob] = []

        // Telemetry Queue Filtering
        telemetryJobsScratch.sort { $0.priorityRank > $1.priorityRank }
        for job in telemetryJobsScratch {
            if deadline.isExpired() || counters.commandRefreshCount >= plan.scannerBudget.maxTelemetryRefreshes {
                counters.telemetryDeferredCount += 1
                counters.skippedOptionalWorkCount += 1
                counters.didHitDeadline = counters.didHitDeadline || deadline.isExpired()
                counters.count(.deadlineSkipped)

                if let index = activeIndexByIdentity[job.identity] {
                    if let cached = telemetryCache.entry(for: job.identity) {
                        counters.commandCacheHitCount += 1
                        activeSamples[index].telemetry = cached
                    } else {
                        let name = processName(for: job.pid, fallbackPath: "")
                        activeSamples[index].telemetry = ProcessTelemetryCache.Entry(
                            name: name,
                            executablePath: "",
                            commandLine: name,
                            ownerName: UserNameResolver.name(for: job.userID),
                            refreshedAt: now
                        )
                    }
                }
            } else {
                activeTelemetryJobs.append(job)
                counters.commandRefreshCount += 1
            }
        }

        // Forensics Queue Filtering
        forensicsJobsScratch.sort { $0.priorityRank > $1.priorityRank }
        for job in forensicsJobsScratch {
            let shouldRefresh = plan.allowsOptionalForensics &&
                counters.forensicsRefreshCount < plan.maxForensicsPerRefresh &&
                (plan.includeForensicsFor.contains(job.identity) || plan.includeForensicsForPIDs.contains(job.pid))

            if !shouldRefresh {
                counters.forensicsDeferredCount += 1
                counters.skippedOptionalWorkCount += 1
                if let index = activeIndexByIdentity[job.identity] {
                    activeSamples[index].forensics = .unavailable(
                        reason: plan.allowsOptionalForensics ? "forensics deferred" : "forensics paused under system pressure"
                    )
                }
            } else if deadline.isExpired() {
                counters.didHitDeadline = true
                counters.forensicsDeferredCount += 1
                counters.skippedOptionalWorkCount += 1
                counters.count(.deadlineSkipped)
                if let index = activeIndexByIdentity[job.identity] {
                    activeSamples[index].forensics = .unavailable(reason: "forensics deferred by scanner deadline")
                }
            } else {
                activeForensicsJobs.append(job)
                counters.forensicsRefreshCount += 1
            }
        }

        // Fan out only when someone is watching and the queue is long enough
        // to repay the task-group overhead; otherwise stay on the actor.
        let telemetryResults: [TelemetryResult]
        if plan.uiVisible, activeTelemetryJobs.count > Self.sequentialJobLimit {
            telemetryResults = try await runTelemetryJobs(activeTelemetryJobs, now: now, counters: &counters, mode: plan.performanceMode)
        } else {
            if !activeTelemetryJobs.isEmpty { counters.tinyQueueSequentialCount += 1 }
            telemetryResults = activeTelemetryJobs.map { telemetryResult(for: $0, now: now) }
        }

        let forensicsResults: [ForensicsResult]
        if plan.uiVisible, activeForensicsJobs.count > Self.sequentialJobLimit {
            forensicsResults = try await runForensicsJobs(activeForensicsJobs, counters: &counters, mode: plan.performanceMode)
        } else {
            if !activeForensicsJobs.isEmpty { counters.tinyQueueSequentialCount += 1 }
            forensicsResults = activeForensicsJobs.map { forensicsResult(for: $0) }
        }

        // Ingest telemetry results back sequentially on the actor
        for result in telemetryResults {
            telemetryCache.update(result.entry, for: result.identity)
            counters.expensiveCallCount += 3
            counters.count(.telemetryRefresh)

            if let index = activeIndexByIdentity[result.identity] {
                activeSamples[index].telemetry = result.entry
            }
        }

        // Ingest forensics results back sequentially on the actor
        for result in forensicsResults {
            forensicsCache.update(result.forensics, for: result.identity, at: now)
            counters.expensiveCallCount += result.expensiveCallCount
            counters.count(.forensicsQueue)

            if let index = activeIndexByIdentity[result.identity] {
                activeSamples[index].forensics = result.forensics
            }
        }

        // Build ProcessMetrics and update scan cache
        var processes: [ProcessMetrics] = []
        processes.reserveCapacity(activeSamples.count)

        for sampleItem in activeSamples {
            let identity = sampleItem.identity
            let totalProcessorSeconds = sampleItem.totalProcessorSeconds
            let cpu = sampleItem.cpu
            let gpu = gpuSnapshot.percentByPID[sampleItem.identity.pid] ?? 0
            let gpuMeasurementStatus: ProcessMeasurementStatus = gpuSnapshot.measuredAtByPID[sampleItem.identity.pid]
                .map { $0 == now ? .fresh : .cached($0) } ?? .unavailable

            guard let telemetry = sampleItem.telemetry,
                  let forensics = sampleItem.forensics
            else {
                continue
            }

            let process = ProcessMetrics(
                identity: identity,
                parentPID: sampleItem.parentPID,
                userID: sampleItem.userID,
                ownerName: telemetry.ownerName,
                name: telemetry.name,
                executablePath: telemetry.executablePath,
                commandLine: telemetry.commandLine,
                residentMemoryBytes: sampleItem.residentMemoryBytes,
                physicalFootprintBytes: sampleItem.physicalFootprintBytes,
                virtualMemoryBytes: sampleItem.virtualMemoryBytes,
                cpuPercent: cpu,
                gpuUsagePercent: gpu,
                totalProcessorSeconds: totalProcessorSeconds,
                threadCount: sampleItem.threadCount,
                isSystemProcess: sampleItem.isSystemProcess,
                sampledAt: now,
                forensics: forensics,
                measurementStatus: sampleItem.measurementStatus,
                cpuMeasurementStatus: sampleItem.cpuMeasurementStatus,
                gpuMeasurementStatus: gpuMeasurementStatus
            )

            scanCache.update(ProcessRecord(identity: identity, process: process, telemetryRefreshedAt: telemetry.refreshedAt))
            processes.append(process)
        }

        if shouldPruneCaches(now: now, processCount: processes.count) {
            let identities = Set(processes.map(\.identity))
            cpuTracker.prune(keeping: identities)
            telemetryCache.prune(keeping: identities)
            forensicsCache.prune(keeping: identities)
            scanCache.prune(keeping: identities)
            lastCachePruneDate = now
        } else {
            counters.skippedOptionalWorkCount += 1
        }

        let elapsed = Date().timeIntervalSince(start) * 1_000
        counters.didHitDeadline = counters.didHitDeadline || elapsed >= deadline.budgetMilliseconds

        let stats = SamplerStats(
            processCount: processes.count,
            commandRefreshCount: counters.commandRefreshCount,
            commandCacheHitCount: counters.commandCacheHitCount,
            forensicsRefreshCount: counters.forensicsRefreshCount,
            forensicsDeferredCount: counters.forensicsDeferredCount,
            elapsedMilliseconds: elapsed,
            telemetryDeferredCount: counters.telemetryDeferredCount,
            forensicsCacheHitCount: counters.forensicsCacheHitCount,
            forensicsNegativeCacheHitCount: counters.forensicsNegativeCacheHitCount,
            skippedPIDCount: counters.skippedPIDCount,
            expensiveCallCount: counters.expensiveCallCount,
            richMetricRefreshCount: counters.richMetricRefreshCount,
            scannerWorkerCount: counters.scannerWorkerCount,
            skippedOptionalWorkCount: counters.skippedOptionalWorkCount,
            scannerTaskCount: counters.scannerTaskCount,
            tinyQueueSequentialCount: counters.tinyQueueSequentialCount,
            didHitDeadline: counters.didHitDeadline,
            laneCounts: counters.laneCounts,
            bsdReadCount: counters.bsdReadCount,
            taskInfoReadCount: counters.taskInfoReadCount,
            reusedRecordCount: counters.reusedRecordCount,
            pidBufferCopyCount: counters.pidBufferCopyCount,
            scratchpadReuseCount: counters.scratchpadReuseCount
        )

        return ProcessSampleBatch(
            processes: processes,
            sampledAt: now,
            stats: stats,
            scannerHealth: ScannerHealthSnapshot(stats: stats, budget: plan.scannerBudget)
        )
    }

    private func runTelemetryJobs(
        _ jobs: [TelemetryJob],
        now: Date,
        counters: inout SamplingCounters,
        mode: RadarPerformanceMode
    ) async throws -> [TelemetryResult] {
        let batchSize = Self.maxParallelJobCount(for: mode)
        var output: [TelemetryResult] = []
        output.reserveCapacity(jobs.count)
        var index = 0
        while index < jobs.count {
            let end = min(jobs.count, index + batchSize)
            counters.scannerTaskCount += end - index
            let results = try await withThrowingTaskGroup(of: TelemetryResult.self) { group in
                for jobIndex in index..<end {
                    let job = jobs[jobIndex]
                    group.addTask {
                        self.telemetryResult(for: job, now: now)
                    }
                }
                var batchResults: [TelemetryResult] = []
                batchResults.reserveCapacity(end - index)
                for try await result in group {
                    batchResults.append(result)
                }
                return batchResults
            }
            output.append(contentsOf: results)
            index = end
        }
        return output
    }

    private func runForensicsJobs(
        _ jobs: [ForensicsJob],
        counters: inout SamplingCounters,
        mode: RadarPerformanceMode
    ) async throws -> [ForensicsResult] {
        let batchSize = Self.maxParallelJobCount(for: mode)
        var output: [ForensicsResult] = []
        output.reserveCapacity(jobs.count)
        var index = 0
        while index < jobs.count {
            let end = min(jobs.count, index + batchSize)
            counters.scannerTaskCount += end - index
            let results = try await withThrowingTaskGroup(of: ForensicsResult.self) { group in
                for jobIndex in index..<end {
                    let job = jobs[jobIndex]
                    group.addTask {
                        self.forensicsResult(for: job)
                    }
                }
                var batchResults: [ForensicsResult] = []
                batchResults.reserveCapacity(end - index)
                for try await result in group {
                    batchResults.append(result)
                }
                return batchResults
            }
            output.append(contentsOf: results)
            index = end
        }
        return output
    }

    nonisolated private func telemetryResult(for job: TelemetryJob, now: Date) -> TelemetryResult {
        let executablePath = processPath(for: job.pid)
        let name = processName(for: job.pid, fallbackPath: executablePath)
        let command = commandLine(for: job.pid) ?? executablePath.ifNotEmpty ?? name
        let entry = ProcessTelemetryCache.Entry(
            name: name,
            executablePath: executablePath,
            commandLine: command,
            ownerName: UserNameResolver.name(for: job.userID),
            refreshedAt: now
        )
        return TelemetryResult(identity: job.identity, entry: entry)
    }

    nonisolated private func forensicsResult(for job: ForensicsJob) -> ForensicsResult {
        let info = forensics(for: job.pid)
        return ForensicsResult(identity: job.identity, forensics: info.forensics, expensiveCallCount: info.expensiveCallCount)
    }

    private static let sequentialJobLimit = 8

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

    private func listPIDCount(counters: inout SamplingCounters) throws -> Int {
        var bytesWritten = 0
        while true {
            let bufferSize = pidBuffer.count * MemoryLayout<pid_t>.stride
            bytesWritten = Int(pidBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(bufferSize))
            })
            if bytesWritten < bufferSize || pidBuffer.count >= 65_536 {
                break
            }
            pidBuffer.append(contentsOf: repeatElement(0, count: pidBuffer.count))
        }
        guard bytesWritten > 0 else {
            throw ProcessSamplerError.listFailed
        }
        counters.expensiveCallCount += 1
        let count = Int(bytesWritten) / MemoryLayout<pid_t>.stride
        return count
    }

    private func shouldPruneCaches(now: Date, processCount: Int) -> Bool {
        guard processCount > 0 else {
            return true
        }
        guard let lastCachePruneDate else {
            return true
        }
        let interval: TimeInterval = processCount > 2_000 ? 5 : 10
        return now.timeIntervalSince(lastCachePruneDate) >= interval
    }

    nonisolated private func rusage(for pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? usage : nil
    }

    nonisolated private func processorSeconds(taskInfo: proc_taskallinfo, usage: rusage_info_v4?) -> TimeInterval {
        if let usage {
            return ProcessCPUTime.seconds(user: usage.ri_user_time, system: usage.ri_system_time)
        }
        return ProcessCPUTime.seconds(user: taskInfo.ptinfo.pti_total_user, system: taskInfo.ptinfo.pti_total_system)
    }

    nonisolated private func processPath(for pid: pid_t) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4096) { buffer in
            buffer.initialize(repeating: 0)
            let length = proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            guard length > 0 else {
                return ""
            }
            return string(from: UnsafeBufferPointer(buffer))
        }
    }

    nonisolated private func processName(for pid: pid_t, fallbackPath: String) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { buffer in
            buffer.initialize(repeating: 0)
            let length = proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            if length > 0 {
                return string(from: UnsafeBufferPointer(buffer))
            }
            let fallback = URL(fileURLWithPath: fallbackPath).lastPathComponent
            return fallback.isEmpty ? "pid-\(pid)" : fallback
        }
    }

    nonisolated private func commandLine(for pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: size) { buffer in
            buffer.initialize(repeating: 0)
            guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
                return nil
            }

            var argc: Int32 = 0
            memcpy(&argc, buffer.baseAddress, MemoryLayout<Int32>.size)

            var index = MemoryLayout<Int32>.size
            while index < size && buffer[index] != 0 { index += 1 }
            while index < size && buffer[index] == 0 { index += 1 }

            var arguments: [String] = []
            for _ in 0..<max(0, Int(argc)) {
                guard index < size else { break }
                let start = index
                while index < size && buffer[index] != 0 { index += 1 }
                if index > start {
                    let count = index - start
                    let rawPtr = UnsafeRawPointer(buffer.baseAddress?.advanced(by: start))
                    if let rawPtr {
                        let subBuffer = UnsafeRawBufferPointer(start: rawPtr, count: count)
                        arguments.append(String(decoding: subBuffer, as: UTF8.self))
                    }
                }
                index += 1
            }

            return arguments.isEmpty ? nil : arguments.joined(separator: " ")
        }
    }

    nonisolated private func forensics(for pid: pid_t) -> (forensics: ProcessForensics, expensiveCallCount: Int) {
        var notes: [String] = []
        var expensiveCallCount = 0

        let vnode = vnodePaths(for: pid)
        expensiveCallCount += 1
        if vnode == nil {
            notes.append("cwd unavailable")
        }

        let descriptors = fileDescriptors(for: pid)
        expensiveCallCount += 1
        if descriptors == nil {
            notes.append("file descriptors unavailable")
        }

        var socketCount = 0
        var ports: [Int] = []
        for descriptor in descriptors ?? [] where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            socketCount += 1
            if let port = localPort(pid: pid, fd: descriptor.proc_fd) {
                ports.append(port)
            }
            expensiveCallCount += 1
        }

        let forensicsResult = ProcessForensics(
            currentDirectory: vnode?.currentDirectory,
            rootDirectory: vnode?.rootDirectory,
            openFileCount: descriptors?.count,
            socketCount: descriptors == nil ? nil : socketCount,
            listeningPorts: Array(Set(ports)).sorted().prefix(8).map { $0 },
            isPartial: vnode == nil || descriptors == nil,
            notes: notes
        )
        return (forensicsResult, expensiveCallCount)
    }

    nonisolated private func vnodePaths(for pid: pid_t) -> (currentDirectory: String?, rootDirectory: String?)? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else {
            return nil
        }
        return (
            tupleString(info.pvi_cdir.vip_path).ifNotEmpty,
            tupleString(info.pvi_rdir.vip_path).ifNotEmpty
        )
    }

    nonisolated private func fileDescriptors(for pid: pid_t) -> [proc_fdinfo]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else {
            return nil
        }

        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else {
            return []
        }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<proc_fdinfo>.stride)
            )
        }
        guard result > 0 else {
            return nil
        }
        return Array(descriptors.prefix(Int(result) / MemoryLayout<proc_fdinfo>.stride))
    }

    nonisolated private func localPort(pid: pid_t, fd: Int32) -> Int? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.stride)
        let result = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        guard result == size else {
            return nil
        }

        let rawPort: Int32
        switch info.psi.soi_kind {
        case Int32(SOCKINFO_TCP):
            rawPort = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
        case Int32(SOCKINFO_IN):
            rawPort = info.psi.soi_proto.pri_in.insi_lport
        default:
            return nil
        }

        guard rawPort > 0 else {
            return nil
        }
        return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: rawPort)))
    }

    nonisolated private func string(from buffer: UnsafeBufferPointer<CChar>) -> String {
        guard let firstZero = buffer.firstIndex(of: 0) else {
            return buffer.withMemoryRebound(to: UInt8.self) { rebound in
                String(decoding: rebound, as: UTF8.self)
            }
        }
        let subBuffer = UnsafeBufferPointer(start: buffer.baseAddress, count: firstZero)
        return subBuffer.withMemoryRebound(to: UInt8.self) { rebound in
            String(decoding: rebound, as: UTF8.self)
        }
    }

    nonisolated private func tupleString<T>(_ tuple: T) -> String {
        var value = tuple
        return withUnsafeBytes(of: &value) { rawBuffer in
            let chars = rawBuffer.bindMemory(to: UInt8.self)
            guard let firstZero = chars.firstIndex(of: 0) else {
                return String(decoding: chars, as: UTF8.self)
            }
            let subBuffer = UnsafeBufferPointer(start: chars.baseAddress, count: firstZero)
            return String(decoding: subBuffer, as: UTF8.self)
        }
    }
}
