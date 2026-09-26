import XCTest
@testable import GhostProcessSniperCore

final class ForecastSemanticsTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let forecaster = FamilyRiskForecaster()

    func testCPUBreachDoesNotProduceALeakVerdict() {
        let memory: [Double] = [400, 405, 410, 415, 420, 425]
        let trend = Fixture.trend(megabytes: memory, cpu: [10, 12, 9, 11, 10, 95])
        let family = Fixture.family(Fixture.process(megabytes: 425, cpu: 95), trend: trend)

        let forecast = forecaster.forecast(family: family, settings: .smart, now: Fixture.now)

        XCTAssertLessThan(forecast.state, .leaking)
        XCTAssertNotEqual(forecast.horizon, .breached, "the horizon is a memory horizon")
        XCTAssertTrue(forecast.whyNow.contains("CPU above its 90% limit"), forecast.whyNow)
        let verdict = FamilyVerdict.synthesize(family: family.enriched(forecast: forecast), pattern: trend.resolvedPattern)
        XCTAssertFalse(verdict.headline.localizedCaseInsensitiveContains("leak"), verdict.headline)
    }

    func testGrowthNearTheMemoryLimitIsALeakWithAMemoryETA() {
        let memory: [Double] = [890, 900, 910, 920, 930, 940, 950]
        let family = Fixture.family(Fixture.process(megabytes: 950, cpu: 4), trend: Fixture.trend(megabytes: memory, cadence: 10))

        let forecast = forecaster.forecast(family: family, settings: .smart, now: Fixture.now)

        XCTAssertEqual(forecast.state, .leaking)
        XCTAssertEqual(forecast.etaKind, .memoryLimit)
        XCTAssertEqual(forecast.horizon, .imminent)
        XCTAssertNotNil(forecast.etaSeconds)
        XCTAssertTrue(forecast.whyNow.contains("memory limit in"), forecast.whyNow)
    }

    func testShortHistoryWithACPUBreachIsNotALeak() {
        let trend = Fixture.trend(megabytes: [900, 960, 1_020], cpu: [95, 96, 97])
        let family = Fixture.family(Fixture.process(megabytes: 1_020, cpu: 97), trend: trend)

        let forecast = forecaster.forecast(family: family, settings: .smart, now: Fixture.now)

        XCTAssertLessThan(forecast.state, .leaking)
    }

    func testFlatFamilyAboveItsLimitIsWatchedNotLeaking() {
        let trend = Fixture.trend(megabytes: [1_300, 1_301, 1_300, 1_302, 1_300, 1_301])
        let family = Fixture.family(Fixture.process(parent: 999, megabytes: 1_301, cpu: 3), trend: trend, level: .watch)

        let forecast = forecaster.forecast(family: family, settings: .smart, now: Fixture.now)

        XCTAssertEqual(forecast.state, .warming)
        XCTAssertEqual(forecast.horizon, .breached)
        XCTAssertTrue(forecast.whyNow.contains("above its memory limit"), forecast.whyNow)
    }

    func testImmatureOrUnknownPatternsDoNotAccumulate() {
        XCTAssertFalse(MemoryPattern.unknown.indicatesAccumulation)
        XCTAssertFalse(MemoryPattern.volatile.indicatesAccumulation)
        let noisy = MemoryPatternAnalysis(pattern: .volatile, confidence: 0.5, detail: "", fitQuality: 0.2)
        XCTAssertFalse(noisy.indicatesAccumulation)
        let trending = MemoryPatternAnalysis(pattern: .volatile, confidence: 0.5, detail: "", fitQuality: 0.6)
        XCTAssertTrue(trending.indicatesAccumulation)
    }

    func testAccelerationNeedsSignificantHalfWindowSlopes() {
        // Four samples per half, but the second half is only noisier, not faster.
        let steady = Fixture.trend(megabytes: [500, 520, 538, 562, 580, 598, 622, 640], cadence: 15)
        let steadyFamily = Fixture.family(Fixture.process(megabytes: 640, cpu: 3), trend: steady)
        let steadyForecast = forecaster.forecast(family: steadyFamily, settings: .smart, now: Fixture.now)
        XCTAssertEqual(steadyForecast.leakAccelerationMegabytesPerMinute2, 0)

        let accelerating = Fixture.trend(megabytes: [100, 110, 120, 130, 200, 300, 400, 500], cadence: 15)
        let family = Fixture.family(Fixture.process(megabytes: 500, cpu: 3), trend: accelerating)
        let forecast = forecaster.forecast(family: family, settings: .smart, now: Fixture.now)
        XCTAssertGreaterThan(forecast.leakAccelerationMegabytesPerMinute2, 80)
        XCTAssertNotEqual(forecast.state, .runaway, "acceleration alone is not a runaway")
        XCTAssertTrue(forecast.whyNow.contains("accelerating"), forecast.whyNow)
    }

    func testSummaryShowsLeakETAOnlyForMemoryLeaks() {
        let leaking = RiskForecast(state: .leaking, horizon: .soon, confidence: 0.9, etaSeconds: 600, etaText: "10 min",
            whyNow: "", recommendedAction: RiskForecast.quiet.recommendedAction, projectedMemoryBytes: 0,
            projectedCPUPercent: 0, leakAccelerationMegabytesPerMinute2: 0, recurrenceRisk: 0, staleLikelihood: 0,
            baseline: .unknown, generatedAt: Fixture.now, etaKind: .memoryLimit)
        let trend = Fixture.trend(megabytes: [100, 110, 120, 130, 140, 150])
        let family = Fixture.family(Fixture.process(megabytes: 150), trend: trend).enriched(forecast: leaking)
        XCTAssertEqual(RadarSummaryBuilder.summary(for: [family]).statusText, "Leak 10 min")

        let noETA = RiskForecast(state: .leaking, horizon: .unknown, confidence: 0.9, etaSeconds: nil,
            etaText: "No threshold ETA", whyNow: "", recommendedAction: RiskForecast.quiet.recommendedAction,
            projectedMemoryBytes: 0, projectedCPUPercent: 0, leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0, staleLikelihood: 0, baseline: .unknown, generatedAt: Fixture.now)
        XCTAssertEqual(RadarSummaryBuilder.summary(for: [family.enriched(forecast: noETA)]).statusText, "Leak")

        let stale = RiskForecast(state: .stale, horizon: .unknown, confidence: 0.6, etaSeconds: nil,
            etaText: "No threshold ETA", whyNow: "", recommendedAction: RiskForecast.quiet.recommendedAction,
            projectedMemoryBytes: 0, projectedCPUPercent: 0, leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0, staleLikelihood: 0.8, baseline: .unknown, generatedAt: Fixture.now)
        XCTAssertEqual(RadarSummaryBuilder.summary(for: [family.enriched(forecast: stale)]).statusText, "Forgotten?")
    }
}
