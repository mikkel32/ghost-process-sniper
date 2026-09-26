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

    func testHoldsAtWatchForTheWholeHoldAfterTheLastHotTick() {
        var hysteresis = RadarHysteresis()
        XCTAssertEqual(level(after: &hysteresis, .hot, at: 0).score.level, .hot)
        for seconds in [1.0, 2, 19] {
            let held = level(after: &hysteresis, .quiet, at: seconds)
            XCTAssertEqual(held.score.level, .watch, "t0+\(seconds)")
            XCTAssertEqual(held.score.heat.level, .watch)
            XCTAssertTrue(held.score.reasons.contains("held briefly to avoid flicker"))
        }
        let released = level(after: &hysteresis, .quiet, at: 21)
        XCTAssertEqual(released.score.level, .quiet)
        XCTAssertFalse(released.score.reasons.contains("held briefly to avoid flicker"))
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
}
