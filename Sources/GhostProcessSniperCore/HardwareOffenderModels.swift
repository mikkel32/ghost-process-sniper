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

    public var scoreImpact: Double {
        min(34, signals.reduce(0) { $0 + $1.impact })
    }

    public var shouldPromote: Bool {
        level >= .watch && !signals.isEmpty
    }
}

public struct HardwareOffenderDetector: Sendable {
    private let currentUserID: UInt32
    private let maxOutlierPromotions: Int

    public init(currentUserID: UInt32 = UInt32(geteuid()), maxOutlierPromotions: Int = 4) {
        self.currentUserID = currentUserID
        self.maxOutlierPromotions = max(1, maxOutlierPromotions)
    }

    public func detect(
        processes: [ProcessMetrics],
        settings: ThresholdSettings
    ) -> [ProcessIdentity: HardwareOffenderProfile] {
        let eligible = processes.filter(isEligibleForGenericHardwareDetection)
        guard !eligible.isEmpty else {
            return [:]
        }

        var signalsByIdentity: [ProcessIdentity: [HardwareOffenderSignal]] = [:]
        var processByIdentity: [ProcessIdentity: ProcessMetrics] = [:]
        signalsByIdentity.reserveCapacity(min(eligible.count, 128))
        processByIdentity.reserveCapacity(eligible.count)

        for process in eligible {
            processByIdentity[process.identity] = process
            let fixedSignals = fixedPressureSignals(for: process, settings: settings)
            if !fixedSignals.isEmpty {
                signalsByIdentity[process.identity, default: []].append(contentsOf: fixedSignals)
            }
        }

        addSampleOutliers(
            eligible,
            metric: { Double($0.memoryForScoringBytes) },
            floor: Double(max(settings.memoryBytes / 3, 256 * 1_048_576)),
            reason: { "memory top offender \(RadarFormat.bytes($0.memoryForScoringBytes))" },
            kind: .memoryPressure,
            signalsByIdentity: &signalsByIdentity
        )

        addSampleOutliers(
            eligible,
            metric: { $0.cpuPercent },
            floor: max(settings.cpuPercent * 0.35, 25),
            reason: { "CPU top offender \(RadarFormat.percent($0.cpuPercent))" },
            kind: .cpuPressure,
            signalsByIdentity: &signalsByIdentity
        )

        addSampleOutliers(
            eligible,
            metric: { $0.gpuUsagePercent },
            floor: 12,
            reason: { "GPU top offender \(RadarFormat.percent($0.gpuUsagePercent))" },
            kind: .gpuPressure,
            signalsByIdentity: &signalsByIdentity
        )

        var profiles: [ProcessIdentity: HardwareOffenderProfile] = [:]
        profiles.reserveCapacity(signalsByIdentity.count)
        for (identity, signals) in signalsByIdentity {
            guard let process = processByIdentity[identity] else {
                continue
            }
            profiles[identity] = HardwareOffenderProfile(
                identity: identity,
                pid: process.pid,
                signals: Self.deduplicated(signals)
            )
        }
        return profiles
    }

    private func isEligibleForGenericHardwareDetection(_ process: ProcessMetrics) -> Bool {
        if process.userID == currentUserID {
            return !process.isSystemProcess && !isSystemBundle(process.executablePath)
        }

        let lowerPath = process.executablePath.lowercased()
        let lowerCommand = process.commandLine.lowercased()
        let devish = lowerPath.hasPrefix("/usr/local/") ||
            lowerPath.hasPrefix("/opt/homebrew/") ||
            lowerPath.contains("/developer/") ||
            lowerCommand.contains("localhost") ||
            lowerCommand.contains("server") ||
            lowerCommand.contains("node_modules")
        return devish && !isSystemBundle(process.executablePath)
    }

