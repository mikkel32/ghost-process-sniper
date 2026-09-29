import XCTest
@testable import GhostProcessSniperCore

/// The Mac's draw as the power controller's own interval means: it keeps a
/// running sum of its load samples (milliwatts, about one a second) and how
/// many it took, so two readings give the exact average between them.
final class DrawAveragingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)
    private let base = PowerAccumulator(sum: 10_000_000_000, samples: 450_000)

    private func advanced(_ from: PowerAccumulator, samples: Double, watts: Double) -> PowerAccumulator {
        PowerAccumulator(sum: from.sum + samples * watts * 1_000, samples: from.samples + samples)
    }

    func testTheMeanBetweenTwoReadingsIsExact() {
        let later = advanced(base, samples: 56, watts: 20)
        XCTAssertEqual(PowerAccumulator.averageWatts(from: base, to: later) ?? 0, 20, accuracy: 1e-9)
    }

    func testABadIntervalHasNoMean() {
        XCTAssertNil(PowerAccumulator.averageWatts(from: base, to: base), "nothing new was counted")
        XCTAssertNil(PowerAccumulator.averageWatts(from: advanced(base, samples: 56, watts: 20), to: base),
                     "a counter that went backwards was reset")
        XCTAssertNil(PowerAccumulator.averageWatts(from: base, to: advanced(base, samples: 10, watts: 5_000)),
                     "5,000 W is not a Mac")
        XCTAssertNil(PowerAccumulator.averageWatts(from: base, to: PowerAccumulator(sum: base.sum - 1_000, samples: base.samples + 1)),
                     "negative power is not a draw")
    }

    func testAnIntervalCountsForAsManySecondsAsItSampled() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        let long = advanced(base, samples: 56, watts: 20)
        averager.add(long, at: start.addingTimeInterval(56), discharging: false)
        averager.add(advanced(long, samples: 1, watts: 90), at: start.addingTimeInterval(57), discharging: false)
        // One 90 W sample among 57 is not a 55 W average.
        XCTAssertEqual(averager.watts(over: 90, now: start.addingTimeInterval(57)) ?? 0, (56 * 20 + 90) / 57, accuracy: 1e-9)
    }

    func testTooFewSamplesAreNotAnAverageYet() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        averager.add(advanced(base, samples: 5, watts: 20), at: start.addingTimeInterval(5), discharging: false)
        XCTAssertNil(averager.watts(over: 90, now: start.addingTimeInterval(5)))
    }

    func testReadsBetweenRegistryUpdatesAddNothing() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        for second in 1...10 { averager.add(base, at: start.addingTimeInterval(Double(second)), discharging: false) }
        XCTAssertEqual(averager.intervalCount, 0)
        averager.add(advanced(base, samples: 30, watts: 20), at: start.addingTimeInterval(11), discharging: false)
        XCTAssertEqual(averager.intervalCount, 1)
    }

    func testACounterThatRestartsStartsTheAverageAfresh() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        averager.add(advanced(base, samples: 56, watts: 20), at: start.addingTimeInterval(56), discharging: false)
        averager.add(PowerAccumulator(sum: 5_000, samples: 5), at: start.addingTimeInterval(60), discharging: false)
        XCTAssertNil(averager.watts(over: 90, now: start.addingTimeInterval(60)))
        XCTAssertEqual(averager.intervalCount, 0)
        let restarted = advanced(PowerAccumulator(sum: 5_000, samples: 5), samples: 40, watts: 12)
        averager.add(restarted, at: start.addingTimeInterval(100), discharging: false)
        XCTAssertEqual(averager.watts(over: 90, now: start.addingTimeInterval(100)) ?? 0, 12, accuracy: 1e-9)
    }

    func testAnImplausibleIntervalIsDroppedNotAveraged() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        averager.add(advanced(base, samples: 56, watts: 5_000), at: start.addingTimeInterval(56), discharging: false)
        XCTAssertEqual(averager.intervalCount, 0)
    }

    func testANewPowerSourceStartsTheAverageAfresh() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        let plugged = advanced(base, samples: 56, watts: 40)
        averager.add(plugged, at: start.addingTimeInterval(56), discharging: false)
        averager.add(advanced(plugged, samples: 56, watts: 8), at: start.addingTimeInterval(112), discharging: true)
        XCTAssertNil(averager.watts(over: 300, now: start.addingTimeInterval(112)), "the first reading on battery only sets a baseline")
    }

    func testOldIntervalsAgeOutOfTheWindow() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        averager.add(advanced(base, samples: 56, watts: 20), at: start.addingTimeInterval(56), discharging: false)
        XCTAssertNotNil(averager.watts(over: 90, now: start.addingTimeInterval(100)))
        XCTAssertNil(averager.watts(over: 90, now: start.addingTimeInterval(200)))
        XCTAssertNotNil(averager.watts(over: 300, now: start.addingTimeInterval(200)))
    }

    func testAGapLongerThanTenMinutesIsNotAnInterval() {
        var averager = DrawAverager()
        averager.add(base, at: start, discharging: false)
        averager.add(advanced(base, samples: 900, watts: 20), at: start.addingTimeInterval(1_800), discharging: false)
        XCTAssertEqual(averager.intervalCount, 0, "asleep or stalled for half an hour")
    }

    // MARK: - Through the monitor

    private func idle(_ index: Int, _ date: Date) -> [ProcessMetrics] {
        [EnergyFixture.process(pid: 1, name: "x", path: "/x", counters: .init(joules: Double(index)), at: date)]
    }

    func testTheHeaderDrawIsTheIntervalMeanNotAStaleSnapshot() {
        // The snapshot fields keep saying 60 W (a burst the registry has not refreshed); the counters say 20 W.
        let battery = ScriptedBattery.discharging(watts: 60)
        battery.advanceLoad(samples: 0, watts: 0)
        var driver = EnergyDriver(battery: battery)
        let report = driver.run(ticks: 40) { index, date in
            battery.advanceLoad(samples: 5, watts: 20)
            return idle(index, date)
        }
        let outlook = try? XCTUnwrap(report.battery)
        XCTAssertEqual(outlook?.drawWatts ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(outlook?.averageDrawWatts ?? 0, 20, accuracy: 0.01)
        // 60 Wh at 20 W, not at the snapshot's 60 W.
        XCTAssertEqual(outlook?.minutesRemaining ?? 0, 180, accuracy: 0.5)
        XCTAssertEqual(report.macWatts ?? 0, 20, accuracy: 0.01)
    }

    func testWithoutCountersTheSnapshotStillDrivesTheDraw() {
        let battery = ScriptedBattery.discharging(watts: 10)
        var driver = EnergyDriver(battery: battery)
        let report = driver.run(ticks: 10, processes: idle)
        XCTAssertEqual(report.battery?.drawWatts ?? 0, 10, accuracy: 0.01)
        XCTAssertNil(report.battery?.averageDrawWatts)
        XCTAssertEqual(report.macWatts ?? 0, 10, accuracy: 0.01, "falls back to the smoothed draw")
    }

    func testAnImplausibleSnapshotIsNeverADraw() {
        var reading = BatteryReading(hasBattery: true, onExternalPower: true, isCharging: false, systemLoadWatts: 4_000, readAt: Date())
        XCTAssertNil(reading.drawWatts)
        reading.systemLoadWatts = -3
        XCTAssertNil(reading.drawWatts, "a wrapped or negative value is not a draw")
        reading.systemLoadWatts = 94
        XCTAssertEqual(reading.drawWatts, 94)
        reading.onExternalPower = false
        reading.voltageMillivolts = 12_500
        reading.amperageMilliamps = -40_000
        XCTAssertEqual(reading.drawWatts, 94, "500 W out of a battery is a bad current: the system load answers instead")
        reading.systemLoadWatts = nil
        XCTAssertNil(reading.drawWatts)
    }
}
