import XCTest
@testable import GhostProcessSniperCore

final class HeatEvidenceTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testCPUPersistenceUsesTheRealThresholdNotTheLastSample() {
        let quietHistory = Fixture.trend(megabytes: Array(repeating: 300, count: 8), cpu: Array(repeating: 20, count: 8))
        let spike = GhostHeatModel.initial(memoryRatio: 0.3, cpuRatio: 2, cpuThreshold: 90, gpuRatio: 0,
                                           leakRatio: 0, trend: quietHistory, hardwareLevel: .quiet)
        XCTAssertEqual(spike.sustainedSignalCount, 0)
        XCTAssertLessThanOrEqual(spike.level, .hot)
        XCTAssertFalse(spike.evidence.contains("CPU stayed elevated across the sampling window"))

        let peggedHistory = Fixture.trend(megabytes: Array(repeating: 300, count: 8), cpu: Array(repeating: 180, count: 8), cadence: 15)
        let pegged = GhostHeatModel.initial(memoryRatio: 0.3, cpuRatio: 2, cpuThreshold: 90, gpuRatio: 0,
                                            leakRatio: 0, trend: peggedHistory, hardwareLevel: .quiet)
        XCTAssertEqual(pegged.sustainedSignalCount, 1)
        XCTAssertTrue(pegged.evidence.contains("CPU stayed elevated across the sampling window"))
    }

    /// Four samples over 15 s prove nothing about minutes: like the
    /// forecaster's runaway rule, the window needs 90 s.
    func testShortPeggedWindowIsNotSustainedCPU() {
        let briefHistory = Fixture.trend(megabytes: Array(repeating: 300, count: 8), cpu: Array(repeating: 180, count: 8), cadence: 3)
        let brief = GhostHeatModel.initial(memoryRatio: 0.3, cpuRatio: 2, cpuThreshold: 90, gpuRatio: 0,
                                           leakRatio: 0, trend: briefHistory, hardwareLevel: .quiet)
        XCTAssertEqual(brief.sustainedSignalCount, 0)
        XCTAssertLessThan(brief.level, .critical)
        XCTAssertFalse(brief.evidence.contains("CPU stayed elevated across the sampling window"))
    }

    func testTwoSampleJumpIsNotALeak() throws {
        var window = TrendWindow()
        let start = Fixture.now.addingTimeInterval(-0.75)
        _ = Fixture.scored([Fixture.process(megabytes: 300, date: start)], window: &window, at: start)
        let family = try XCTUnwrap(Fixture.scored([Fixture.process(megabytes: 340)], window: &window).first)

        XCTAssertGreaterThan(family.trend.memoryVelocityMegabytesPerMinute, 1_000, "the raw two-point slope stays for charts")
        XCTAssertEqual(family.trend.credibleMemoryVelocity, 0)
        XCTAssertFalse(family.score.components.contains { $0.kind == .leak })
        XCTAssertFalse(family.score.reasons.contains { $0.contains("climbing") })
        XCTAssertLessThanOrEqual(family.score.level, .watch)
        XCTAssertFalse(family.score.heat.shouldRaiseLiveAlert)

        let rule = RadarRule(name: "Fast leaks", match: RadarRuleMatch(minimumLevel: .quiet, minimumLeakVelocity: 50), action: .highlight)
        XCTAssertTrue(RadarRuleEngine().suggestions(for: family, rules: [rule], now: Fixture.now).isEmpty)
    }

    func testSustainedClimbStillScoresAsALeak() throws {
        var window = TrendWindow()
        var family: ProcessFamily?
        for step in 0..<6 {
            let date = Fixture.now.addingTimeInterval(Double(step - 5) * 4)
            let megabytes = 300 + Double(step) * 200 * 4 / 60
            family = Fixture.scored([Fixture.process(megabytes: megabytes, date: date)], window: &window, at: date).first
        }
        let climbing = try XCTUnwrap(family)
        XCTAssertEqual(climbing.trend.credibleMemoryVelocity, 200, accuracy: 5)
        XCTAssertTrue(climbing.score.components.contains { $0.kind == .leak && $0.title.contains("climbing") })

        let rule = RadarRule(name: "Fast leaks", match: RadarRuleMatch(minimumLevel: .quiet, minimumLeakVelocity: 50), action: .highlight)
        XCTAssertFalse(RadarRuleEngine().suggestions(for: climbing, rules: [rule], now: Fixture.now).isEmpty)
    }
}

final class CorroborationHistoryTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let warning = SystemMemoryPressure(level: .warning, usedFraction: 0.88, totalBytes: 16 * 1_073_741_824,
                                               availableBytes: 2 * 1_073_741_824, compressedBytes: 1_073_741_824)

    func testHostPressureIsNotHistory() throws {
        var window = TrendWindow()
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: warning)
        let family = try XCTUnwrap(Fixture.scored([Fixture.process(megabytes: 1_300, cpu: 2)], context: context, window: &window).first)

        XCTAssertEqual(family.trend.sampleCount, 1)
        XCTAssertEqual(family.score.heat.sustainedSignalCount, 0)
        // An idle family is a bystander: pressure weighs its share but does
        // not corroborate it.
        XCTAssertEqual(family.score.heat.corroborationCount, 0)
        XCTAssertTrue(family.score.heat.evidence.contains { $0.hasPrefix("Host memory pressure is warning") })
        XCTAssertFalse(family.forecastIsCredibleEscalation)
        let verdict = FamilyVerdict.synthesize(family: family, pattern: family.trend.resolvedPattern)
        XCTAssertFalse(verdict.headline.hasPrefix("Leak"), verdict.headline)
    }

    func testSustainedGrowthUnderPressureStillEscalates() throws {
        var window = TrendWindow()
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: warning)
        var family: ProcessFamily?
        for step in 0..<6 {
            let date = Fixture.now.addingTimeInterval(Double(step - 5) * 4)
            let process = Fixture.process(megabytes: 1_300 + Double(step) * 200 * 4 / 60, cpu: 2, date: date)
            family = Fixture.scored([process], context: context, window: &window, at: date).first
        }
        let growing = try XCTUnwrap(family)
        XCTAssertTrue(growing.forecastIsCredibleEscalation)
        XCTAssertGreaterThanOrEqual(growing.forecast.state, .leaking)
    }
}
