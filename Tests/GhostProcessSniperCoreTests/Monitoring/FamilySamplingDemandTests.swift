import XCTest
@testable import GhostProcessSniperCore

final class FamilySamplingDemandTests: XCTestCase {
    func testPriorityKeysPlusSelectionDoNotExpandToEveryMatchingSibling() {
        let families = (0..<256).map { index in
            RefreshPerformanceFixture.family(
                RefreshPerformanceFixture.process(0, pid: Int32(40_000 + index)))
        }
        XCTAssertEqual(Set(families.map(\.signature.id)).count, 1)
        var focusedKeys = Set(families.prefix(8).map(\.familyKey))
        focusedKeys.insert(families.last!.familyKey)
        let demand = FamilySamplingDemand(families: families, focusedKeys: focusedKeys)
        XCTAssertEqual(demand.focusedFamilyCount, 9)
        XCTAssertEqual(demand.candidateIdentities.count, 9)
        XCTAssertEqual(demand.forensicsIdentities.count, 9)
        XCTAssertTrue(demand.candidateIdentities.contains(families.last!.root.identity))
    }

    func testRuntimeKeyFocusesOnlyTheSelectedInstance() {
        let a = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(0))
        let b = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(1))
        XCTAssertEqual(a.signature.id, b.signature.id)
        let demand = FamilySamplingDemand(families: [a, b], focusedKeys: [b.familyKey])
        XCTAssertEqual(demand.focusedFamilyCount, 1)
        XCTAssertEqual(demand.candidateIdentities, [b.root.identity])
        XCTAssertEqual(demand.forensicsIdentities, [b.root.identity])
        XCTAssertEqual(demand.reason, "focused-family")
    }

    func testLogicalSignatureRetainsAllMatchingInstances() {
        let a = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(0))
        let b = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(1))
        let demand = FamilySamplingDemand(families: [a, b], focusedKeys: [a.signature.id])
        XCTAssertEqual(demand.focusedFamilyCount, 2)
        XCTAssertEqual(demand.candidateIdentities, [a.root.identity, b.root.identity])
    }

    func testExpiredRuntimeKeyDoesNotFocusARecycledPID() {
        let old = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(0))
        let replacement = RefreshPerformanceFixture.family(
            RefreshPerformanceFixture.process(0, start: 1_999_999_000))
        let demand = FamilySamplingDemand(families: [replacement], focusedKeys: [old.familyKey])
        XCTAssertTrue(demand.candidateIdentities.isEmpty)
        XCTAssertEqual(demand.focusedFamilyCount, 0)
    }

    func testHotFocusedAndWatchingFamiliesKeepDistinctBudgets() {
        let child = RefreshPerformanceFixture.process(7)
        let root = RefreshPerformanceFixture.process(0)
        let hot = RefreshPerformanceFixture.family(root, members: [root, child], level: .hot)
        let watch = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(2), level: .watch)
        let quiet = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(4))
        let demand = FamilySamplingDemand(families: [hot, watch, quiet], focusedKeys: [hot.familyKey])
        XCTAssertEqual(demand.highestLevel, .hot)
        XCTAssertEqual(demand.hotFamilyCount, 1)
        XCTAssertEqual(demand.focusedFamilyCount, 1)
        XCTAssertEqual(demand.candidateIdentities, [root.identity, child.identity, watch.root.identity])
        XCTAssertEqual(demand.forensicsIdentities, [root.identity, child.identity])
        XCTAssertEqual(demand.reason, "hot-family")
    }

    func testSchedulerUsesRuntimeDemandInItsActualSamplingPlan() {
        let family = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(0))
        var scheduler = RadarScheduler()
        let plan = scheduler.plan(settings: .smart, families: [family], popoverVisible: true,
            focusedSignatureIDs: [family.familyKey], now: RefreshPerformanceFixture.now)
        XCTAssertEqual(plan.candidateSet.identities, [family.root.identity])
        XCTAssertEqual(plan.includeForensicsFor, [family.root.identity])
        XCTAssertEqual(plan.reason, "focused-family")
    }

    func testEmptyDemandDoesNotRetainOldSelection() {
        let demand = FamilySamplingDemand(families: [], focusedKeys: ["gone"])
        XCTAssertEqual(demand.highestLevel, .quiet)
        XCTAssertTrue(demand.candidateIdentities.isEmpty)
        XCTAssertTrue(demand.forensicsIdentities.isEmpty)
        XCTAssertEqual(demand.reason, "steady-state")
    }
}
