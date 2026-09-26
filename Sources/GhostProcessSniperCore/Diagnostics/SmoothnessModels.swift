import Foundation

public struct RefreshPhaseTrace: Equatable, Sendable {
    public let sampleMilliseconds: Double
    public let buildMilliseconds: Double
    public let scoreMilliseconds: Double
    public let storeMilliseconds: Double
    public let publishMilliseconds: Double
    public let totalMilliseconds: Double

    public static let empty = RefreshPhaseTrace(
        sampleMilliseconds: 0,
        buildMilliseconds: 0,
        scoreMilliseconds: 0,
        storeMilliseconds: 0,
        publishMilliseconds: 0,
        totalMilliseconds: 0
    )

    public init(
        sampleMilliseconds: Double,
        buildMilliseconds: Double,
        scoreMilliseconds: Double,
        storeMilliseconds: Double,
        publishMilliseconds: Double,
        totalMilliseconds: Double
    ) {
        self.sampleMilliseconds = sampleMilliseconds
        self.buildMilliseconds = buildMilliseconds
        self.scoreMilliseconds = scoreMilliseconds
        self.storeMilliseconds = storeMilliseconds
        self.publishMilliseconds = publishMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }

    public init(stats: RefreshStats) {
        self.init(
            sampleMilliseconds: stats.sampleMilliseconds,
            buildMilliseconds: stats.buildMilliseconds,
            scoreMilliseconds: stats.scoreMilliseconds,
            storeMilliseconds: stats.storeMilliseconds,
            publishMilliseconds: stats.publishMilliseconds,
            totalMilliseconds: stats.totalMilliseconds
        )
    }

    public var slowestPhase: (name: String, milliseconds: Double) {
        [
            ("sample", sampleMilliseconds),
            ("build", buildMilliseconds),
            ("score", scoreMilliseconds),
            ("store", storeMilliseconds),
            ("publish", publishMilliseconds)
        ].max { $0.1 < $1.1 } ?? ("unknown", totalMilliseconds)
    }
}

public struct RadarSmoothnessReport: Equatable, Sendable {
    public let hitchCount: Int
    public let worstHitchMilliseconds: Double
    public let latestSpikePhase: String
    public let recentSpikes: [String]

    public static let empty = RadarSmoothnessReport(
        hitchCount: 0,
        worstHitchMilliseconds: 0,
        latestSpikePhase: "none",
        recentSpikes: []
    )

    public init(
        hitchCount: Int,
        worstHitchMilliseconds: Double,
        latestSpikePhase: String,
        recentSpikes: [String]
    ) {
        self.hitchCount = hitchCount
        self.worstHitchMilliseconds = worstHitchMilliseconds
        self.latestSpikePhase = latestSpikePhase
        self.recentSpikes = recentSpikes
    }

    public func merging(_ other: RadarSmoothnessReport) -> RadarSmoothnessReport {
        RadarSmoothnessReport(
            hitchCount: hitchCount + other.hitchCount,
            worstHitchMilliseconds: max(worstHitchMilliseconds, other.worstHitchMilliseconds),
            latestSpikePhase: other.latestSpikePhase == "none" ? latestSpikePhase : other.latestSpikePhase,
            recentSpikes: Array((recentSpikes + other.recentSpikes).suffix(8))
        )
    }
}

public struct SpikeRingBuffer: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let date: Date
        public let phase: String
        public let milliseconds: Double

        public init(date: Date, phase: String, milliseconds: Double) {
            self.date = date
            self.phase = phase
            self.milliseconds = milliseconds
        }
    }

    private let limit: Int
    private var entries: [Entry]

    public init(limit: Int = 8) {
        self.limit = max(1, limit)
        self.entries = []
    }

    public mutating func record(
        phase: String,
        milliseconds: Double,
        threshold: Double,
        at date: Date = Date(),
        logToOS: Bool = true
    ) {
        guard milliseconds >= threshold else {
            return
        }
        entries.append(Entry(date: date, phase: phase, milliseconds: milliseconds))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        if logToOS {
            RadarLogger.performance.notice("Smoothness spike \(phase, privacy: .public) \(milliseconds, privacy: .public)ms")
        }
    }

    public mutating func record(trace: RefreshPhaseTrace, threshold: Double, at date: Date = Date()) {
        let phase = trace.slowestPhase
        record(phase: phase.name, milliseconds: phase.milliseconds, threshold: threshold, at: date)
    }

    public var report: RadarSmoothnessReport {
        let worst = entries.map(\.milliseconds).max() ?? 0
        let latest = entries.last?.phase ?? "none"
        let lines = entries.map { entry in
            "\(entry.phase) \(Int(entry.milliseconds.rounded()))ms at \(entry.date.formatted(date: .omitted, time: .standard))"
        }
        return RadarSmoothnessReport(
            hitchCount: entries.count,
            worstHitchMilliseconds: worst,
            latestSpikePhase: latest,
            recentSpikes: lines
        )
    }
}

@MainActor
public final class MainActorHitchMonitor {
    private var task: Task<Void, Never>?
    private var spikes = SpikeRingBuffer(limit: 8)
    private var heartbeatInterval: TimeInterval = 0.25
    private var thresholdMilliseconds: Double = 120

    public init() {}

    public func start(
        interval: TimeInterval = 0.25,
        thresholdMilliseconds: Double = 120
    ) {
        stop()
        heartbeatInterval = max(0.05, interval)
        self.thresholdMilliseconds = thresholdMilliseconds
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let warmupEnd = Date().addingTimeInterval(2)
            var expected = Date().addingTimeInterval(self.heartbeatInterval)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                let now = Date()
                let drift = max(0, now.timeIntervalSince(expected) * 1_000)
                if now >= warmupEnd {
                    self.spikes.record(
                        phase: "main actor heartbeat",
                        milliseconds: drift,
                        threshold: self.thresholdMilliseconds,
                        at: now,
                        logToOS: false
                    )
                }
                expected = now.addingTimeInterval(self.heartbeatInterval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func recordPublish(milliseconds: Double) {
        spikes.record(phase: "main actor publish", milliseconds: milliseconds, threshold: 16)
    }

    public var report: RadarSmoothnessReport {
        spikes.report
    }
}
