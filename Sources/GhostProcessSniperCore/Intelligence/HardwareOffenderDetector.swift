import Darwin
import Foundation

public struct HardwareOffenderDetector: Sendable {
    private let currentUserID: UInt32
    private let maxOutlierPromotions: Int
    private let physicalMemoryBytes: UInt64

    public init(
        currentUserID: UInt32 = UInt32(geteuid()),
        maxOutlierPromotions: Int = 4,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.currentUserID = currentUserID
        self.maxOutlierPromotions = max(1, maxOutlierPromotions)
        self.physicalMemoryBytes = physicalMemoryBytes
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
            // The largest app on a big Mac is not abnormal just for being
            // largest; scale the floor with the host as well as the limit.
            floor: Double(max(settings.memoryBytes / 3, physicalMemoryBytes / 25, 256 * 1_048_576)),
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
                // One reading; "sustained" is reserved for trend-proven heat.
                reason: "CPU pressure \(RadarFormat.percent(process.cpuPercent))"
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
        // We only ever keep a tiny number of offenders. Sorting the entire
        // process population three times (memory/CPU/GPU) turns this into an
        // avoidable O(n log n) cost on large hosts. Maintain a bounded top-K
        // list instead; maxOutlierPromotions defaults to four.
        var ranked: [(process: ProcessMetrics, value: Double)] = []
        ranked.reserveCapacity(maxOutlierPromotions)
        for process in processes {
            let value = metric(process)
            guard value >= floor else {
                continue
            }

            let insertionIndex = ranked.firstIndex { value > $0.value } ?? ranked.endIndex
            if insertionIndex < maxOutlierPromotions {
                ranked.insert((process, value), at: insertionIndex)
                if ranked.count > maxOutlierPromotions {
                    ranked.removeLast()
                }
            } else if ranked.count < maxOutlierPromotions {
                ranked.append((process, value))
            }
        }

        // Rank says "largest", not "abnormal": an outlier signal only lends
        // visibility (Watch). Hot and Critical come from fixed thresholds, and
        // a process gets at most one signal per resource.
        for (offset, entry) in ranked.enumerated() {
            let process = entry.process
            if let fixedIndex = signalsByIdentity[process.identity]?.firstIndex(where: { $0.kind == kind }) {
                if offset == 0, let fixed = signalsByIdentity[process.identity]?[fixedIndex] {
                    signalsByIdentity[process.identity]?[fixedIndex] = HardwareOffenderSignal(
                        kind: fixed.kind,
                        value: fixed.value,
                        threshold: fixed.threshold,
                        level: fixed.level,
                        impact: fixed.impact,
                        reason: fixed.reason + " (largest on this Mac)"
                    )
                }
                continue
            }
            signalsByIdentity[process.identity, default: []].append(HardwareOffenderSignal(
                kind: kind == .gpuPressure ? .gpuPressure : .sampleOutlier,
                value: entry.value,
                threshold: floor,
                level: .watch,
                impact: max(4, min(14, 10 - Double(offset))),
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
