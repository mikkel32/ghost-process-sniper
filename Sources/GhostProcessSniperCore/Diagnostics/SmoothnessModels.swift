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
        /// Formatted once when recorded; reports are read every tick.
        public let line: String

        public init(date: Date, phase: String, milliseconds: Double) {
            self.date = date
            self.phase = phase
            self.milliseconds = milliseconds
            line = "\(phase) \(Int(milliseconds.rounded()))ms at \(date.formatted(date: .omitted, time: .standard))"
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
        return RadarSmoothnessReport(
            hitchCount: entries.count,
            worstHitchMilliseconds: worst,
            latestSpikePhase: latest,
            recentSpikes: entries.map(\.line)
        )
    }
}

/// A main-actor heartbeat that records late wake-ups as hitches. It runs
/// only while a radar surface is on screen, since nobody sees a hitch
/// otherwise and the heartbeat wakes the main thread four times a second.
@MainActor
public final class MainActorHitchMonitor {
    private var task: Task<Void, Never>?
    private var spikes = SpikeRingBuffer(limit: 8)
    private let sleepMeasuringLateness: @MainActor @Sendable (Duration) async throws -> Duration
    private var heartbeatInterval: TimeInterval = 0.25
    private var thresholdMilliseconds: Double = 120

    /// The clock must stop while the Mac sleeps (the default suspending
    /// clock does), or waking from sleep would read as a minutes-long hitch.
    public init<C: Clock<Duration>>(clock: C = SuspendingClock()) {
        // Main-actor isolated so the post-sleep reading waits for the main
        // thread: a busy main actor is exactly the lateness being measured.
        sleepMeasuringLateness = { @MainActor interval in
            let expected = clock.now.advanced(by: interval)
            try await clock.sleep(until: expected, tolerance: nil)
            return expected.duration(to: clock.now)
        }
    }

    deinit {
        task?.cancel()
    }

    public var isRunning: Bool {
        task != nil
    }

    public func start(
        interval: TimeInterval = 0.25,
        thresholdMilliseconds: Double = 120
    ) {
        stop()
        heartbeatInterval = max(0.05, interval)
        self.thresholdMilliseconds = thresholdMilliseconds
        task = heartbeat()
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func recordPublish(milliseconds: Double) {
        spikes.record(phase: "main actor publish", milliseconds: milliseconds, threshold: 16)
    }

    func recordHeartbeat(milliseconds: Double, at date: Date = Date()) {
        spikes.record(
            phase: "main actor heartbeat",
            milliseconds: milliseconds,
            threshold: thresholdMilliseconds,
            at: date,
            logToOS: false
        )
    }

    public var report: RadarSmoothnessReport {
        spikes.report
    }

    private func heartbeat() -> Task<Void, Never> {
        let interval = Duration.seconds(heartbeatInterval)
        let sleep = sleepMeasuringLateness
        return Task { @MainActor [weak self] in
            let warmup = Duration.seconds(2)
            var elapsed = Duration.zero
            while !Task.isCancelled {
                let late: Duration
                do {
                    late = try await sleep(interval)
                } catch {
                    return
                }
                guard let self else { return }
                elapsed += interval + late
                if elapsed >= warmup {
                    self.recordHeartbeat(milliseconds: max(0, late.milliseconds))
                }
            }
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
