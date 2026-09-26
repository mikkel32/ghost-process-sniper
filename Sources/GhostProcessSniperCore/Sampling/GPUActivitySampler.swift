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
    private var didLogServices = false

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
        let raw = IORegistryGPUClientReader.readAccumulatedNanosecondsByPID(logMatchedServices: !didLogServices)
        didLogServices = true
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

/// One GPU user client's lifetime GPU time.
struct GPUClientUsage: Equatable, Sendable {
    let serviceID: UInt64
    let clientID: UInt64
    let pid: Int32
    let nanoseconds: UInt64
}

public enum IORegistryGPUClientReader {
    private static let acceleratorClasses = ["AGXAccelerator", "IOAccelerator"]

    public static func readAccumulatedNanosecondsByPID() -> [Int32: UInt64] {
        readAccumulatedNanosecondsByPID(logMatchedServices: false)
    }

    /// Apple GPUs match both classes (AGXAccelerator subclasses IOAccelerator),
    /// so services are collected by registry ID and each is walked once.
    static func readAccumulatedNanosecondsByPID(logMatchedServices: Bool) -> [Int32: UInt64] {
        var services: [UInt64: io_registry_entry_t] = [:]
        var matchedByClass: [String: [UInt64]] = [:]
        for acceleratorClass in acceleratorClasses {
            matchedByClass[acceleratorClass] = collectServices(acceleratorClass, into: &services)
        }
        defer { services.values.forEach { IOObjectRelease($0) } }
        if logMatchedServices {
            let summary = acceleratorClasses
                .map { "\($0): \((matchedByClass[$0] ?? []).map(String.init).joined(separator: ","))" }
                .joined(separator: "; ")
            RadarLogger.sampler.debug("GPU accelerator services \(summary, privacy: .public)")
        }

        var clients: [GPUClientUsage] = []
        for (serviceID, service) in services {
            appendClients(of: service, serviceID: serviceID, into: &clients)
        }
        return mergeClients(clients)
    }

    /// Sums GPU time per pid, counting each user client once however many
    /// times the walk reached it.
    static func mergeClients(_ clients: [GPUClientUsage]) -> [Int32: UInt64] {
        var seen = Set<UInt64>()
        var totals: [Int32: UInt64] = [:]
        for client in clients where client.nanoseconds > 0 && seen.insert(client.clientID).inserted {
            totals[client.pid, default: 0] &+= client.nanoseconds
        }
        return totals
    }

    /// Returns the registry IDs this class matched; new services are retained
    /// in `services`, duplicates released.
    private static func collectServices(_ acceleratorClass: String,
                                        into services: inout [UInt64: io_registry_entry_t]) -> [UInt64] {
        guard let matching = IOServiceMatching(acceleratorClass) else {
            return []
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var matched: [UInt64] = []
        while true {
            let accelerator = IOIteratorNext(iterator)
            guard accelerator != 0 else { break }
            guard let serviceID = registryID(accelerator), services[serviceID] == nil else {
                IOObjectRelease(accelerator)
                continue
            }
            services[serviceID] = accelerator
            matched.append(serviceID)
        }
        return matched
    }

    private static func appendClients(of service: io_registry_entry_t, serviceID: UInt64,
                                      into clients: inout [GPUClientUsage]) {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(childIterator) }

        while true {
            let child = IOIteratorNext(childIterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }

            // Most children are not user clients; AppUsage rules them out
            // before any string work.
            guard let nanoseconds = accumulatedGPUTimeNanoseconds(child),
                  isGPUUserClient(child),
                  let creator = stringProperty(child, key: "IOUserClientCreator"),
                  let pid = pid(fromCreator: creator),
                  let clientID = registryID(child)
            else {
                continue
            }
            clients.append(GPUClientUsage(serviceID: serviceID, clientID: clientID, pid: pid, nanoseconds: nanoseconds))
        }
    }

    private static func registryID(_ entry: io_registry_entry_t) -> UInt64? {
        var identifier: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &identifier) == KERN_SUCCESS ? identifier : nil
    }

    private static func isGPUUserClient(_ entry: io_registry_entry_t) -> Bool {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 128) { buffer in
            buffer.initialize(repeating: 0)
            guard let base = buffer.baseAddress, IOObjectGetClass(entry, base) == KERN_SUCCESS else {
                return false
            }
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            let name = UnsafeBufferPointer(rebasing: buffer[..<length]).withMemoryRebound(to: UInt8.self) {
                String(decoding: $0, as: UTF8.self)
            }
            return name.contains("UserClient")
        }
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

    /// nil when the entry has no AppUsage, which is every non-client child.
    private static func accumulatedGPUTimeNanoseconds(_ entry: io_registry_entry_t) -> UInt64? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            "AppUsage" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(), let usage = value as? NSArray else {
            return nil
        }

        // Stay on the Foundation objects instead of bridging the whole array
        // to [Any] and every entry to [String: Any].
        var total: UInt64 = 0
        for case let record as NSDictionary in usage {
            total &+= nanoseconds(record["accumulatedGPUTime"]) &+ nanoseconds(record["AccumulatedGPUTime"])
        }
        return total
    }

    private static func nanoseconds(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        let signed = number.int64Value
        return signed > 0 ? UInt64(signed) : 0
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
