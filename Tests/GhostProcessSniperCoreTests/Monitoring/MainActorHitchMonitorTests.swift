import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A suspending-style clock the test drives: each sleep lands exactly on its
/// deadline plus any lateness scheduled for that beat. After `beatLimit`
/// beats it parks until the heartbeat is cancelled.
private final class SteppingClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepCount = 0
    private let lateness: [Int: Duration]
    private let beatLimit: Int

    init(beatLimit: Int, lateness: [Int: Duration] = [:]) {
        self.beatLimit = beatLimit
        self.lateness = lateness
    }

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var beats: Int { lock.withLock { sleepCount } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let beat = lock.withLock {
            sleepCount += 1
            return sleepCount
        }
        if beat > beatLimit {
            try await Task.sleep(for: .seconds(3_600))
        }
        await Task.yield()
        lock.withLock { current = deadline.advanced(by: lateness[beat] ?? .zero) }
    }
}

@MainActor
final class MainActorHitchMonitorTests: XCTestCase {
    private func run(_ clock: SteppingClock, beats: Int) async throws -> RadarSmoothnessReport {
        let monitor = MainActorHitchMonitor(clock: clock)
        monitor.start(interval: 0.25, thresholdMilliseconds: 120)
        XCTAssertTrue(monitor.isRunning)
        let deadline = Date().addingTimeInterval(10)
        while clock.beats <= beats, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        return monitor.report
    }

    func testOnTimeBeatsRecordNoHitchWhateverTheWallClockDoes() async throws {
        // Wall time is never consulted: a Mac that slept for an hour shows up
        // here as a clock that simply kept its 0.25 s rhythm.
        let report = try await run(SteppingClock(beatLimit: 20), beats: 20)
        XCTAssertEqual(report.hitchCount, 0)
        XCTAssertEqual(report.worstHitchMilliseconds, 0)
    }

    func testLateBeatAfterWarmupIsOneHitchOfItsLateness() async throws {
        let clock = SteppingClock(beatLimit: 16, lateness: [3: .milliseconds(500), 12: .milliseconds(300)])
        let report = try await run(clock, beats: 16)
        XCTAssertEqual(report.hitchCount, 1, "the warm-up beat must not count")
        XCTAssertEqual(report.worstHitchMilliseconds, 300, accuracy: 0.001)
        XCTAssertEqual(report.latestSpikePhase, "main actor heartbeat")
    }

    func testBlockedMainActorOnARealClockIsAHitch() async throws {
        let monitor = MainActorHitchMonitor(clock: SuspendingClock())
        monitor.start(interval: 0.05, thresholdMilliseconds: 120)
        try await Task.sleep(for: .milliseconds(2_300))
        let blockedUntil = Date().addingTimeInterval(0.3)
        while Date() < blockedUntil {}
        try await Task.sleep(for: .milliseconds(200))
        monitor.stop()
        let report = monitor.report
        XCTAssertGreaterThanOrEqual(report.hitchCount, 1, "a 300 ms main-actor stall must register")
        XCTAssertGreaterThan(report.worstHitchMilliseconds, 150)
    }

    func testReportLinesArePreformattedAndStable() {
        var ring = SpikeRingBuffer(limit: 4)
        ring.record(phase: "sample", milliseconds: 42.4, threshold: 20, at: Date(timeIntervalSince1970: 1), logToOS: false)
        ring.record(phase: "store", milliseconds: 64.6, threshold: 20, at: Date(timeIntervalSince1970: 2), logToOS: false)
        let first = ring.report
        XCTAssertEqual(first, ring.report)
        XCTAssertEqual(first.recentSpikes.count, 2)
        XCTAssertTrue(first.recentSpikes[0].hasPrefix("sample 42ms at "))
        XCTAssertTrue(first.recentSpikes[1].hasPrefix("store 65ms at "))
    }
}
