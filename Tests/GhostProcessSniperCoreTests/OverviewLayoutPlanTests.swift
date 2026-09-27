import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class OverviewLayoutPlanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 50_000)

    /// The Live Radar follows the queues it draws, so it starts on screen
    /// instead of below the tiles and thermals.
    func testQueuesStayAboveThermalsUntilTheMacIsHot() {
        XCTAssertEqual(OverviewLayoutPlan.sections(thermal: .normal), [.verdict, .queues, .analytics, .metrics, .thermals])
        XCTAssertEqual(OverviewLayoutPlan.sections(thermal: .elevated), [.verdict, .thermals, .queues, .analytics, .metrics])
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

    func testAWindowAlreadyVeryHotPromotesOnTheFirstUpdate() {
        var tracker = OverviewThermalBandTracker()
        let temperature = assessment(after: [(0, 91), (10, 93), (20, 94), (30, 92)])
        XCTAssertEqual(temperature.trajectory.veryHotSeconds, 30)
        XCTAssertEqual(tracker.update(thermalState: .normal, temperature: temperature, at: start.addingTimeInterval(30)), .elevated,
                       "the console opened on 30 s of readings at 90 °C or more")
    }

    func testOneVeryHotSpikeAfterHotReadingsDoesNotPromote() {
        var tracker = OverviewThermalBandTracker()
        let temperature = assessment(after: [(0, 85), (10, 85), (20, 85), (30, 85), (40, 91)])
        XCTAssertGreaterThanOrEqual(temperature.trajectory.hotSeconds, 30, "hot for 40 s, very hot only now")
        XCTAssertEqual(tracker.update(thermalState: .normal, temperature: temperature, at: start.addingTimeInterval(40)), .normal)
    }

    /// The assessment at the last reading, from a window that recorded every reading as it came.
    private func assessment(after readings: [(offset: TimeInterval, celsius: Double)]) -> ThermalTemperatureAssessment {
        var window = ThermalObservationWindow()
        var snapshot: ThermalSnapshot?
        for reading in readings {
            let date = start.addingTimeInterval(reading.offset)
            let next = ThermalSnapshot(sampledAt: date, cpuCelsius: reading.celsius, gpuCelsius: nil, sensorCount: 1,
                                       sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
            window.record(next, at: date)
            snapshot = next
        }
        let last = snapshot!
        return ThermalTemperatureAssessment.evaluate(snapshot: last, observations: window, at: last.sampledAt)
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
