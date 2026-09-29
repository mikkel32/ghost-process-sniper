import XCTest
@testable import GhostProcessSniperCore

/// The sidebar's Duplicates and Incidents tiles carry a count badge that has
/// to fit a third of the sidebar's width.
final class CountBadgeTests: XCTestCase {
    func testAZeroCountShowsNoBadge() {
        XCTAssertNil(RadarFormat.badge(0))
        XCTAssertNil(RadarFormat.badge(-3), "a negative count is nothing to show")
    }

    func testSmallCountsShowAsWritten() {
        XCTAssertEqual(RadarFormat.badge(1), "1")
        XCTAssertEqual(RadarFormat.badge(7), "7")
        XCTAssertEqual(RadarFormat.badge(99), "99")
    }

    func testBigCountsAreCappedSoTheBadgeStaysNarrow() {
        XCTAssertEqual(RadarFormat.badge(100), "99+")
        XCTAssertEqual(RadarFormat.badge(250), "99+")
        XCTAssertEqual(RadarFormat.badge(Int.max), "99+")
    }
}