    private func fixedPressureSignals(
        for process: ProcessMetrics,
        settings: ThresholdSettings
    ) -> [HardwareOffenderSignal] {
        var signals: [HardwareOffenderSignal] = []
        let memoryWatch = max(Double(settings.memoryBytes) * 0.45, Double(384 * 1_048_576))
        let memoryHot = max(Double(settings.memoryBytes) * 0.85, Double(768 * 1_048_576))
        let memoryValue = Double(process.memoryForScoringBytes)
        if memoryValue >= memoryWatch {
            signals.append(signal(
                kind: .memoryPressure,
                value: memoryValue,
                threshold: memoryWatch,
                hotThreshold: memoryHot,
                criticalThreshold: Double(settings.memoryBytes) * 1.25,
                watchImpact: 8,
                hotImpact: 16,
                reason: memoryValue >= memoryHot ? "large hardware footprint \(RadarFormat.bytes(process.memoryForScoringBytes))" : "notable hardware footprint \(RadarFormat.bytes(process.memoryForScoringBytes))"
            ))
        }

        let cpuWatch = max(settings.cpuPercent * 0.40, 30)
        let cpuHot = max(settings.cpuPercent * 0.75, 55)
        if process.cpuPercent >= cpuWatch {
            signals.append(signal(
                kind: .cpuPressure,
                value: process.cpuPercent,
                threshold: cpuWatch,
                hotThreshold: cpuHot,
                criticalThreshold: max(settings.cpuPercent * 1.15, 90),
                watchImpact: 7,
                hotImpact: 18,
                reason: process.cpuPercent >= cpuHot ? "sustained CPU pressure \(RadarFormat.percent(process.cpuPercent))" : "CPU pressure \(RadarFormat.percent(process.cpuPercent))"
            ))
        }

        if process.gpuUsagePercent >= 18 {
            signals.append(signal(
                kind: .gpuPressure,
                value: process.gpuUsagePercent,
                threshold: 18,
                hotThreshold: 45,
                criticalThreshold: 80,
                watchImpact: 10,
                hotImpact: 22,
                reason: process.gpuUsagePercent >= 45 ? "high GPU activity \(RadarFormat.percent(process.gpuUsagePercent))" : "GPU activity \(RadarFormat.percent(process.gpuUsagePercent))"
            ))
        }

        if process.threadCount >= 80 {
            signals.append(signal(
                kind: .threadPressure,
                value: Double(process.threadCount),
                threshold: 80,
                hotThreshold: 160,
                criticalThreshold: 260,
                watchImpact: 5,
                hotImpact: 12,
                reason: "\(process.threadCount) live threads"
            ))
        }

        return signals
    }

    private func addSampleOutliers(
        _ processes: [ProcessMetrics],
        metric: (ProcessMetrics) -> Double,
        floor: Double,
        reason: (ProcessMetrics) -> String,
        kind: HardwareOffenderSignalKind,
        signalsByIdentity: inout [ProcessIdentity: [HardwareOffenderSignal]]
    ) {
        let ranked = processes
            .filter { metric($0) >= floor }
            .sorted { metric($0) > metric($1) }
            .prefix(maxOutlierPromotions)

        for (offset, process) in ranked.enumerated() {
            let value = metric(process)
            let level: GhostLevel = offset == 0 && value >= floor * 1.8 ? .hot : .watch
            let impact = max(4, min(14, 10 - Double(offset)))
            signalsByIdentity[process.identity, default: []].append(HardwareOffenderSignal(
                kind: kind == .gpuPressure ? .gpuPressure : .sampleOutlier,
                value: value,
                threshold: floor,
                level: level,
                impact: impact,
                reason: reason(process)
            ))
        }
    }

    private func signal(
        kind: HardwareOffenderSignalKind,
        value: Double,
        threshold: Double,
        hotThreshold: Double,
        criticalThreshold: Double,
        watchImpact: Double,
        hotImpact: Double,
        reason: String
    ) -> HardwareOffenderSignal {
        let level: GhostLevel
        if value >= criticalThreshold {
            level = .critical
        } else if value >= hotThreshold {
            level = .hot
        } else {
            level = .watch
        }
        let impact = level == .critical ? hotImpact + 10 : (level == .hot ? hotImpact : watchImpact)
        return HardwareOffenderSignal(
            kind: kind,
            value: value,
            threshold: threshold,
            level: level,
            impact: impact,
            reason: reason
        )
    }

    private func isSystemBundle(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("/system/") ||
            lower.hasPrefix("/system/applications/") ||
            lower.hasPrefix("/usr/libexec/") ||
            lower.hasPrefix("/library/apple/")
    }

    private static func deduplicated(_ signals: [HardwareOffenderSignal]) -> [HardwareOffenderSignal] {
        var seen = Set<String>()
        return signals.filter { signal in
            seen.insert("\(signal.kind.rawValue)|\(signal.reason)").inserted
        }
        .sorted { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            return lhs.impact > rhs.impact
        }
        .prefix(6)
        .map { $0 }
    }
}
