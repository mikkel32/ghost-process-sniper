import Darwin
import Foundation

public enum HardwareOffenderSignalKind: String, Codable, CaseIterable, Sendable {
    case memoryPressure
    case cpuPressure
    case gpuPressure
    case threadPressure
    case sampleOutlier

    public var label: String {
        switch self {
        case .memoryPressure: "Memory pressure"
        case .cpuPressure: "CPU pressure"
        case .gpuPressure: "GPU pressure"
        case .threadPressure: "Thread pressure"
        case .sampleOutlier: "Sample outlier"
        }
    }
}

public struct HardwareOffenderSignal: Codable, Equatable, Sendable {
    public let kind: HardwareOffenderSignalKind
    public let value: Double
    public let threshold: Double
    public let level: GhostLevel
    public let impact: Double
    public let reason: String

    public init(
        kind: HardwareOffenderSignalKind,
        value: Double,
        threshold: Double,
        level: GhostLevel,
        impact: Double,
        reason: String
    ) {
        self.kind = kind
        self.value = value
        self.threshold = threshold
        self.level = level
        self.impact = impact
        self.reason = reason
    }
}

public struct HardwareOffenderProfile: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let pid: Int32
    public let signals: [HardwareOffenderSignal]

    public init(identity: ProcessIdentity, pid: Int32, signals: [HardwareOffenderSignal]) {
        self.identity = identity
        self.pid = pid
        self.signals = signals.sorted { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            return lhs.impact > rhs.impact
        }
    }

    public var level: GhostLevel {
        signals.map(\.level).max() ?? .quiet
    }

    public var shouldPromote: Bool {
        level >= .watch && !signals.isEmpty
    }
}

