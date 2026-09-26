import Darwin
import Foundation

public enum UserNameResolver {
    private static let cache = LockedUserNameCache()

    public static func name(for userID: UInt32) -> String {
        if let cached = cache.value(for: userID) {
            return cached
        }

        guard let passwd = getpwuid(uid_t(userID)) else {
            let fallback = "#\(userID)"
            cache.store(fallback, for: userID)
            return fallback
        }
        let name = String(cString: passwd.pointee.pw_name)
        cache.store(name, for: userID)
        return name
    }
}

private final class LockedUserNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32: String] = [:]

    func value(for userID: UInt32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[userID]
    }

    func store(_ value: String, for userID: UInt32) {
        lock.lock()
        values[userID] = value
        lock.unlock()
    }
}

extension String {
    var ifNotEmpty: String? {
        isEmpty ? nil : self
    }
}

struct SamplingCounters {
    var commandRefreshCount = 0
    var commandCacheHitCount = 0
    var telemetryDeferredCount = 0
    var forensicsRefreshCount = 0
    var forensicsDeferredCount = 0
    var forensicsCacheHitCount = 0
    var forensicsNegativeCacheHitCount = 0
    var skippedPIDCount = 0
    var expensiveCallCount = 0
    var richMetricRefreshCount = 0
    var scannerWorkerCount = 0
    var skippedOptionalWorkCount = 0
    var scannerTaskCount = 0
    var tinyQueueSequentialCount = 0
    var bsdReadCount = 0
    var taskInfoReadCount = 0
    var reusedRecordCount = 0
    var pidBufferCopyCount = 0
    var scratchpadReuseCount = 0
    var usageReadCount = 0
    var usageFailedCount = 0
    var bsdDeniedCount = 0
    var portCensusCount = 0
    var didHitDeadline = false
    var laneCounts: [ScanLane: Int] = [:]

    mutating func count(_ lane: ScanLane) {
        laneCounts[lane, default: 0] += 1
    }

    mutating func count(_ lane: ScanLane, by amount: Int) {
        guard amount > 0 else {
            return
        }
        laneCounts[lane, default: 0] += amount
    }
}

extension SamplingCounters {
    mutating func record(_ probe: ProbeReadStats) {
        bsdReadCount += probe.bsdReadCount
        bsdDeniedCount += probe.bsdDeniedCount
        usageReadCount += probe.usageReadCount
        usageFailedCount += probe.usageFailedCount
        taskInfoReadCount += probe.taskInfoReadCount
        richMetricRefreshCount += probe.taskInfoReadCount
        expensiveCallCount += probe.expensiveCallCount
        didHitDeadline = didHitDeadline || probe.didHitDeadline
        count(.cheapMetrics, by: probe.bsdReadCount)
        count(.richMetrics, by: probe.taskInfoReadCount)
    }

    func stats(processCount: Int, elapsedMilliseconds: Double) -> SamplerStats {
        SamplerStats(
            processCount: processCount,
            commandRefreshCount: commandRefreshCount,
            commandCacheHitCount: commandCacheHitCount,
            forensicsRefreshCount: forensicsRefreshCount,
            forensicsDeferredCount: forensicsDeferredCount,
            elapsedMilliseconds: elapsedMilliseconds,
            telemetryDeferredCount: telemetryDeferredCount,
            forensicsCacheHitCount: forensicsCacheHitCount,
            forensicsNegativeCacheHitCount: forensicsNegativeCacheHitCount,
            skippedPIDCount: skippedPIDCount,
            expensiveCallCount: expensiveCallCount,
            richMetricRefreshCount: richMetricRefreshCount,
            scannerWorkerCount: scannerWorkerCount,
            skippedOptionalWorkCount: skippedOptionalWorkCount,
            scannerTaskCount: scannerTaskCount,
            tinyQueueSequentialCount: tinyQueueSequentialCount,
            didHitDeadline: didHitDeadline,
            laneCounts: laneCounts,
            bsdReadCount: bsdReadCount,
            taskInfoReadCount: taskInfoReadCount,
            reusedRecordCount: reusedRecordCount,
            pidBufferCopyCount: pidBufferCopyCount,
            scratchpadReuseCount: scratchpadReuseCount,
            usageReadCount: usageReadCount,
            usageFailedCount: usageFailedCount,
            bsdDeniedCount: bsdDeniedCount,
            portCensusCount: portCensusCount
        )
    }
}

/// One tick's working set. The actor keeps it between ticks so the buffers
/// keep their capacity.
struct SamplerTick {
    var rawSamples: [RawProcessSample] = []
    var rawPriorities: [Int] = []
    var samples: [ActiveProcessSample] = []
    var telemetryJobs: [TelemetryJob] = []
    var forensicsJobs: [ForensicsJob] = []
    var identitiesByPID: [Int32: ProcessIdentity] = [:]
    var indexByIdentity: [ProcessIdentity: Int] = [:]
    var counters = SamplingCounters()
    var deadline = TickDeadline(startedAt: 0, budgetMilliseconds: 0)
    private(set) var reused = false
    private var used = false

    mutating func reset(deadline: TickDeadline) {
        samples.removeAll(keepingCapacity: true)
        telemetryJobs.removeAll(keepingCapacity: true)
        forensicsJobs.removeAll(keepingCapacity: true)
        identitiesByPID.removeAll(keepingCapacity: true)
        indexByIdentity.removeAll(keepingCapacity: true)
        counters = SamplingCounters()
        self.deadline = deadline
        reused = used
        used = true
    }
}
