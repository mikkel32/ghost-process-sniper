import Foundation
@testable import GhostProcessSniperCore

/// Builds measured processes, families and real TrendWindow histories for the
/// intelligence tests. Every reading is fresh at the fixture clock unless a
/// test says otherwise.
enum IntelligenceFixture {
    static let now = Date(timeIntervalSince1970: 50_000)
    static let mib: UInt64 = 1_048_576

    static func process(
        pid: Int32 = 40_000,
        parent: Int32 = 1,
        name: String = "node",
        path: String = "/usr/local/bin/node",
        command: String? = nil,
        megabytes: Double = 100,
        cpu: Double = 0,
        started: Date? = nil,
        date: Date? = nil,
        status: ProcessMeasurementStatus = .fresh,
        cpuStatus: ProcessMeasurementStatus? = nil
    ) -> ProcessMetrics {
        let bytes = UInt64(megabytes * Double(mib))
        let start = started ?? now.addingTimeInterval(-3_600)
        return ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: UInt64(start.timeIntervalSince1970), startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "dev", name: name, executablePath: path,
            commandLine: command ?? "\(name) server.js", residentMemoryBytes: bytes, physicalFootprintBytes: bytes,
            virtualMemoryBytes: bytes, cpuPercent: cpu, totalProcessorSeconds: 0, threadCount: 4,
            isSystemProcess: false, sampledAt: date ?? now, measurementStatus: status, cpuMeasurementStatus: cpuStatus
        )
    }

    /// A real TrendWindow history: one sample per entry, `cadence` seconds apart, ending at `now`.
    static func trend(megabytes: [Double], cpu: [Double]? = nil, cadence: TimeInterval = 5) -> TrendMetrics {
        var window = TrendWindow()
        var metrics = TrendMetrics.empty
        let start = now.addingTimeInterval(-cadence * Double(megabytes.count - 1))
        for (index, value) in megabytes.enumerated() {
            metrics = window.update(
                signatureID: "fixture",
                memoryBytes: UInt64(value * Double(mib)),
                cpuPercent: cpu?[index] ?? 0,
                at: start.addingTimeInterval(cadence * Double(index))
            )
        }
        return metrics
    }

    static func family(
        _ root: ProcessMetrics,
        members: [ProcessMetrics]? = nil,
        trend: TrendMetrics = .empty,
        level: GhostLevel = .quiet,
        heat: GhostHeat? = nil,
        devConfidence: Double = 0.9,
        activity: FamilyCPUActivity = .empty
    ) -> ProcessFamily {
        let members = members ?? [root]
        let score = GhostScore(value: level == .quiet ? 5 : 70, level: level, reasons: [], heat: heat)
        return ProcessFamily(
            root: root, members: members,
            totalResidentMemoryBytes: members.reduce(0) { $0 + $1.residentMemoryBytes },
            totalPhysicalFootprintBytes: members.reduce(0) { $0 + $1.memoryForScoringBytes },
            totalCPUPercent: members.reduce(0) { $0 + $1.cpuPercent },
            devConfidence: devConfidence, commandHints: [root.commandLine], trend: trend, score: score,
            ownedIdentities: members.map(\.identity), protectedPIDs: [], lastScoredAt: now, cpuActivity: activity
        )
    }

    /// Builds and scores one tick through the real builder and intelligence.
    /// `processorCount` pins the core count the CPU limits scale by; nil is this Mac's.
    static func scored(
        _ processes: [ProcessMetrics],
        settings: ThresholdSettings = .smart,
        context: RadarContext = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: []),
        processorCount: Int? = nil,
        window: inout TrendWindow,
        at date: Date = now
    ) -> [ProcessFamily] {
        let cores = processorCount ?? ProcessInfo.processInfo.activeProcessorCount
        let builder = ProcessFamilyBuilder(currentUserID: 501, processorCount: cores)
        let intelligence = RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: cores))
        return builder.buildFamilies(from: processes, settings: settings, trendWindow: &window, now: date)
            .map { intelligence.enrich(family: $0, context: context, settings: settings, now: date) }
    }

    /// Deterministic ±amplitude jitter (a 64-bit LCG), so noisy fixtures replay exactly.
    struct Jitter {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(amplitude: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return (unit * 2 - 1) * amplitude
        }
    }
}
