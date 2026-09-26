import XCTest
@testable import GhostProcessSniperCore

final class RadarHysteresisTests: XCTestCase {
    private let t0 = RefreshPerformanceFixture.now
    private let root = RefreshPerformanceFixture.process(1)

    private func family(_ level: GhostLevel) -> ProcessFamily {
        RefreshPerformanceFixture.family(root, level: level)
    }

    private func level(after hysteresis: inout RadarHysteresis, _ level: GhostLevel, at seconds: TimeInterval) -> ProcessFamily {
        hysteresis.apply(to: [family(level)], now: t0.addingTimeInterval(seconds))[0]
    }

    func testHoldsAtWatchOrAboveForTheWholeHoldAfterTheLastHotTick() {
        var hysteresis = RadarHysteresis()
        XCTAssertEqual(level(after: &hysteresis, .hot, at: 0).score.level, .hot)
        for seconds in [1.0, 2, 19, 21, 40] {
            let held = level(after: &hysteresis, .quiet, at: seconds)
            XCTAssertGreaterThanOrEqual(held.score.level, .watch, "t0+\(seconds)")
            XCTAssertEqual(held.score.heat.level, held.score.level)
            XCTAssertTrue(held.score.reasons.contains(RadarHysteresis.holdReason))
        }
        let released = level(after: &hysteresis, .quiet, at: 41)
        XCTAssertEqual(released.score.level, .quiet)
        XCTAssertFalse(released.score.reasons.contains(RadarHysteresis.holdReason))
    }

    func testBurstyRunawayNeverDropsBelowWatch() {
        var hysteresis = RadarHysteresis()
        let pattern: [(GhostLevel, TimeInterval)] = [(.hot, 0), (.quiet, 5), (.hot, 12), (.quiet, 20), (.quiet, 30), (.hot, 31)]
        for (input, seconds) in pattern {
            XCTAssertGreaterThanOrEqual(level(after: &hysteresis, input, at: seconds).score.level, .watch, "t0+\(seconds)")
        }
    }

    func testFamilyThatWasNeverHotIsUntouched() {
        var hysteresis = RadarHysteresis()
        XCTAssertEqual(level(after: &hysteresis, .quiet, at: 0).score.level, .quiet)
        XCTAssertEqual(level(after: &hysteresis, .watch, at: 1).score.level, .watch)
        XCTAssertEqual(level(after: &hysteresis, .quiet, at: 2).score.level, .quiet)
    }

    func testHoldDoesNotSurviveAbsence() {
        let other = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(2))
        for returning in [GhostLevel.watch, .hot] {
            var hysteresis = RadarHysteresis()
            XCTAssertEqual(level(after: &hysteresis, .critical, at: 0).score.level, .critical)
            for seconds in stride(from: 3.0, through: 600, by: 3) {
                _ = hysteresis.apply(to: [other], now: t0.addingTimeInterval(seconds))
            }
            let back = level(after: &hysteresis, returning, at: 630)
            XCTAssertEqual(back.score.level, returning)
            XCTAssertFalse(back.score.reasons.contains(RadarHysteresis.holdReason))
        }
    }

    func testShortAbsenceKeepsTheHold() {
        var hysteresis = RadarHysteresis()
        let other = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(2))
        XCTAssertEqual(level(after: &hysteresis, .critical, at: 0).score.level, .critical)
        _ = hysteresis.apply(to: [other], now: t0.addingTimeInterval(6))
        let back = level(after: &hysteresis, .watch, at: 12)
        XCTAssertEqual(back.score.level, .critical)
        XCTAssertTrue(back.score.reasons.contains(RadarHysteresis.holdReason))
    }
}
