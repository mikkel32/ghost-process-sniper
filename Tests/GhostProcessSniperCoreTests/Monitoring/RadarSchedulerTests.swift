import XCTest
@testable import GhostProcessSniperCore

final class RadarSchedulerTests: XCTestCase {
    func testPlanIsUIVisibleOnlyWhileThePopoverIsOpen() {
        var scheduler = RadarScheduler()
        let visible = scheduler.plan(settings: .smart, families: [], uiVisible: true,
            now: RefreshPerformanceFixture.now)
        let hidden = scheduler.plan(settings: .smart, families: [], uiVisible: false,
            now: RefreshPerformanceFixture.now.addingTimeInterval(1))
        XCTAssertTrue(visible.uiVisible)
        XCTAssertFalse(hidden.uiVisible)
    }

    func testDirectlyBuiltPlansDefaultToHidden() {
        XCTAssertFalse(SamplingPlan.balanced(now: RefreshPerformanceFixture.now).uiVisible)
    }

    private let battery = PowerContext(onBattery: true, lowPowerMode: false)
    private let lowPower = PowerContext(onBattery: true, lowPowerMode: true)

    private func cadence(
        _ level: GhostLevel, visible: Bool = false, power: PowerContext = .mains,
        thermal: SystemPressureLevel = .nominal, settled: Bool = false, cost: Double = 5,
        settings: ThresholdSettings = .smart
    ) -> (interval: TimeInterval, mode: RadarPerformanceMode) {
        var scheduler = RadarScheduler(pressureProvider: { thermal })
        let context = RadarSchedulingContext(uiVisible: visible, power: power, thermalPressure: thermal,
            summaryLevel: level, hotSinceAlerted: settled, currentRefreshMilliseconds: cost)
        let interval = scheduler.nextInterval(settings: settings, context: context)
        return (interval, scheduler.currentPerformanceMode)
    }

    func testVisibleSurfaceSamplesAboutEverySecondWithRealtimeBudgets() {
        for power in [PowerContext.mains, battery, lowPower] {
            XCTAssertEqual(cadence(.quiet, visible: true, power: power).interval, 1)
            XCTAssertEqual(cadence(.hot, visible: true, power: power).interval, 0.75)
            XCTAssertEqual(cadence(.watch, visible: true, power: power).mode, .realtime)
        }
    }

    func testUnattendedVisibleConsoleRelaxesAndInputRestoresTheWatchedRate() {
        func visible(_ level: GhostLevel, idle: TimeInterval) -> TimeInterval {
            var scheduler = RadarScheduler(pressureProvider: { .nominal })
            let context = RadarSchedulingContext(uiVisible: true, summaryLevel: level,
                currentRefreshMilliseconds: 5, userIdleSeconds: idle)
            return scheduler.nextInterval(settings: .smart, context: context)
        }
        XCTAssertEqual(visible(.quiet, idle: 5), 1, "someone using the Mac gets the watched rate")
        XCTAssertEqual(visible(.quiet, idle: 45), 2)
        XCTAssertEqual(visible(.quiet, idle: 600), 4)
        XCTAssertEqual(visible(.hot, idle: 45), 1.5)
        XCTAssertEqual(visible(.hot, idle: 600), 3)
        XCTAssertEqual(visible(.quiet, idle: 0), 1, "fresh input restores the watched rate")
    }

    func testIdleTimeNeverStretchesTheHiddenCadence() {
        var scheduler = RadarScheduler(pressureProvider: { .nominal })
        let idle = RadarSchedulingContext(uiVisible: false, summaryLevel: .quiet,
            currentRefreshMilliseconds: 5, userIdleSeconds: 900)
        XCTAssertEqual(scheduler.nextInterval(settings: .smart, context: idle), 3.5)
    }

    func testHiddenOnMainsNeverRunsRealtime() {
        XCTAssertEqual(cadence(.quiet).interval, 3.5)
        XCTAssertEqual(cadence(.watch).interval, 2)
        XCTAssertEqual(cadence(.hot).interval, 1)
        for level in [GhostLevel.quiet, .watch, .hot, .critical] {
            XCTAssertEqual(cadence(level).mode, .balanced, "\(level)")
        }
    }

