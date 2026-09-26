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

    /// A 2 GB family, growing `rate` MB/min over eight samples.
    private func family(pid: Int32, rate: Double) -> ProcessFamily {
        let megabytes = (0..<8).map { 2_048 + Double($0) * rate * 5 / 60 }
        let root = Fixture.process(pid: pid, megabytes: megabytes.last ?? 2_048, cpu: 2)
        return Fixture.family(root, trend: Fixture.trend(megabytes: megabytes))
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
}
