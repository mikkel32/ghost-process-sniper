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
