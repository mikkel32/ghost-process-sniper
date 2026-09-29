import XCTest
@testable import GhostProcessSniperCore

/// One notification per episode: a family that stays Hot alerts once, not
/// every quarter hour, and steady families never take a new one's slot.
final class FamilyAlertGateTests: XCTestCase {
    private typealias Candidate = FamilyAlertGate.Candidate
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    private func candidate(_ id: String, _ level: GhostLevel = .hot) -> Candidate {
        Candidate(id: id, level: level)
    }

    /// Plans a pass and marks what it offered delivered, as the notifier does once `add` succeeds.
    private func alert(_ gate: inout FamilyAlertGate, _ candidates: [Candidate], after seconds: TimeInterval) -> [String] {
        let now = t0.addingTimeInterval(seconds)
        let ids = gate.plan(candidates, now: now)
        for id in ids {
            gate.delivered(id, level: candidates.first { $0.id == id }?.level ?? .hot, at: now)
        }
        return ids
    }

    func testAPersistentlyHotFamilyAlertsOnceNotEveryFifteenMinutes() {
        var gate = FamilyAlertGate()
        let hot = [candidate("a")]
        XCTAssertEqual(alert(&gate, hot, after: 0), ["a"])
        for seconds in [15 * 60, 30 * 60, 3_600, 12 * 3_600 - 60] as [TimeInterval] {
            XCTAssertEqual(alert(&gate, hot, after: seconds), [], "still hot after \(seconds) s, already told")
        }
        XCTAssertEqual(alert(&gate, hot, after: 12 * 3_600), ["a"], "a slow reminder once a half day has passed")
        XCTAssertEqual(alert(&gate, hot, after: 12 * 3_600 + 15 * 60), [])
    }

    func testEscalationAlertsAgainButNotWithinFiveMinutes() {
        var gate = FamilyAlertGate()
        XCTAssertEqual(alert(&gate, [candidate("a", .hot)], after: 0), ["a"])
        XCTAssertEqual(alert(&gate, [candidate("a", .critical)], after: 120), [], "too soon after the first alert")
        XCTAssertEqual(alert(&gate, [candidate("a", .critical)], after: 360), ["a"], "worse, and five minutes on")
        // Bouncing between the levels is not news once Critical has been announced.
        XCTAssertEqual(alert(&gate, [candidate("a", .hot)], after: 720), [])
        XCTAssertEqual(alert(&gate, [candidate("a", .critical)], after: 1_200), [])
    }

    func testAFourthFamilyIsNotStarvedBySteadyOnes() {
        var gate = FamilyAlertGate()
        let steady = ["a", "b", "c"].map { candidate($0) }
        XCTAssertEqual(alert(&gate, steady, after: 0), ["a", "b", "c"])
        let withFourth = steady + [candidate("d", .critical)]
        XCTAssertEqual(alert(&gate, withFourth, after: 3_600), ["d"],
                       "the three that already alerted no longer use up the passes")
        XCTAssertEqual(alert(&gate, withFourth, after: 3_660), [])
    }

    func testABurstIsSpreadOverARollingBudgetMostUrgentFirst() {
        var gate = FamilyAlertGate()
        let burst = ["a", "b", "c", "d", "e", "f", "g", "h"].map { candidate($0) }
        XCTAssertEqual(alert(&gate, burst, after: 0), ["a", "b", "c"], "a launch does not post a banner per family")
        XCTAssertEqual(alert(&gate, burst, after: 1), [])
        XCTAssertEqual(alert(&gate, burst, after: 300), [])
        XCTAssertEqual(alert(&gate, burst, after: 601), ["d", "e", "f"], "the next three once the window frees")
        XCTAssertEqual(alert(&gate, burst, after: 1_202), ["g", "h"])
        XCTAssertEqual(alert(&gate, burst, after: 1_900), [])
    }

    func testAFamilyThatDipsAndReturnsIsTheSameEpisode() {
        var gate = FamilyAlertGate()
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 0), ["a"])
        XCTAssertEqual(alert(&gate, [], after: 30), [])
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 90), [], "back inside the grace period: not news")
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 3_600), [])
    }

    func testAFamilyThatLeftAndComesBackWaitsOutTheCooldown() {
        var gate = FamilyAlertGate()
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 0), ["a"])
        XCTAssertEqual(alert(&gate, [], after: 200), [], "gone for over two minutes: the episode ends")
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 600), [], "flapping inside 30 minutes stays quiet")
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 29 * 60), [])
        XCTAssertEqual(alert(&gate, [candidate("a")], after: 31 * 60), ["a"], "still trouble after the cooldown")
    }

    func testAFamilyTheNotifierNeverDeliveredIsOfferedAgain() {
        var gate = FamilyAlertGate()
        let hot = [candidate("a")]
        // No `delivered` call: permission was not granted yet.
        XCTAssertEqual(gate.plan(hot, now: t0), ["a"])
        XCTAssertEqual(gate.plan(hot, now: t0.addingTimeInterval(1)), ["a"])
        XCTAssertEqual(alert(&gate, hot, after: 2), ["a"])
        XCTAssertEqual(gate.plan(hot, now: t0.addingTimeInterval(3)), [])
    }

    func testAnUndeliveredOfferDoesNotUseTheBudget() {
        var gate = FamilyAlertGate()
        let burst = ["a", "b", "c", "d"].map { candidate($0) }
        XCTAssertEqual(gate.plan(burst, now: t0), ["a", "b", "c"])
        XCTAssertEqual(gate.plan(burst, now: t0.addingTimeInterval(1)), ["a", "b", "c"], "nothing was delivered yet")
    }

    func testTheSameFamilyListedTwiceIsOneAlert() {
        var gate = FamilyAlertGate()
        XCTAssertEqual(gate.plan([candidate("a"), candidate("a", .critical), candidate("b")], now: t0), ["a", "b"])
    }

    func testMemoryStaysBoundedAsFamiliesComeAndGo() {
        var gate = FamilyAlertGate()
        for index in 0..<200 {
            _ = alert(&gate, [candidate("app\(index)")], after: Double(index) * 3_600)
        }
        XCTAssertLessThanOrEqual(gate.trackedCount, 2, "only the current family and one cooldown entry remain")
        _ = gate.plan([], now: t0.addingTimeInterval(500 * 3_600))
        XCTAssertEqual(gate.trackedCount, 0)
    }
}
