import XCTest
@testable import GhostProcessSniperCore

final class ScoringCacheRuleTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private let family = Fixture.family(Fixture.process(pid: 44_000, command: "node vite"))

    func testEditingARuleMatchMissesTheCache() {
        var rule = RadarRule(name: "Watch vite", match: RadarRuleMatch(commandContains: "vite"), action: .highlight)
        var cache = FamilyScoringCache()
        cache.store(family, context: context(rule), now: Fixture.now)
        XCTAssertNotNil(cache.cachedFamily(for: family, context: context(rule), now: Fixture.now))

        rule.match.commandContains = "webpack"
        XCTAssertNil(cache.cachedFamily(for: family, context: context(rule), now: Fixture.now))
    }

    func testExpiredSnoozeMissesTheCache() {
        let expiry = Fixture.now.addingTimeInterval(30)
        let snooze = RadarRule(name: "Snooze vite", match: RadarRuleMatch(commandContains: "vite"),
                               action: .snooze, expiresAt: expiry)
        var cache = FamilyScoringCache()
        cache.store(family, context: context(snooze), now: Fixture.now)
        XCTAssertNotNil(cache.cachedFamily(for: family, context: context(snooze), now: Fixture.now.addingTimeInterval(29)))
        XCTAssertNil(cache.cachedFamily(for: family, context: context(snooze), now: expiry))
    }

    func testPipelineDropsASnoozeAsSoonAsItExpires() throws {
        // Late enough that the history has settled and the cache would hit.
        let expiry = Fixture.now.addingTimeInterval(25)
        let snooze = RadarRule(name: "Snooze vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .quiet),
                               action: .snooze, expiresAt: expiry)
        var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: 501))
        var states: [AlertStateKind] = []
        for tick in 0..<7 {
            let date = Fixture.now.addingTimeInterval(Double(tick) * 5)
            let root = Fixture.process(pid: 44_010, command: "node node_modules/.bin/vite", date: date)
            let output = pipeline.run(processes: [root], settings: .smart, context: context(snooze), now: date)
            states.append(try XCTUnwrap(output.families.first { $0.root.pid == 44_010 }).alertState.kind)
        }
        XCTAssertEqual(states, [.snoozed, .snoozed, .snoozed, .snoozed, .snoozed, .normal, .normal])
    }

    private func context(_ rule: RadarRule) -> RadarContext {
        RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [rule])
    }
}
