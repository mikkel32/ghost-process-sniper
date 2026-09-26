import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalInterpretationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)

    func testWarmHotAndVeryHotAreVisibleUnderNominalPressure() {
        for (value, band, label) in [(70.0, ThermalTemperatureBand.warm, "Warm"),
                                     (80.0, .hot, "Hot"), (90.0, .veryHot, "Very hot")] {
            let result = diagnose(cpu: value)
            XCTAssertEqual(result.state, .normal, "Keep the platform signal separate")
            XCTAssertEqual(result.temperature.band, band)
            XCTAssertEqual(result.reviewStatus, label)
            XCTAssertTrue(result.headline.contains(result.temperature.readingText))
            XCTAssertNotEqual(result.headline, "macOS reports normal thermal pressure")
        }
    }

    func testSeventyAndEightyAreReviewBoundariesNotFaultClaims() {
        XCTAssertEqual(diagnose(cpu: 69.9).temperature.band, .belowReview)
        XCTAssertEqual(diagnose(cpu: 79.9).temperature.band, .warm)
        XCTAssertEqual(diagnose(cpu: 89.9).temperature.band, .hot)
        for value in [70.0, 80.0, 90.0] {
            let result = diagnose(cpu: value)
            XCTAssertFalse(result.headline.localizedCaseInsensitiveContains("hardware fault"))
            XCTAssertNotEqual(result.state, .critical)
        }
    }

    func testStaleFutureAndInvalidSensorsNeverBecomeCurrentHeat() {
        for date in [now.addingTimeInterval(-16), now.addingTimeInterval(1)] {
            let result = ThermalDiagnosis.evaluate(snapshot: snapshot(90, at: date), activity: .empty, at: now)
            XCTAssertEqual(result.temperature.band, .unavailable)
            XCTAssertEqual(result.state, .checking)
        }
        for value in [Double.nan, .infinity, -1, 0, 200] {
            XCTAssertEqual(diagnose(cpu: value).temperature.band, .unavailable)
        }
    }

    func testUnknownPressureDoesNotHideAValidHotReading() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(84, state: "Unknown"), activity: .empty, at: now)
        XCTAssertEqual(result.state, .checking)
        XCTAssertEqual(result.temperature.band, .hot)
        XCTAssertEqual(result.reviewStatus, "Hot")
        XCTAssertTrue(result.pressureText.contains("Unavailable"))
    }

    func testReadableGPUSensorWorksWithoutCPU() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(nil, gpu: 84), activity: .empty, at: now)
        XCTAssertEqual(result.temperature.hottestCelsius, 84)
        XCTAssertEqual(result.temperature.component, "GPU sensor")
        XCTAssertEqual(result.reviewStatus, "Hot")
    }

    func testCriticalAndSeriousPressureOverrideLowOrMissingSensors() {
        for (name, state) in [("Serious", ThermalDiagnosis.State.serious), ("Critical", .critical)] {
            let result = ThermalDiagnosis.evaluate(snapshot: snapshot(nil, state: name), activity: .empty, at: now)
            XCTAssertEqual(result.state, state)
            XCTAssertTrue(result.reviewStatus.lowercased().contains("pressure"))
            XCTAssertFalse(result.headline.contains("Waiting"))
        }
    }

    func testWeakLeaderDoesNotBecomeTheExplanationForEightyDegrees() {
        let result = insight(temperature: 80, activity: activity(cpu: 5))
        XCTAssertEqual(result.kind, .modest)
        XCTAssertTrue(result.action.contains("does not clearly explain the heat"))
        XCTAssertFalse(result.title.contains("Start with"))
    }

    func testIncompleteCoverageIsDisclosedAndNeverBecomesAnIdleDiagnosis() {
        let activity = activity(cpu: 5, missing: 8)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(82), activity: activity, at: now)
        XCTAssertTrue(diagnosis.coverageText.contains("1 of 9"))
        XCTAssertTrue(diagnosis.coverageText.contains("8 without either reading"))
        let result = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: now)
        XCTAssertEqual(result.kind, .modest)
        XCTAssertFalse(result.evidence.contains("idle"))
    }

    func testSubstantialActivityIsAPlausibleContributorAndNotAHeatShare() {
        let result = insight(temperature: 82, activity: activity(cpu: 200))
        XCTAssertEqual(result.kind, .active)
        XCTAssertEqual(result.title, "Start with Render")
        XCTAssertTrue(result.evidence.contains("the cause of heat is unconfirmed"))
        XCTAssertFalse(result.evidence.contains("of heat:"))
    }

    func testOldActivityCannotNameASuspect() {
        let activity = activity(cpu: 200, date: now.addingTimeInterval(-13))
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(82), activity: activity, at: now)
        XCTAssertFalse(diagnosis.isActivityFresh)
        let result = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: now)
        XCTAssertEqual(result.kind, .checking)
        XCTAssertNil(result.contributor)
        XCTAssertFalse(result.title.contains("Render"))
    }

    func testModestFirstPlaceAtLowTemperatureIsNotAProblemVerdict() {
        let result = insight(temperature: 55, activity: activity(cpu: 5))
        XCTAssertEqual(result.kind, .modest)
        XCTAssertTrue(result.action.contains("No demanding workload stands out"))
    }

    func testRepeatedTimerTicksDoNotCreateHistoryOrPersistence() {
        var window = ThermalObservationWindow()
        for seconds in 0...14 { window.record(snapshot(82), at: now.addingTimeInterval(Double(seconds))) }
        XCTAssertEqual(window.readings.count, 1)
        let result = ThermalTemperatureAssessment.evaluate(snapshot: snapshot(82), observations: window, at: now.addingTimeInterval(14))
        XCTAssertEqual(result.trajectory.direction, .measuring)
        XCTAssertEqual(result.trajectory.hotSeconds, 0)
    }

    func testRisingTemperatureUsesFourDistinctSamplesAndThirtySeconds() {
        let (window, latest) = history([70, 72, 76, 80])
        let result = ThermalDiagnosis.evaluate(snapshot: latest, activity: .empty, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.temperature.trajectory.direction, .rising)
        XCTAssertTrue(result.headline.contains("rising"))
        XCTAssertEqual(result.temperature.trajectory.spanSeconds, 30)
    }

    func testCoolingStillShowsTheCurrentHotBand() {
        let (window, latest) = history([92, 89, 85, 81])
        let result = ThermalDiagnosis.evaluate(snapshot: latest, activity: activity(cpu: 5, date: latest.sampledAt), observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.temperature.band, .hot)
        XCTAssertEqual(result.temperature.trajectory.direction, .falling)
        XCTAssertTrue(result.headline.contains("Cooling, but still"))
    }

    func testPersistentHeatNeedsContinuousSampleEvidence() {
        let (window, latest) = history(Array(repeating: 84, count: 7))
        let result = ThermalDiagnosis.evaluate(snapshot: latest, activity: .empty, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.temperature.trajectory.hotSeconds, 60)
        XCTAssertTrue(result.headline.contains("persisting"))
    }

    func testGapBreaksTrendAndPersistence() {
        var (window, _) = history([82, 84, 86, 88])
        let latest = snapshot(88, at: now.addingTimeInterval(60))
        window.record(latest, at: latest.sampledAt)
        XCTAssertEqual(window.readings.count, 1)
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.trajectory.direction, .measuring)
        XCTAssertEqual(result.trajectory.hotSeconds, 0)
    }

    func testInvalidSensorBreaksOnlyItsOwnHistory() {
        var window = ThermalObservationWindow()
        for index in 0..<5 {
            let reading = snapshot(index == 2 ? nil : 90, gpu: 80, at: now.addingTimeInterval(Double(index * 10)))
            window.record(reading, at: reading.sampledAt)
        }
        let latest = snapshot(90, gpu: 80, at: now.addingTimeInterval(40))
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.trajectory.direction, .measuring)
        XCTAssertEqual(result.trajectory.hotSeconds, 10)
    }

    func testTrendNeverComparesDifferentSensorsWhenTheHottestOneChanges() {
        var window = ThermalObservationWindow()
        let cpus = [72.0, 75, 78, 81]
        let gpus = [92.0, 88, 84, 79]
        for index in cpus.indices {
            let reading = snapshot(cpus[index], gpu: gpus[index], at: now.addingTimeInterval(Double(index * 10)))
            window.record(reading, at: reading.sampledAt)
        }
        let latest = snapshot(81, gpu: 79, at: now.addingTimeInterval(30))
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.component, "CPU sensor")
        XCTAssertEqual(result.trajectory.direction, .rising)
    }

    func testTrendResetsWhenTheHottestCPUSensorKeyChanges() {
        var window = ThermalObservationWindow()
        for (index, value) in [70.0, 72, 76, 80].enumerated() {
            let reading = ThermalSnapshot(sampledAt: now.addingTimeInterval(Double(index * 10)),
                cpuCelsius: value, gpuCelsius: nil, sensorCount: 2,
                sensorKeys: ["core-a", "core-b"], systemState: "Normal", unavailableReason: nil,
                cpuSensorKey: index < 2 ? "core-a" : "core-b")
            window.record(reading, at: reading.sampledAt)
        }
        let latest = ThermalSnapshot(sampledAt: now.addingTimeInterval(30), cpuCelsius: 80,
            gpuCelsius: nil, sensorCount: 2, sensorKeys: ["core-a", "core-b"],
            systemState: "Normal", unavailableReason: nil, cpuSensorKey: "core-b")
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window,
                                                            at: latest.sampledAt)
        XCTAssertEqual(result.trajectory.direction, .measuring)
        XCTAssertEqual(result.trajectory.spanSeconds, 10)
    }

    func testTrendSurvivesHottestCoreRotationWithinOneSensorSet() {
        var window = ThermalObservationWindow()
        var latest = snapshot(nil)
        for (index, value) in [70.0, 73, 76, 79, 82, 85, 88].enumerated() {
            latest = ThermalSnapshot(sampledAt: now.addingTimeInterval(Double(index * 10)),
                cpuCelsius: value, gpuCelsius: nil, sensorCount: 2, sensorKeys: ["Tp01", "Tp05"],
                systemState: "Normal", unavailableReason: nil,
                cpuSensorKey: index.isMultiple(of: 2) ? "Tp01" : "Tp05", cpuSeriesID: "cpu:Tp01,Tp05")
            window.record(latest, at: latest.sampledAt)
        }
        let result = ThermalDiagnosis.evaluate(snapshot: latest, activity: .empty, observations: window,
                                               at: latest.sampledAt)
        XCTAssertEqual(result.temperature.trajectory.direction, .rising)
        XCTAssertEqual(result.temperature.trajectory.spanSeconds, 60)
        XCTAssertGreaterThan(result.temperature.trajectory.hotSeconds, 0)
        XCTAssertTrue(result.headline.contains("rising"))
    }

    func testTrendResetsWhenTheSensorSetChanges() {
        var window = ThermalObservationWindow()
        var latest = snapshot(nil)
        for (index, value) in [70.0, 72, 76, 80].enumerated() {
            latest = ThermalSnapshot(sampledAt: now.addingTimeInterval(Double(index * 10)),
                cpuCelsius: value, gpuCelsius: nil, sensorCount: 2, sensorKeys: ["Tp01", "Tp05"],
                systemState: "Normal", unavailableReason: nil, cpuSensorKey: "Tp01",
                cpuSeriesID: index < 2 ? "cpu:Tp01,Tp05" : "cpu:Tp01")
            window.record(latest, at: latest.sampledAt)
        }
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window,
                                                            at: latest.sampledAt)
        XCTAssertEqual(result.trajectory.direction, .measuring)
        XCTAssertEqual(result.trajectory.spanSeconds, 10)
    }

    func testSingleSpikeDoesNotInventASustainedRise() {
        let (window, latest) = history([75, 75, 75, 75, 75, 75, 90])
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.band, .veryHot, "The instantaneous reading must remain visible")
        XCTAssertEqual(result.trajectory.direction, .steady, "One outlier cannot fabricate a trend")
        XCTAssertEqual(result.trajectory.hotSeconds, 0)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: latest, activity: .empty, observations: window,
                                                  at: latest.sampledAt)
        XCTAssertEqual(diagnosis.reviewStatus, "Very hot")
        XCTAssertFalse(diagnosis.headline.contains("Reduce"))
        XCTAssertEqual(diagnosis.headline, "90.0°C · Brief spike — watching the next readings")
    }

    func testConsecutiveVeryHotReadingsAskToReduceHeavyWork() {
        let (window, latest) = history([75, 75, 75, 75, 75, 91, 91])
        let result = ThermalDiagnosis.evaluate(snapshot: latest, activity: .empty, observations: window,
                                               at: latest.sampledAt)
        XCTAssertEqual(result.temperature.trajectory.veryHotSeconds, 10)
        XCTAssertEqual(result.headline, "91.0°C · Reduce optional heavy work")
    }

    func testObservationWindowIsBoundedAndRejectsOutOfOrderSamples() {
        var window = ThermalObservationWindow()
        for index in 0..<500 {
            let reading = snapshot(80, at: now.addingTimeInterval(Double(index)))
            window.record(reading, at: reading.sampledAt)
        }
        XCTAssertEqual(window.readings.count, 90)
        let lastDate = window.readings.last?.date
        window.record(snapshot(120, at: now.addingTimeInterval(495)), at: now.addingTimeInterval(499))
        XCTAssertEqual(window.readings.last?.date, lastDate)
        XCTAssertEqual(window.readings.last?.cpu, 80)
    }

    func testTypedPressureDoesNotDependOnSensorDisplayStrings() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(82, state: "Unrecognized display text"),
            activity: .empty, pressure: ThermalPressureReading(state: .normal, sampledAt: now), at: now)
        XCTAssertEqual(result.state, .normal)
        XCTAssertEqual(result.reviewStatus, "Hot")
        XCTAssertEqual(result.pressureText, "macOS pressure: Normal")
    }

    func testTypedCriticalPressureDoesNotNeedTemperatureSensors() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(nil), activity: .empty,
            pressure: ThermalPressureReading(state: .critical, sampledAt: now), at: now)
        XCTAssertEqual(result.state, .critical)
        XCTAssertEqual(result.reviewStatus, "Critical pressure")
        XCTAssertEqual(result.temperature.band, .unavailable)
    }

    func testExpiredTypedPressureIsNotReplacedWithAnOldNormalLabel() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(80), activity: .empty,
            pressure: ThermalPressureReading(state: .normal, sampledAt: now.addingTimeInterval(-16)), at: now)
        XCTAssertEqual(result.state, .checking)
        XCTAssertEqual(result.reviewStatus, "Hot")
    }

    func testFutureTypedPressureIsUnknown() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(80), activity: .empty,
            pressure: ThermalPressureReading(state: .normal, sampledAt: now.addingTimeInterval(1)), at: now)
        XCTAssertEqual(result.state, .checking)
    }

    func testCurrentTypedPressureSurvivesAnExpiredSensorReading() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(80, at: now.addingTimeInterval(-30)), activity: .empty,
            pressure: ThermalPressureReading(state: .serious, sampledAt: now), at: now)
        XCTAssertEqual(result.state, .serious)
        XCTAssertEqual(result.reviewStatus, "High pressure")
        XCTAssertEqual(result.temperature.band, .unavailable)
    }

    func testLegacyElevatedLabelMatchesTheLivePlatformSignal() {
        let result = ThermalDiagnosis.evaluate(snapshot: snapshot(76, state: " Elevated "), activity: .empty, at: now)
        XCTAssertEqual(result.state, .warm)
        XCTAssertEqual(result.pressureText, "macOS pressure: Elevated")
        XCTAssertEqual(result.reviewStatus, "Elevated pressure")
    }

    private func insight(temperature: Double, activity: ThermalActivitySummary) -> ThermalAppInsight {
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(temperature), activity: activity, at: now)
        return ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: now)
    }

    private func diagnose(cpu: Double) -> ThermalDiagnosis {
        ThermalDiagnosis.evaluate(snapshot: snapshot(cpu), activity: activity(cpu: 0), at: now)
    }

    private func snapshot(_ cpu: Double?, gpu: Double? = nil, state: String = "Normal", at date: Date? = nil) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date ?? now, cpuCelsius: cpu, gpuCelsius: gpu,
                        sensorCount: 2, sensorKeys: [], systemState: state, unavailableReason: nil)
    }

    private func history(_ values: [Double]) -> (ThermalObservationWindow, ThermalSnapshot) {
        var window = ThermalObservationWindow()
        var latest = snapshot(nil)
        for (index, value) in values.enumerated() {
            latest = snapshot(value, at: now.addingTimeInterval(Double(index * 10)))
            window.record(latest, at: latest.sampledAt)
        }
        return (window, latest)
    }

    private func activity(cpu: Double, missing: Int = 0, date: Date? = nil) -> ThermalActivitySummary {
        let date = date ?? now
        let samples = (0...missing).map { index in
            ThermalActivitySample(identity: ProcessIdentity(pid: Int32(100 + index), startTimeSeconds: 1, startTimeMicroseconds: 0),
                familyKey: "render-\(index)", name: "Render", executablePath: "/Applications/Render.app/Contents/MacOS/Render",
                cpuPercent: cpu, gpuPercent: 0, measuredAt: index == 0 ? date : nil)
        }
        return ThermalActivitySummary.build(samples: samples, now: date, processorCount: 10)
    }
}