    func testBatteryStretchesHiddenCadenceAndUsesBatterySaverBudgets() {
        XCTAssertEqual(cadence(.quiet, power: battery).interval, 5.25, accuracy: 0.001)
        XCTAssertEqual(cadence(.watch, power: battery).interval, 3, accuracy: 0.001)
        XCTAssertEqual(cadence(.quiet, power: battery).mode, .batterySaver)
        for level in [GhostLevel.hot, .critical] {
            for thermal in [SystemPressureLevel.nominal, .elevated, .serious, .critical] {
                XCTAssertGreaterThanOrEqual(cadence(level, power: battery, thermal: thermal, cost: 0).interval, 1.5,
                                            "hidden \(level) on battery at \(thermal) thermal")
            }
        }
    }

    func testLowPowerModeRunsSlowest() {
        XCTAssertEqual(cadence(.quiet, power: lowPower).interval, 6)
        XCTAssertEqual(cadence(.hot, power: lowPower).interval, 3)
        XCTAssertEqual(cadence(.hot, power: lowPower).mode, .batterySaver)
        XCTAssertEqual(cadence(.hot, power: PowerContext(onBattery: false, lowPowerMode: true)).mode, .batterySaver)
    }

    func testSettledAlertedHotFamilyRelaxesTheHiddenCadence() {
        XCTAssertEqual(cadence(.hot, settled: true).interval, 2.5)
        XCTAssertEqual(cadence(.hot, visible: true, settled: true).interval, 0.75, "someone watching still gets live data")
    }

    func testThermalPressureAndOwnCostStretchTheCadence() {
        XCTAssertEqual(cadence(.watch, thermal: .elevated).interval, 2.5, accuracy: 0.001)
        XCTAssertEqual(cadence(.watch, cost: 61).interval, 2.7, accuracy: 0.001, "over the balanced 60 ms budget")
        XCTAssertEqual(cadence(.quiet, thermal: .critical).interval, 8, "capped")
    }

    func testExplicitModeIsHonoured() {
        var saver = ThresholdSettings.smart
        saver.adaptivePerformance = false
        saver.performanceMode = .batterySaver
        XCTAssertEqual(cadence(.hot, settings: saver).interval, 1.5)
        XCTAssertEqual(cadence(.hot, settings: saver).mode, .batterySaver)
        var realtime = saver
        realtime.performanceMode = .realtime
        XCTAssertEqual(cadence(.quiet, settings: realtime).interval, 1)
        XCTAssertEqual(cadence(.quiet, power: lowPower, settings: realtime).interval, 6, "Low Power Mode still wins hidden")
    }

    /// Adaptive scanning off: the explicit mode and the Refresh slider decide.
    private func manual(_ mode: RadarPerformanceMode, refresh: TimeInterval) -> ThresholdSettings {
        var settings = ThresholdSettings.smart
        settings.adaptivePerformance = false
        settings.performanceMode = mode
        settings.refreshInterval = refresh
        return settings
    }

    func testRefreshSliderSetsTheWatchedPaceInEveryMode() {
        for mode in RadarPerformanceMode.allCases {
            for seconds in stride(from: 1.0, through: 5.0, by: 0.5) {
                XCTAssertEqual(cadence(.quiet, visible: true, settings: manual(mode, refresh: seconds)).interval, seconds,
                               "\(mode) at \(seconds) s")
            }
        }
    }

    func testRefreshSliderLeavesHotFamiliesTheFastPaceAndAdaptiveScanningItsOwn() {
        for mode in RadarPerformanceMode.allCases {
            XCTAssertEqual(cadence(.hot, visible: true, settings: manual(mode, refresh: 5)).interval, 0.75, "\(mode)")
        }
        var adaptive = ThresholdSettings.smart
        adaptive.refreshInterval = 5
        XCTAssertEqual(cadence(.quiet, visible: true, settings: adaptive).interval, 1,
                       "with adaptive scanning on the slider is hidden and the watched pace stays a second")
    }

    func testRefreshSliderDoesNotSlowTheBackgroundCadence() {
        XCTAssertEqual(cadence(.quiet, settings: manual(.balanced, refresh: 5)).interval, 3.5)
        XCTAssertEqual(cadence(.hot, settings: manual(.balanced, refresh: 5)).interval, 1)
        XCTAssertEqual(cadence(.hot, settings: manual(.realtime, refresh: 5)).interval, 0.75)
    }

    func testRefreshSliderOffersOnlyPacesTheSchedulerKeeps() {
        XCTAssertEqual(ThresholdSettings.refreshIntervalRange, 1...5)
        XCTAssertEqual(manual(.balanced, refresh: 0.5).watchedInterval, 1, "settings saved when the slider still offered half a second")
        XCTAssertEqual(manual(.balanced, refresh: 3).watchedInterval, 3)
        XCTAssertEqual(manual(.balanced, refresh: 9).watchedInterval, 5)
        XCTAssertEqual(manual(.balanced, refresh: .nan).watchedInterval, 1)
        XCTAssertEqual(cadence(.quiet, visible: true, settings: manual(.realtime, refresh: 0.5)).interval, 1)
    }

