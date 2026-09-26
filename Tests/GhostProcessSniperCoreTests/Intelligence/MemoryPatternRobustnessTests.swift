import XCTest
@testable import GhostProcessSniperCore

final class MemoryPatternRobustnessTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testJitteryLeaksAreSteadyClimbsWithTheirTrueSlope() {
        let cases: [(rate: Double, jitter: Double, cadence: TimeInterval)] = [(20, 3, 1), (130, 6, 0.75), (200, 8, 1)]
        for (index, leak) in cases.enumerated() {
            var jitter = Fixture.Jitter(seed: UInt64(index + 1))
            let series = (0..<90).map { step in
                300 + leak.rate * Double(step) * leak.cadence / 60 + jitter.next(amplitude: leak.jitter)
            }
            let trend = Fixture.trend(megabytes: series, cadence: leak.cadence)

            XCTAssertEqual(trend.resolvedPattern.pattern, .steadyClimb, "\(leak)")
            XCTAssertEqual(trend.memoryVelocityMegabytesPerMinute, leak.rate, accuracy: leak.rate * 0.05, "\(leak)")
            XCTAssertEqual(trend.credibleMemoryVelocity, leak.rate, accuracy: leak.rate * 0.05, "\(leak)")
        }
    }

    func testFlatNoiseIsFlat() {
        var jitter = Fixture.Jitter(seed: 7)
        let trend = Fixture.trend(megabytes: (0..<60).map { _ in 400 + jitter.next(amplitude: 3) }, cadence: 1)
        XCTAssertEqual(trend.resolvedPattern.pattern, .flat)
        XCTAssertEqual(trend.credibleMemoryVelocity, 0)
    }

    func testGarbageCollectionWithAFlatFloorIsSawtooth() {
        let trend = Fixture.trend(megabytes: gcSeries(floorRisePerMinute: 0), cadence: 2)
        XCTAssertEqual(trend.resolvedPattern.pattern, .sawtooth)
        XCTAssertFalse(trend.resolvedPattern.indicatesAccumulation)
        XCTAssertEqual(trend.credibleMemoryVelocity, 0)
    }

    func testGarbageCollectionWithARisingFloorIsALeak() {
        let trend = Fixture.trend(megabytes: gcSeries(floorRisePerMinute: 40), cadence: 2)
        let pattern = trend.resolvedPattern
        XCTAssertEqual(pattern.pattern, .risingFloor)
        XCTAssertTrue(pattern.indicatesAccumulation)
        XCTAssertEqual(pattern.floorSlopeMegabytesPerMinute, 40, accuracy: 4)
        XCTAssertEqual(trend.credibleMemoryVelocity, 40, accuracy: 4)
    }

    func testOneAllocationStepIsAStepJump() {
        var jitter = Fixture.Jitter(seed: 11)
        let series = (0..<20).map { step in (step < 10 ? 200.0 : 520.0) + jitter.next(amplitude: 2) }
        let trend = Fixture.trend(megabytes: series, cadence: 5)
        XCTAssertEqual(trend.resolvedPattern.pattern, .stepJump)
        XCTAssertEqual(trend.credibleMemoryVelocity, 0)
    }

    func testTrendWindowComputesThePatternOnce() {
        let trend = Fixture.trend(megabytes: [100, 110, 120, 130, 140, 150])
        XCTAssertNotNil(trend.pattern)
        XCTAssertEqual(trend.pattern, trend.resolvedPattern)
    }

    func testRisingFloorForecastIsALeak() {
        let trend = Fixture.trend(megabytes: gcSeries(floorRisePerMinute: 160), cadence: 2)
        let current = trend.memoryPoints.last.map { $0 / Double(Fixture.mib) } ?? 0
        let family = Fixture.family(Fixture.process(parent: 999, megabytes: current, cpu: 3), trend: trend)
        let forecast = FamilyRiskForecaster().forecast(family: family, settings: .smart, now: Fixture.now)
        XCTAssertEqual(forecast.state, .leaking)
        XCTAssertTrue(forecast.whyNow.contains("floor keeps rising"), forecast.whyNow)
    }

    /// A GC sawtooth: allocates 90 MB over 20 s, collects back to the floor.
    private func gcSeries(floorRisePerMinute: Double) -> [Double] {
        var jitter = Fixture.Jitter(seed: 3)
        return (0..<90).map { step in
            let minutes = Double(step) * 2 / 60
            return 300 + floorRisePerMinute * minutes + Double(step % 10) * 10 + jitter.next(amplitude: 2)
        }
    }
}
