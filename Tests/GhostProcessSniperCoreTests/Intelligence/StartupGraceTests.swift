import XCTest
@testable import GhostProcessSniperCore

/// A launch is allowed to allocate fast while it warms its caches: the
/// forecaster always said so, but the scorer did not, and a fifteen-second
/// ramp on an app that had only just started was scored Critical.
final class StartupGraceTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    /// Six scans four seconds apart, ending at the fixture clock, climbing at
    /// `rate` MB/min: fast enough to be a leak on any process old enough to judge.
    private func ramp(startedSecondsAgo: TimeInterval, rate: Double = 400) throws -> ProcessFamily {
        var window = TrendWindow()
        var family: ProcessFamily?
        let started = Fixture.now.addingTimeInterval(-startedSecondsAgo)
        for step in 0..<6 {
            let date = Fixture.now.addingTimeInterval(Double(step - 5) * 4)
            let megabytes = 300 + Double(step) * rate * 4 / 60
            let process = Fixture.process(megabytes: megabytes, started: started, date: date)
            family = Fixture.scored([process], window: &window, at: date).first
        }
        return try XCTUnwrap(family)
    }

    func testARampRightAfterLaunchIsNotCritical() throws {
        let launching = try ramp(startedSecondsAgo: 40)
        XCTAssertEqual(launching.trend.credibleMemoryVelocity, 400, accuracy: 10, "the ramp itself is real and still measured")
        XCTAssertLessThan(launching.score.level, .hot)
        XCTAssertEqual(launching.score.heat.sustainedSignalCount, 0)
        XCTAssertFalse(launching.score.heat.shouldNotify)
        XCTAssertFalse(launching.score.heat.shouldRaiseLiveAlert)
        XCTAssertLessThan(launching.forecast.state, .leaking)
        XCTAssertTrue(launching.score.heat.evidence.contains { $0.contains("only just started") }, "\(launching.score.heat.evidence)")
    }

    /// The same ramp on a process that has been running for an hour is a leak.
    func testTheSameRampOnALongRunningProcessStillEscalates() throws {
        let old = try ramp(startedSecondsAgo: 3_600)
        XCTAssertEqual(old.score.level, .critical)
        XCTAssertEqual(old.score.heat.sustainedSignalCount, 1)
        XCTAssertGreaterThanOrEqual(old.forecast.state, .leaking)
        XCTAssertFalse(old.score.heat.evidence.contains { $0.contains("only just started") })
    }

    /// The forecaster keeps its own grace: a leak call waits out the same window.
    func testTheForecasterHoldsBackALeakCallInsideTheGraceWindow() throws {
        let trend = Fixture.trend(megabytes: (0..<8).map { 300 + 40 * Double($0) }, cadence: 10)
        func forecast(startedSecondsAgo: TimeInterval) -> RiskForecast {
            let root = Fixture.process(parent: 999, megabytes: 580, started: Fixture.now.addingTimeInterval(-startedSecondsAgo))
            let family = Fixture.family(root, trend: trend)
            return FamilyRiskForecaster().forecast(family: family, settings: .smart, now: Fixture.now)
        }
        let inside = forecast(startedSecondsAgo: 140)
        XCTAssertEqual(inside.state, .warming)
        XCTAssertTrue(inside.whyNow.contains("startup grace"), inside.whyNow)
        let outside = forecast(startedSecondsAgo: 160)
        XCTAssertGreaterThanOrEqual(outside.state, .leaking)
        XCTAssertFalse(outside.whyNow.contains("startup grace"), outside.whyNow)
    }

    func testGraceCoversTheFirstHundredAndFiftySecondsOfTheRoot() {
        func starting(startedSecondsAgo: TimeInterval) -> Bool {
            let root = Fixture.process(started: Fixture.now.addingTimeInterval(-startedSecondsAgo))
            return StartupGrace.isStarting(root: root, now: Fixture.now)
        }
        XCTAssertTrue(starting(startedSecondsAgo: 0))
        XCTAssertTrue(starting(startedSecondsAgo: 149))
        XCTAssertFalse(starting(startedSecondsAgo: 151))
        XCTAssertFalse(starting(startedSecondsAgo: 3_600))
        XCTAssertFalse(starting(startedSecondsAgo: -30), "a clock stepped back must not hold a family in grace")
        let unknown = Fixture.process(started: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(StartupGrace.isStarting(root: unknown, now: Fixture.now), "no reported start time")
    }

    /// The same window and limit: only the flag differs, so the flag is what holds the leak back.
    func testAProvenClimbIsNotASustainedLeakWhileStarting() {
        let climb = Fixture.trend(megabytes: (0..<6).map { 300 + Double($0) * 400 * 4 / 60 }, cadence: 4)
        func heat(isStarting: Bool) -> GhostHeat {
            GhostHeatModel.initial(memoryRatio: 0.4, cpuRatio: 0, cpuThreshold: 90, gpuRatio: 0, leakRatio: 3,
                                   trend: climb, hardwareLevel: .quiet, isStarting: isStarting)
        }
        let settled = heat(isStarting: false)
        XCTAssertEqual(settled.sustainedSignalCount, 1)
        XCTAssertEqual(settled.level, .critical)

        let launching = heat(isStarting: true)
        XCTAssertEqual(launching.sustainedSignalCount, 0)
        XCTAssertEqual(launching.level, .watch, "still worth a look, never an alert")
        XCTAssertLessThan(launching.value, settled.value, "an unproven trend carries less heat")
        XCTAssertTrue(launching.evidence.contains("Memory is rising, but the process only just started"), "\(launching.evidence)")
    }

    /// A family that is over its memory limit as it launches still reads Hot:
    /// grace is for the ramp, not for a footprint that is already too big.
    func testALaunchAlreadyFarOverItsLimitIsStillHot() {
        let heat = GhostHeatModel.initial(memoryRatio: 1.8, cpuRatio: 0, cpuThreshold: 90, gpuRatio: 0, leakRatio: 0,
                                          trend: .empty, hardwareLevel: .quiet, isStarting: true)
        XCTAssertEqual(heat.level, .hot)
    }

    /// Age is not in the fingerprint of anything else, so without its own bit a
    /// family scored inside the grace would keep that score for up to five minutes.
    func testTheScoringCacheRescoresWhenTheGraceEnds() {
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        let root = Fixture.process(started: Fixture.now.addingTimeInterval(-100))
        let family = Fixture.family(root)
        let inside = FamilyScoringCache.fingerprint(family: family, context: context, now: Fixture.now)
        XCTAssertEqual(inside, FamilyScoringCache.fingerprint(family: family, context: context, now: Fixture.now.addingTimeInterval(10)))
        XCTAssertNotEqual(inside, FamilyScoringCache.fingerprint(family: family, context: context, now: Fixture.now.addingTimeInterval(60)))
    }
}
