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
}

public struct SystemMemoryPressure: Equatable, Hashable, Sendable {
    public let level: MemoryPressureLevel
    /// Fraction of physical memory that is not cheaply reclaimable (0-1).
    public let usedFraction: Double
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let compressedBytes: UInt64

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
        compressedBytes: UInt64
    ) {
        self.level = level
        self.usedFraction = min(1, max(0, usedFraction))
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.compressedBytes = compressedBytes
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

/// Samples host VM statistics via Mach. Sub-millisecond; safe to call every
/// refresh.
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

        let level: MemoryPressureLevel
        if usedFraction >= 0.92 {
            level = .critical
        } else if usedFraction >= 0.84 {
            level = .warning
        } else if usedFraction >= 0.72 {
            level = .elevated
        } else {
            level = .nominal
        }

        return SystemMemoryPressure(
            level: level,
            usedFraction: usedFraction,
            totalBytes: total,
            availableBytes: available,
            compressedBytes: compressed
        )
    }
}
