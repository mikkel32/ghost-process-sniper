import Darwin
import Foundation
import IOKit

public struct ProcessGPUActivitySnapshot: Equatable, Sendable {
    public let percentByPID: [Int32: Double]
    public let measuredAtByPID: [Int32: Date]
    public let rawClientCount: Int
    public let readMilliseconds: Double
    public let didRefresh: Bool

    public static let empty = ProcessGPUActivitySnapshot(
        percentByPID: [:],
        measuredAtByPID: [:],
        rawClientCount: 0,
        readMilliseconds: 0,
        didRefresh: false
    )

    public init(percentByPID: [Int32: Double], measuredAtByPID: [Int32: Date] = [:],
                rawClientCount: Int, readMilliseconds: Double, didRefresh: Bool) {
        self.percentByPID = percentByPID
        self.measuredAtByPID = measuredAtByPID
        self.rawClientCount = rawClientCount
        self.readMilliseconds = readMilliseconds
        self.didRefresh = didRefresh
    }
}

public struct ProcessGPUUsageTracker: Sendable {
    private struct RawSample: Sendable {
        var nanoseconds: UInt64
        var sampledAt: Date
        var identity: ProcessIdentity?
    }

    private var previous: [Int32: RawSample] = [:]
    private var cachedPercentByPID: [Int32: Double] = [:]
    private var cachedMeasuredAtByPID: [Int32: Date] = [:]
    private var lastRefreshAt: Date?

    public init() {}

    public mutating func sample(now: Date, minimumInterval: TimeInterval,
                                identitiesByPID: [Int32: ProcessIdentity] = [:]) -> ProcessGPUActivitySnapshot {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minimumInterval {
            // A PID can be recycled between GPU polls. Never hand its old rate
            // to a different process just because the integer is the same.
            let validPIDs = Set(previous.compactMap { pid, sample in
                sample.identity == identitiesByPID[pid] ? pid : nil
            })
            return ProcessGPUActivitySnapshot(
                percentByPID: cachedPercentByPID.filter { validPIDs.contains($0.key) },
                measuredAtByPID: cachedMeasuredAtByPID.filter { validPIDs.contains($0.key) },
                rawClientCount: previous.count,
                readMilliseconds: 0,
                didRefresh: false
            )
        }

        let start = Date()
        let raw = IORegistryGPUClientReader.readAccumulatedNanosecondsByPID()
        let elapsed = Date().timeIntervalSince(start) * 1_000
        let percent = update(rawNanosecondsByPID: raw, now: now, identitiesByPID: identitiesByPID)
        lastRefreshAt = now

        return ProcessGPUActivitySnapshot(
            percentByPID: percent,
            measuredAtByPID: cachedMeasuredAtByPID,
            rawClientCount: raw.count,
            readMilliseconds: elapsed,
            didRefresh: true
        )
    }

    public mutating func update(rawNanosecondsByPID raw: [Int32: UInt64], now: Date,
                                identitiesByPID: [Int32: ProcessIdentity] = [:]) -> [Int32: Double] {
        var nextPercent: [Int32: Double] = [:]
        var nextMeasuredAt: [Int32: Date] = [:]
        nextPercent.reserveCapacity(raw.count)
        nextMeasuredAt.reserveCapacity(raw.count)

        for (pid, nanoseconds) in raw {
            let identity = identitiesByPID[pid]
            if let old = previous[pid], old.identity == identity,
               nanoseconds >= old.nanoseconds, now > old.sampledAt {
                let elapsed = now.timeIntervalSince(old.sampledAt)
                let delta = nanoseconds - old.nanoseconds
                let percent = min(999, max(0, Double(delta) / (elapsed * 1_000_000_000) * 100))
                nextMeasuredAt[pid] = now
                if percent > 0.1 {
                    nextPercent[pid] = percent
                }
            }
            previous[pid] = RawSample(nanoseconds: nanoseconds, sampledAt: now, identity: identity)
        }

        let livePIDs = Set(raw.keys)
        previous = previous.filter { livePIDs.contains($0.key) }
        cachedPercentByPID = nextPercent
        cachedMeasuredAtByPID = nextMeasuredAt
        return nextPercent
    }
}

public enum IORegistryGPUClientReader {
    public static func readAccumulatedNanosecondsByPID() -> [Int32: UInt64] {
        var totals: [Int32: UInt64] = [:]
        for acceleratorClass in ["AGXAccelerator", "IOAccelerator"] {
            mergeGPUClients(acceleratorClass: acceleratorClass, into: &totals)
        }
        return totals
    }

    private static func mergeGPUClients(acceleratorClass: String, into totals: inout [Int32: UInt64]) {
        guard let matching = IOServiceMatching(acceleratorClass) else {
            return
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let accelerator = IOIteratorNext(iterator)
            guard accelerator != 0 else { break }
            defer { IOObjectRelease(accelerator) }
            mergeChildren(of: accelerator, into: &totals)
        }
    }

    private static func mergeChildren(of parent: io_registry_entry_t, into totals: inout [Int32: UInt64]) {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(childIterator) }

        while true {
            let child = IOIteratorNext(childIterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }

            guard isGPUUserClient(child),
                  let creator = stringProperty(child, key: "IOUserClientCreator"),
                  let pid = pid(fromCreator: creator)
            else {
                continue
            }

            let nanoseconds = accumulatedGPUTimeNanoseconds(child)
            if nanoseconds > 0 {
                totals[pid, default: 0] += nanoseconds
            }
        }
    }

    private static func isGPUUserClient(_ entry: io_registry_entry_t) -> Bool {
        var className = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &className) == KERN_SUCCESS else {
            return false
        }
        let name = className.withUnsafeBufferPointer { buffer in
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return name.contains("DeviceUserClient") || name.contains("UserClient")
    }

    private static func stringProperty(_ entry: io_registry_entry_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    private static func accumulatedGPUTimeNanoseconds(_ entry: io_registry_entry_t) -> UInt64 {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            "AppUsage" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return 0
        }
        guard let array = value as? [Any] else {
            return 0
        }

        var total: UInt64 = 0
        for item in array {
            guard let dictionary = item as? [String: Any] else {
                continue
            }
            total += numberValue(dictionary["accumulatedGPUTime"])
            total += numberValue(dictionary["AccumulatedGPUTime"])
        }
        return total
    }

    private static func numberValue(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int64, value > 0 {
            return UInt64(value)
        }
        if let value = value as? Int, value > 0 {
            return UInt64(value)
        }
        return 0
    }

    private static func pid(fromCreator creator: String) -> Int32? {
        let pieces = creator.split { !$0.isNumber }
        for piece in pieces {
            if let value = Int32(piece), value > 0 {
                return value
            }
        }
        return nil
    }
}
