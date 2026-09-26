import Darwin
import Foundation

/// Discrete host memory-pressure bucket. Discrete on purpose: it feeds the
/// scoring-cache fingerprint, so it must only change when the situation
/// meaningfully changes.
public enum MemoryPressureLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case nominal
    case elevated
    case warning
    case critical

    public var label: String {
        switch self {
        case .nominal: "Nominal"
        case .elevated: "Elevated"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    public var ghostLevel: GhostLevel {
        switch self {
        case .nominal: .quiet
        case .elevated: .watch
        case .warning: .hot
        case .critical: .critical
        }
    }

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ level: MemoryPressureLevel) -> Int {
        switch level {
        case .nominal: 0
        case .elevated: 1
        case .warning: 2
        case .critical: 3
        }
    }

    /// Swap growing this fast means the machine is paging out real work.
    public static let swapGrowthThresholdBytes: UInt64 = 256 * 1_048_576

    /// The kernel's own verdict (kern.memorystatus_vm_pressure_level: 1
    /// normal, 2 warning, 4 critical) wins over the used-fraction bands,
    /// which count anonymous and compressed pages as used and so read
    /// elevated on a healthy Mac. Fast swap growth raises the level one
    /// step, to at most Warning; only the kernel can say Critical then.
    public static func resolve(kernelLevel: Int?, usedFraction: Double, swapGrowthBytes: UInt64) -> MemoryPressureLevel {
        let heuristic = bands(usedFraction: usedFraction)
        var level: MemoryPressureLevel
        switch kernelLevel {
        case 4: return .critical
        case 2: level = .warning
        case 1: level = min(heuristic, .elevated)
        default: level = heuristic
        }
        if swapGrowthBytes > swapGrowthThresholdBytes {
            level = max(level, min(level.raised, .warning))
        }
        return level
    }

    static func bands(usedFraction: Double) -> MemoryPressureLevel {
        if usedFraction >= 0.92 { return .critical }
        if usedFraction >= 0.84 { return .warning }
        if usedFraction >= 0.72 { return .elevated }
        return .nominal
    }

    private var raised: MemoryPressureLevel {
        switch self {
        case .nominal: .elevated
        case .elevated: .warning
        case .warning, .critical: .critical
        }
    }
}

public struct SystemMemoryPressure: Equatable, Hashable, Sendable {
    public let level: MemoryPressureLevel
    /// Fraction of physical memory that is not cheaply reclaimable (0-1).
    public let usedFraction: Double
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let compressedBytes: UInt64
    /// kern.memorystatus_vm_pressure_level, when the kernel reported it.
    public let kernelLevel: Int?
    public let swapUsedBytes: UInt64

    public static let unknown = SystemMemoryPressure(
        level: .nominal,
        usedFraction: 0,
        totalBytes: 0,
        availableBytes: 0,
        compressedBytes: 0
    )

    public init(
        level: MemoryPressureLevel,
        usedFraction: Double,
        totalBytes: UInt64,
        availableBytes: UInt64,
        compressedBytes: UInt64,
        kernelLevel: Int? = nil,
        swapUsedBytes: UInt64 = 0
    ) {
        self.level = level
        self.usedFraction = min(1, max(0, usedFraction))
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.compressedBytes = compressedBytes
        self.kernelLevel = kernelLevel
        self.swapUsedBytes = swapUsedBytes
    }

    public var isKnown: Bool {
        totalBytes > 0
    }

    public var summaryText: String {
        guard isKnown else {
            return "Pressure unknown"
        }
        return "\(Int((usedFraction * 100).rounded()))% used, \(RadarFormat.bytes(availableBytes)) available"
    }
}

/// Swap use sampled at most once a minute, six deep, so growth is measured
/// over about five minutes.
struct SwapGrowthHistory: Sendable {
    static let interval: TimeInterval = 60
    static let capacity = 6

    private var samples: [(date: Date, bytes: UInt64)] = []

    /// Records `bytes` when a minute has passed and returns the growth since
    /// the oldest retained sample (never negative).
    mutating func record(_ bytes: UInt64, at date: Date) -> UInt64 {
        if let last = samples.last, date.timeIntervalSince(last.date) < Self.interval, date >= last.date {
            return growth(to: bytes)
        }
        if let last = samples.last, date < last.date {
            samples.removeAll()
        }
        samples.append((date, bytes))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        return growth(to: bytes)
    }

    private func growth(to bytes: UInt64) -> UInt64 {
        guard let oldest = samples.first, bytes > oldest.bytes else { return 0 }
        return bytes - oldest.bytes
    }
}

/// The refresh worker creates a sampler per refresh; swap history must
/// outlive it.
final class LockedSwapGrowthHistory: @unchecked Sendable {
    static let shared = LockedSwapGrowthHistory()

    private let lock = NSLock()
    private var history = SwapGrowthHistory()

    func record(_ bytes: UInt64, at date: Date) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return history.record(bytes, at: date)
    }
}

/// Samples host VM statistics via Mach plus the kernel's pressure verdict
/// and swap use via sysctl. Sub-millisecond; safe to call every refresh.
public struct SystemPressureSampler: Sendable {
    public init() {}

    public func sample() -> SystemMemoryPressure {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .unknown
        }

        let pageSize = UInt64(getpagesize())
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else {
            return .unknown
        }

        // File-backed and purgeable pages are cheap to evict; treat them as
        // available alongside free pages, mirroring Activity Monitor's view.
        let free = UInt64(stats.free_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let fileBacked = UInt64(stats.external_page_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let available = min(total, free + purgeable + fileBacked)
        var usedFraction = 1 - Double(available) / Double(total)

        // Heavy compressor occupancy is pressure even when "available" looks
        // adequate on paper.
        if Double(compressed) / Double(total) > 0.25 {
            usedFraction = min(1, usedFraction + 0.05)
        }

        let kernelLevel = Self.kernelPressureLevel()
        let swapUsed = Self.swapUsedBytes()
        let swapGrowth = swapUsed.map { LockedSwapGrowthHistory.shared.record($0, at: Date()) } ?? 0

        return SystemMemoryPressure(
            level: .resolve(kernelLevel: kernelLevel, usedFraction: usedFraction, swapGrowthBytes: swapGrowth),
            usedFraction: usedFraction,
            totalBytes: total,
            availableBytes: available,
            compressedBytes: compressed,
            kernelLevel: kernelLevel,
            swapUsedBytes: swapUsed ?? 0
        )
    }

    /// nil when the sysctl fails or reports a value outside 1/2/4.
    static func kernelPressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              [1, 2, 4].contains(level)
        else {
            return nil
        }
        return Int(level)
    }

    static func swapUsedBytes() -> UInt64? {
        #if os(macOS)
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
        #else
        return nil
        #endif
    }
}
