import XCTest
@testable import GhostProcessSniperCore

final class RadarSchedulerTests: XCTestCase {
    func testPlanIsUIVisibleOnlyWhileThePopoverIsOpen() {
        var scheduler = RadarScheduler()
        let visible = scheduler.plan(settings: .smart, families: [], popoverVisible: true,
            now: RefreshPerformanceFixture.now)
        let hidden = scheduler.plan(settings: .smart, families: [], popoverVisible: false,
            now: RefreshPerformanceFixture.now.addingTimeInterval(1))
        XCTAssertTrue(visible.uiVisible)
        XCTAssertFalse(hidden.uiVisible)
    }

    func testDirectlyBuiltPlansDefaultToHidden() {
        XCTAssertFalse(SamplingPlan.balanced(now: RefreshPerformanceFixture.now).uiVisible)
    }
}
