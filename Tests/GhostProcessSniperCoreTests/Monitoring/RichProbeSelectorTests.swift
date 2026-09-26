import XCTest
@testable import GhostProcessSniperCore

final class RichProbeSelectorTests: XCTestCase {
    func testEveryQuietProcessGetsProbedOnAStableList() {
        let priorities = [Int](repeating: 0, count: 552)
        var observed: Set<Int> = []
        for pass in 0..<18 {
            let selected = RichProbeSelector.indices(priorities: priorities, budget: 32, pass: UInt64(pass))
            XCTAssertEqual(selected.count, 32)
            XCTAssertEqual(Set(selected).count, selected.count)
            observed.formUnion(selected)
        }
        XCTAssertEqual(observed.count, 552)
    }

    func testDeveloperHintsCannotStarveAppDiscovery() {
        let priorities = [Int](repeating: 1, count: 64) + [Int](repeating: 0, count: 64)
        var discovered: Set<Int> = []
        for pass in 0..<8 {
            let selected = RichProbeSelector.indices(priorities: priorities, budget: 32, pass: UInt64(pass))
            XCTAssertEqual(selected.count, 32)
            discovered.formUnion(selected.filter { priorities[$0] == 0 })
        }
        XCTAssertEqual(discovered.count, 64)
    }

    func testExplicitFocusPrecedesDeveloperHints() {
        let priorities = [Int](repeating: 1, count: 40) + [2] + [Int](repeating: 0, count: 20)
        let selected = RichProbeSelector.indices(priorities: priorities, budget: 16, pass: 0)
        XCTAssertEqual(selected.first, 40)
        XCTAssertTrue(selected.contains { priorities[$0] == 0 })
        XCTAssertEqual(selected.count, 16)
    }

    func testBudgetBoundariesAndEmptyInputs() {
        XCTAssertTrue(RichProbeSelector.indices(priorities: [2, 1, 0], budget: 0, pass: 0).isEmpty)
        XCTAssertTrue(RichProbeSelector.indices(priorities: [], budget: 32, pass: 0).isEmpty)
        XCTAssertTrue(RichProbeSelector.indices(priorities: [2], budget: -1, pass: 0).isEmpty)
        XCTAssertEqual(Set(RichProbeSelector.indices(priorities: [2, 1, 0], budget: 50, pass: .max)), [0, 1, 2])
    }

    func testSingleSlotRotatesBothPriorityAndDiscovery() {
        let priorities = [2, 2, 0, 0]
        let selected = (0..<8).flatMap { RichProbeSelector.indices(priorities: priorities, budget: 1, pass: UInt64($0)) }
        XCTAssertEqual(Set(selected), [0, 1, 2, 3])
    }
}