    func testSelfThrottleTargetsTwiceTheIdleBudgetOnlyWhileHidden() {
        XCTAssertEqual(RadarScheduler.selfThrottled(3.5, selfAverageCPUPercent: 0.4, targetIdleCPUPercent: 0.25, uiVisible: false), 3.5)
        XCTAssertEqual(RadarScheduler.selfThrottled(2, selfAverageCPUPercent: 1, targetIdleCPUPercent: 0.25, uiVisible: false), 4)
        XCTAssertEqual(RadarScheduler.selfThrottled(3.5, selfAverageCPUPercent: 5, targetIdleCPUPercent: 0.25, uiVisible: false), 8)
        XCTAssertEqual(RadarScheduler.selfThrottled(1, selfAverageCPUPercent: 5, targetIdleCPUPercent: 1.2, uiVisible: true), 1)
    }

    func testHotSinceAlertedNeedsEveryHotFamilySettledForFiveMinutes() {
        var scheduler = RadarScheduler(pressureProvider: { .nominal })
        let now = RefreshPerformanceFixture.now
        let build = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(1), level: .hot)
            .enriched(alertState: AlertState(kind: .recurring, message: "2x recurring incident", since: now))
        XCTAssertFalse(scheduler.noteHotFamilies([build], now: now))
        XCTAssertFalse(scheduler.noteHotFamilies([build], now: now.addingTimeInterval(300)))
        XCTAssertTrue(scheduler.noteHotFamilies([build], now: now.addingTimeInterval(301)))

        let fresh = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(3), level: .hot)
            .enriched(alertState: AlertState(kind: .new, message: "New hot incident", since: now))
        XCTAssertFalse(scheduler.noteHotFamilies([build, fresh], now: now.addingTimeInterval(302)),
                       "a new alert is news, whatever else is settled")
        XCTAssertFalse(scheduler.noteHotFamilies([], now: now.addingTimeInterval(303)))
        XCTAssertFalse(scheduler.noteHotFamilies([build], now: now.addingTimeInterval(304)),
                       "a family that cooled starts its five minutes again")
    }

    func testBriefHysteresisHoldKeepsTheHotClockRunning() {
        var scheduler = RadarScheduler(pressureProvider: { .nominal })
        var hysteresis = RadarHysteresis()
        let now = RefreshPerformanceFixture.now
        let root = RefreshPerformanceFixture.process(1)
        func tick(_ level: GhostLevel, at seconds: TimeInterval) -> Bool {
            let family = RefreshPerformanceFixture.family(root, level: level)
                .enriched(alertState: AlertState(kind: .recurring, message: "2x recurring incident", since: now))
            let at = now.addingTimeInterval(seconds)
            return scheduler.noteHotFamilies(hysteresis.apply(to: [family], now: at), now: at)
        }
        // Each lull is long enough for the hold to step down to watch.
        for burst in stride(from: 0.0, through: 270, by: 30) {
            XCTAssertFalse(tick(.hot, at: burst), "t0+\(burst)")
            XCTAssertFalse(tick(.quiet, at: burst + 5), "t0+\(burst + 5)")
            XCTAssertFalse(tick(.quiet, at: burst + 25), "t0+\(burst + 25)")
        }
        XCTAssertTrue(tick(.hot, at: 301), "a build hot in bursts still settles after five minutes")

        XCTAssertTrue(tick(.quiet, at: 310), "held at Hot, it is still settled")
        XCTAssertFalse(tick(.quiet, at: 330), "held at Watch nothing is hot, but the clock is kept")
        XCTAssertFalse(tick(.quiet, at: 350), "once the hold has stepped all the way down the family really cooled")
        XCTAssertFalse(tick(.hot, at: 351), "so its five minutes start again")
    }

    func testPowerContextIsCachedForThirtySeconds() {
        let reads = LockedCounter()
        var reader = PowerContextReader(source: {
            reads.increment()
            return .mains
        })
        let now = RefreshPerformanceFixture.now
        _ = reader.context(now: now)
        _ = reader.context(now: now.addingTimeInterval(29))
        XCTAssertEqual(reads.value, 1)
        _ = reader.context(now: now.addingTimeInterval(30))
        XCTAssertEqual(reads.value, 2)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
