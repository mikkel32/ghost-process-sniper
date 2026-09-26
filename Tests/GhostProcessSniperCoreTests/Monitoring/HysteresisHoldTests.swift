import XCTest
@testable import GhostProcessSniperCore

final class HysteresisHoldTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testHotHoldsUntilTheLowerReadingHasLastedTheHoldDuration() throws {
        // 1.7 GB for three ticks, then 800 MB from t = 15 s.
        let levels = try run(megabytes: [1_700, 1_700, 1_700, 800, 800, 800, 800, 800, 800, 800])
        XCTAssertEqual(Array(levels.prefix(3)), [.hot, .hot, .hot])
        XCTAssertEqual(Array(levels[3...6]), [.hot, .hot, .hot, .hot], "held for 20 s after the first lower reading")
        XCTAssertEqual(levels[7], .watch, "then one step down")
    }

    func testEachStepDownIsHeldToo() throws {
        let levels = try run(megabytes: [1_700, 1_700, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100])
        XCTAssertEqual(levels[2], .hot)
        XCTAssertEqual(levels[6], .watch, "hot steps to watch 20 s after the drop")
        XCTAssertEqual(levels[9], .watch, "watch is held for another 20 s")
        XCTAssertEqual(levels[10], .quiet)
    }

    func testIgnoreRuleDropsTheLevelAtOnce() throws {
        let ignore = RadarRule(name: "Ignore node", match: RadarRuleMatch(commandContains: "server.js", minimumLevel: .quiet),
                               action: .ignore)
        let levels = try run(megabytes: [1_700, 1_700, 1_700, 800], rulesFrom: 3, rules: [ignore])
        XCTAssertEqual(levels[2], .hot)
        XCTAssertEqual(levels[3], .quiet)
    }

    private func run(megabytes: [Double], rulesFrom: Int = .max, rules: [RadarRule] = []) throws -> [GhostLevel] {
        var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: 501))
        return try megabytes.enumerated().map { tick, value in
            let date = Fixture.now.addingTimeInterval(Double(tick) * 5)
            let process = Fixture.process(pid: 45_000, megabytes: value, date: date)
            let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: tick >= rulesFrom ? rules : [])
            let output = pipeline.run(processes: [process], settings: .smart, context: context, now: date)
            return try XCTUnwrap(output.families.first { $0.root.pid == 45_000 }).score.level
        }
    }
}
