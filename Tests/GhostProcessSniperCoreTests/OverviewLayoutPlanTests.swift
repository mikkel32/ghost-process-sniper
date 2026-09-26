import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class OverviewLayoutPlanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 50_000)

    func testQueuesStayAboveThermalsUntilTheMacIsHot() {
        XCTAssertEqual(OverviewLayoutPlan.sections(thermal: .normal), [.verdict, .queues, .metrics, .thermals, .analytics])
        XCTAssertEqual(OverviewLayoutPlan.sections(thermal: .elevated), [.verdict, .thermals, .queues, .metrics, .analytics])
    }

    func testOrdinaryHotReadingsNeverPromoteThermals() {
        var tracker = OverviewThermalBandTracker()
        for (step, celsius) in [79.0, 81, 77, 75, 85, 88, 89].enumerated() {
            XCTAssertEqual(update(&tracker, celsius, at: Double(step) * 10), .normal, "\(celsius) °C")
        }
    }

    func testVeryHotMustHoldForThirtySeconds() {
        var tracker = OverviewThermalBandTracker()
        XCTAssertEqual(update(&tracker, 94, at: 0), .normal)
        XCTAssertEqual(update(&tracker, 95, at: 15), .normal)
        XCTAssertEqual(update(&tracker, 93, at: 29), .normal)
        XCTAssertEqual(update(&tracker, 92, at: 30), .elevated)
    }

    func testABriefDipRestartsTheVeryHotClock() {
        var tracker = OverviewThermalBandTracker()
        XCTAssertEqual(update(&tracker, 95, at: 0), .normal)
        XCTAssertEqual(update(&tracker, 85, at: 10), .normal)
        XCTAssertEqual(update(&tracker, 95, at: 20), .normal)
        XCTAssertEqual(update(&tracker, 95, at: 35), .normal)
        XCTAssertEqual(update(&tracker, 95, at: 50), .elevated)
    }

    func testOSThrottlingPromotesAtOnce() {
        var tracker = OverviewThermalBandTracker()
        XCTAssertEqual(update(&tracker, 60, state: .serious, at: 0), .elevated)
        var critical = OverviewThermalBandTracker()
        XCTAssertEqual(update(&critical, nil, state: .critical, at: 0), .elevated)
    }

    func testReturnsToNormalOnlyAfterAMinuteOfCalm() {
        var tracker = OverviewThermalBandTracker()
        XCTAssertEqual(update(&tracker, 70, state: .serious, at: 0), .elevated)
        XCTAssertEqual(update(&tracker, 81, state: .warm, at: 10), .elevated)
        XCTAssertEqual(update(&tracker, 77, at: 25), .elevated)
        XCTAssertEqual(update(&tracker, 75, at: 40), .elevated)
        XCTAssertEqual(update(&tracker, 75, at: 55), .elevated)
        XCTAssertEqual(update(&tracker, 75, at: 69), .elevated)
        XCTAssertEqual(update(&tracker, 75, at: 70), .normal)
    }

    func testRenewedHeatResetsTheCalmClock() {
        var tracker = OverviewThermalBandTracker()
        XCTAssertEqual(update(&tracker, 70, state: .serious, at: 0), .elevated)
        XCTAssertEqual(update(&tracker, 75, at: 10), .elevated)
        XCTAssertEqual(update(&tracker, 92, at: 50), .elevated, "very hot is not calm")
        for offset in stride(from: 60.0, through: 110, by: 10) {
            XCTAssertEqual(update(&tracker, 75, at: offset), .elevated)
        }
        XCTAssertEqual(update(&tracker, 75, at: 120), .normal)
    }

    func testAGapInReadingsDoesNotCountAsSustainedHeat() {
        var tracker = OverviewThermalBandTracker()
        XCTAssertEqual(update(&tracker, 95, at: 0), .normal)
        XCTAssertEqual(update(&tracker, 95, at: 600), .normal, "the console was hidden in between")
        XCTAssertEqual(update(&tracker, 95, at: 615), .normal)
        XCTAssertEqual(update(&tracker, 95, at: 630), .elevated)
    }

    private func update(
        _ tracker: inout OverviewThermalBandTracker,
        _ celsius: Double?,
        state: ThermalDiagnosis.State = .normal,
        at offset: TimeInterval
    ) -> OverviewThermalBand {
        let temperature = ThermalTemperatureAssessment(
            band: .classify(celsius), hottestCelsius: celsius, component: "CPU sensor", trajectory: .empty
        )
        return tracker.update(thermalState: state, temperature: temperature, at: start.addingTimeInterval(offset))
    }
}
