import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class RadarPresentationTests: XCTestCase {
    func testContinuousMotionNeedsEveryVisibilityAndPowerGate() {
        XCTAssertTrue(RadarMotionPolicy.runsContinuousMotion(reduceMotion: false, lowPower: false, inViewport: true, windowVisible: true, applicationActive: true))
        for gate in 0..<5 {
            XCTAssertFalse(RadarMotionPolicy.runsContinuousMotion(reduceMotion: gate == 0, lowPower: gate == 1,
                                                                 inViewport: gate != 2, windowVisible: gate != 3, applicationActive: gate != 4))
        }
    }

    func testQuietSummaryProducesNoWarningChips() {
        let summary = RadarSummary(statusText: "Quiet", level: .quiet, familyCount: 12, hotCount: 0,
                                   totalMemoryBytes: 6_000_000_000, topFamilyName: "node")
        let model = OverviewCommandCenterModel(summary: summary, engineStatus: .empty)
        for chip in model.chips {
            XCTAssertEqual(chip.level, .quiet, "\(chip.title) should not warn on an idle Mac")
        }
    }

    func testEveryCommandCenterChipHasItsOwnDestination() {
        let summary = RadarSummary(statusText: "2 hot", level: .hot, familyCount: 12, hotCount: 2,
                                   totalMemoryBytes: 6_000_000_000, topFamilyName: "node", leakingCount: 1)
        let chips = OverviewCommandCenterModel(summary: summary, engineStatus: .empty, duplicateCount: 3).chips
        let destinations = chips.compactMap(\.destination)
        XCTAssertEqual(destinations.count, chips.count, "every dashboard card should lead somewhere")
        for (index, destination) in destinations.enumerated() {
            XCTAssertFalse(destinations[(index + 1)...].contains(destination), "\(destination) is used twice")
        }
        XCTAssertTrue(chips.allSatisfy { $0.actionTitle?.isEmpty == false })
    }

    func testRadarBearingIsStableAndUrgencyMovesInward() {
        let quiet = RadarScopeGeometry.position(key: "node|pid:10", urgency: 0, width: 320, height: 240)
        let urgent = RadarScopeGeometry.position(key: "node|pid:10", urgency: 100, width: 320, height: 240)
        let center = CGPoint(x: 160, y: 120)
        XCTAssertEqual(RadarScopeGeometry.angle(for: "node|pid:10"), RadarScopeGeometry.angle(for: "node|pid:10"))
        XCTAssertGreaterThan(hypot(quiet.x - center.x, quiet.y - center.y), hypot(urgent.x - center.x, urgent.y - center.y))
        XCTAssertEqual(atan2(quiet.y - center.y, quiet.x - center.x), atan2(urgent.y - center.y, urgent.x - center.x), accuracy: 0.00001)
    }

    func testRadarGeometryHandlesTinyAndInvalidBounds() {
        for urgency in [Double.nan, .infinity, -100, 10_000] {
            let point = RadarScopeGeometry.position(key: "tiny", urgency: urgency, width: 1, height: 1)
            XCTAssertEqual(point, CGPoint(x: 0.5, y: 0.5))
        }
        let invalid = RadarScopeGeometry.position(key: "bad", urgency: 50, width: .nan, height: -.infinity)
        XCTAssertEqual(invalid, .zero)
    }
}
