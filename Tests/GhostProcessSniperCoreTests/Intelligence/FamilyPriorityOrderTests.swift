import XCTest
@testable import GhostProcessSniperCore

final class FamilyPriorityOrderTests: XCTestCase {
    private typealias Fixture = RefreshPerformanceFixture

    func testEqualFamiliesSortByNameWhateverTheInputOrder() {
        // Same footprint and CPU, different names (tool-0 and tool-5).
        let first = Fixture.family(Fixture.process(0))
        let second = Fixture.family(Fixture.process(10))
        let forward = [second, first].sorted(by: FamilyPriorityOrder.areInIncreasingOrder)
        let reverse = [first, second].sorted(by: FamilyPriorityOrder.areInIncreasingOrder)
        XCTAssertEqual(forward.map(\.displayName), ["tool-0", "tool-5"])
        XCTAssertEqual(reverse.map(\.displayName), ["tool-0", "tool-5"])
    }

    func testNewAlertOutranksAnEqualLevelFamilyWithoutOne() {
        let quiet = Fixture.family(Fixture.process(0), level: .hot)
        let alerted = Fixture.family(Fixture.process(10), level: .hot)
            .enriched(alertState: AlertState(kind: .new, message: "New", since: Fixture.now))
        let sorted = [quiet, alerted].sorted(by: FamilyPriorityOrder.areInIncreasingOrder)
        XCTAssertEqual(sorted.first?.displayName, "tool-5")
    }

    func testForecastStateOutranksLevel() {
        let hot = Fixture.family(Fixture.process(0), level: .hot)
        let leaking = RiskForecast(state: .leaking, horizon: .soon, confidence: 0.8, etaSeconds: 600,
            etaText: "10 min", whyNow: "", recommendedAction: RiskForecast.quiet.recommendedAction,
            projectedMemoryBytes: 0, projectedCPUPercent: 0, leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0, staleLikelihood: 0, baseline: .unknown, generatedAt: Fixture.now)
        let forecast = Fixture.family(Fixture.process(10), level: .watch).enriched(forecast: leaking)
        let sorted = [hot, forecast].sorted(by: FamilyPriorityOrder.areInIncreasingOrder)
        XCTAssertEqual(sorted.first?.displayName, "tool-5")
    }
}
