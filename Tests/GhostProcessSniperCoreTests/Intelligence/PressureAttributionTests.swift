import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class PressureAttributionTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private static let gib: UInt64 = 1 << 30

    private func pressure(_ level: MemoryPressureLevel, total: UInt64 = 64 << 30, available: UInt64 = 4 << 30) -> SystemMemoryPressure {
        SystemMemoryPressure(level: level, usedFraction: 1 - Double(available) / Double(total), totalBytes: total,
                             availableBytes: available, compressedBytes: 2 << 30)
    }

    /// A 2 GB family, growing `rate` MB/min for a minute: long enough to be a leak.
    private func family(pid: Int32, rate: Double) -> ProcessFamily {
        let megabytes = (0..<13).map { 2_048 + Double($0) * rate * 5 / 60 }
        let root = Fixture.process(pid: pid, megabytes: megabytes.last ?? 2_048, cpu: 2)
        return Fixture.family(root, trend: Fixture.trend(megabytes: megabytes))
    }

    /// A family of `size` MB climbing `rate` MB/min in a steady line: 17
    /// samples ten seconds apart, enough for the trend to trust it. The
    /// smallest climb it trusts is about 5 MB/min.
    private func steadyFamily(pid: Int32, rate: Double, size: Double = 2_048) -> ProcessFamily {
        let megabytes = (0..<17).map { size + Double($0) * rate * 10 / 60 }
        let root = Fixture.process(pid: pid, megabytes: megabytes.last ?? size, cpu: 2)
        return Fixture.family(root, trend: Fixture.trend(megabytes: megabytes, cadence: 10))
    }

    private func enrich(_ family: ProcessFamily, _ context: RadarContext) -> ProcessFamily {
        RadarIntelligence().enrich(family: family, context: context, settings: .smart, now: Fixture.now)
    }

    func testOnlyTheGrowingFamilyIsBoostedAndCorroborated() throws {
        let grower = family(pid: 700, rate: 150)
        let idle = family(pid: 701, rate: 0)
        let critical = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: pressure(.critical))
            .attributingPressure(to: [grower, idle])
        let plain = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])

        let growing = enrich(grower, critical)
        let boost = try XCTUnwrap(growing.score.components.first { $0.slot == "pressure" })
        XCTAssertGreaterThanOrEqual(growing.score.heat.corroborationCount, 1)
        XCTAssertTrue(growing.score.reasons.contains { $0.contains("100% of recent growth") }, "\(growing.score.reasons)")
        XCTAssertTrue(boost.detail.contains("of used memory"), boost.detail)

        let bystander = enrich(idle, critical)
        XCTAssertEqual(bystander.score.heat.corroborationCount, 0)
        let bystanderBoost = bystander.score.value - enrich(idle, plain).score.value
        XCTAssertLessThan(bystanderBoost, 2)
        XCTAssertGreaterThan(growing.score.value - enrich(grower, plain).score.value, 10)
    }

    /// Growth is judged by its share, and the only family growing has all of
    /// it, however little that is. A trickle is not what starves the Mac, so
    /// it must not be voted the driver of pressure: that vote keeps a big app
    /// at its usual size from being held at Watch.
    func testALoneSlowGrowerIsNotTheDriverOfPressure() throws {
        let slow = steadyFamily(pid: 740, rate: 12)
        let idle = family(pid: 741, rate: 0)
        XCTAssertEqual(slow.trend.credibleMemoryVelocity, 12, accuracy: 3, "a credible climb, only a slow one")

        let warning = pressure(.warning, total: 16 << 30, available: 3 << 30)
        let shares = PressureAttribution.compute(families: [slow, idle], pressure: warning)
        let share = try XCTUnwrap(shares[slow.familyKey])
        XCTAssertEqual(share.growthShare, 1, accuracy: 0.001, "all of the growth there is")
        XCTAssertFalse(share.corroboratesPressure)
        XCTAssertFalse(share.text.contains("recent growth"), share.text)

        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: warning)
            .attributingPressure(to: [slow, idle])
        XCTAssertEqual(enrich(slow, context).score.heat.corroborationCount, 0, "no vote")
    }

    /// The boost follows how much the growth is, not only its share of it.
    func testTheGrowthBoostFollowsHowMuchTheFamilyGrows() throws {
        let warning = pressure(.warning, total: 16 << 30, available: 3 << 30)
        func share(of rate: Double) throws -> PressureShare {
            let grower = steadyFamily(pid: 742, rate: rate, size: 600)
            let shares = PressureAttribution.compute(families: [grower, family(pid: 743, rate: 0)], pressure: warning)
            return try XCTUnwrap(shares[grower.familyKey])
        }
        let trickle = try share(of: 6)
        XCTAssertEqual(trickle.growthShare, 1, accuracy: 0.001)
        XCTAssertLessThan(trickle.boostScale, 0.5, "a trickle earns part of the boost")
        XCTAssertGreaterThan(trickle.boostScale, 0.1, "but not none of it")

        let steady = try share(of: 60)
        XCTAssertEqual(steady.boostScale, 1, accuracy: 0.001)
        XCTAssertTrue(steady.corroboratesPressure)
        XCTAssertTrue(steady.text.contains("100% of recent growth"), steady.text)
    }

    /// Material growth is at least 20 MB/min, the same floor as the host
    /// countdown; a share built without a rate is judged as before.
    func testGrowthIsMaterialFromTwentyMegabytesAMinute() {
        func share(_ rate: Double) -> PressureShare {
            PressureShare(footprintShare: 0.1, growthShare: 1, growthMegabytesPerMinute: rate)
        }
        XCTAssertFalse(share(19.9).corroboratesPressure)
        XCTAssertLessThan(share(19.9).boostScale, 1)
        XCTAssertEqual(share(10).boostScale, 0.5, accuracy: 0.001)
        XCTAssertTrue(share(20).corroboratesPressure)
        XCTAssertEqual(share(20).boostScale, 1, accuracy: 0.001)
        XCTAssertEqual(share(0).boostScale, 0.4, accuracy: 0.001, "its footprint still counts")

        XCTAssertTrue(PressureShare(footprintShare: 0.1, growthShare: 1).corroboratesPressure)
        XCTAssertFalse(PressureShare(footprintShare: 0.1, growthShare: 0.29).corroboratesPressure, "and it must be most of the growth")
        XCTAssertEqual(PressureShare(footprintShare: 0.5, growthShare: 0, growthMegabytesPerMinute: 0).boostScale, 1, "a big holder is not a trickle")
        XCTAssertEqual(PressureShare.none.boostScale, 0)

        let outlook = PressureAttribution.outlook(families: [steadyFamily(pid: 744, rate: 12), steadyFamily(pid: 745, rate: 12)],
                                                  pressure: pressure(.warning, total: 16 << 30, available: 3 << 30))
        XCTAssertNotNil(outlook, "two trickles that add up to 24 MB/min still count down together")
    }

    func testHostETAIsHeadroomOverCredibleGrowth() throws {
        let fast = family(pid: 710, rate: 150)
        let slow = family(pid: 711, rate: 50)
        let tight = pressure(.warning, total: 16 << 30, available: 3 << 30)
        let outlook = try XCTUnwrap(PressureAttribution.outlook(families: [fast, slow], pressure: tight))
        let reserve = Double(PressureAttribution.criticalReserve(totalBytes: 16 << 30)) / 1_048_576
        let expected = (3_072 - reserve) / (outlook.growthMegabytesPerMinute) * 60
        XCTAssertEqual(outlook.growthMegabytesPerMinute, 200, accuracy: 5)
        XCTAssertEqual(outlook.etaSeconds, expected, accuracy: 1)
        XCTAssertEqual(outlook.topContributors.first, fast.familyKey)

        let summary = RadarSummaryBuilder.summary(for: [fast, slow], hostOutlook: outlook)
        XCTAssertEqual(summary.hostPressureCulprit, "node")
        XCTAssertTrue(summary.statusText.hasPrefix("Memory critical in ~"), summary.statusText)

        // No outlook without real growth, or while pressure is nominal.
        XCTAssertNil(PressureAttribution.outlook(families: [family(pid: 712, rate: 0)], pressure: tight))
        XCTAssertNil(PressureAttribution.outlook(families: [fast], pressure: pressure(.nominal, total: 16 << 30, available: 3 << 30)))
    }

    func testFamilyForecastCountsDownToCriticalPressure() {
        let fast = family(pid: 715, rate: 150)
        let tight = pressure(.warning, total: 16 << 30, available: 3 << 30)
        let outlook = PressureAttribution.outlook(families: [fast], pressure: tight)
        var settings = ThresholdSettings.smart
        settings.memoryBytes = 64 << 30
        let forecast = FamilyRiskForecaster().forecast(family: fast, settings: settings, now: Fixture.now,
                                                        pressure: tight, hostOutlook: outlook)
        XCTAssertEqual(forecast.etaKind, .hostMemory)
        XCTAssertTrue(forecast.whyNow.contains("memory pressure turns critical"), forecast.whyNow)
    }

    func testNoHeadroomLeftIsNotAFamilyLimitBreach() throws {
        // 800 MB free is below the 1.28 GB critical reserve of a 16 GB Mac.
        let grower = family(pid: 716, rate: 30)
        let exhausted = pressure(.critical, total: 16 << 30, available: 800 << 20)
        let belowReserve = pressure(.warning, total: 16 << 30, available: 800 << 20)
        XCTAssertNil(PressureAttribution.outlook(families: [grower], pressure: exhausted))
        XCTAssertNil(PressureAttribution.outlook(families: [grower], pressure: belowReserve))
        XCTAssertNil(PressureAttribution.familyETASeconds(velocity: 30, pressure: exhausted))
        XCTAssertNil(PressureAttribution.familyETASeconds(velocity: 30, pressure: belowReserve))

        var settings = ThresholdSettings.smart
        settings.memoryBytes = 64 << 30
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: exhausted)
            .attributingPressure(to: [grower])
        let scored = RadarIntelligence().enrich(family: grower, context: context, settings: settings, now: Fixture.now)
        XCTAssertNotEqual(scored.forecast.horizon, .breached)
        XCTAssertNotEqual(scored.forecast.etaKind, .hostMemory)
        XCTAssertFalse(scored.forecast.whyNow.contains("memory limit"), scored.forecast.whyNow)
        let verdict = FamilyVerdict.synthesize(family: scored, pattern: scored.trend.resolvedPattern)
        XCTAssertFalse(verdict.detail.contains("above its memory limit"), verdict.detail)

        let summary = RadarSummaryBuilder.summary(for: [scored], hostOutlook: context.hostOutlook)
        XCTAssertFalse(summary.statusText.hasPrefix("Memory critical in"), summary.statusText)
    }

    func testHostCountdownReadsAsPressureNotAMemoryLimit() throws {
        let fast = family(pid: 717, rate: 150)
        let tight = pressure(.warning, total: 16 << 30, available: 3 << 30)
        var settings = ThresholdSettings.smart
        settings.memoryBytes = 64 << 30
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: tight)
            .attributingPressure(to: [fast])
        let scored = RadarIntelligence().enrich(family: fast, context: context, settings: settings, now: Fixture.now)
        XCTAssertEqual(scored.forecast.etaKind, .hostMemory)
        XCTAssertFalse(scored.forecast.whyNow.contains("memory limit"), scored.forecast.whyNow)
        let verdict = FamilyVerdict.synthesize(family: scored, pattern: scored.trend.resolvedPattern)
        XCTAssertFalse(verdict.detail.contains("memory limit"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("Memory pressure turns critical in"), verdict.detail)
        XCTAssertFalse(scored.forecast.recommendedAction.detail.contains("memory limit"), scored.forecast.recommendedAction.detail)
    }

    func testNominalPressureChangesNothing() {
        let grower = family(pid: 720, rate: 150)
        let nominal = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: pressure(.nominal))
        let attributed = nominal.attributingPressure(to: [grower])
        XCTAssertTrue(attributed.pressureShares.isEmpty)
        XCTAssertNil(attributed.hostOutlook)
        let scored = enrich(grower, attributed)
        XCTAssertFalse(scored.score.components.contains { $0.slot == "pressure" })
    }

    func testScoringCacheRescoresWhenAShareCrossesAStep() {
        let family = family(pid: 730, rate: 0)
        func context(footprintShare: Double) -> RadarContext {
            RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: pressure(.warning),
                         pressureShares: [family.familyKey: PressureShare(footprintShare: footprintShare, growthShare: 0)])
        }
        let base = FamilyScoringCache.fingerprint(family: family, context: context(footprintShare: 0.20))
        XCTAssertEqual(base, FamilyScoringCache.fingerprint(family: family, context: context(footprintShare: 0.21)))
        XCTAssertNotEqual(base, FamilyScoringCache.fingerprint(family: family, context: context(footprintShare: 0.26)))
    }

    /// A trickle's boost follows its rate: the same share of the growth at a
    /// faster rate is scored again.
    func testScoringCacheRescoresWhenATrickleSpeedsUp() {
        let family = family(pid: 731, rate: 0)
        func context(rate: Double) -> RadarContext {
            RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: pressure(.warning),
                         pressureShares: [family.familyKey: PressureShare(footprintShare: 0.05, growthShare: 1, growthMegabytesPerMinute: rate)])
        }
        let slow = FamilyScoringCache.fingerprint(family: family, context: context(rate: 6))
        XCTAssertEqual(slow, FamilyScoringCache.fingerprint(family: family, context: context(rate: 6.5)))
        XCTAssertNotEqual(slow, FamilyScoringCache.fingerprint(family: family, context: context(rate: 10)))
    }
}
