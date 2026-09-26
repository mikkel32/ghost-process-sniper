import XCTest
@testable import GhostProcessSniperCore

final class VerdictLevelAgreementTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testHotFamilyWithAQuietForecastGetsAMeasuredVerdict() throws {
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([Fixture.process(parent: 999, megabytes: 1_700, cpu: 3)], window: &window).first)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        XCTAssertFalse(family.forecastIsCredibleEscalation)

        let verdict = FamilyVerdict.synthesize(family: family, pattern: family.trend.resolvedPattern)
        XCTAssertEqual(verdict.level, family.score.level)
        XCTAssertEqual(verdict.headline, "Using a lot of memory now")
        XCTAssertTrue(verdict.detail.hasSuffix("Not confirmed as a leak yet."), verdict.detail)
    }

    func testBehavingNormallyNeedsAQuietLevel() {
        let root = Fixture.process(parent: 999, megabytes: 400, cpu: 150)
        let heat = GhostHeat(value: 70, level: .hot, confidence: 0.6, evidence: [GhostHeat.instantCPUEvidence], sustainedSignalCount: 0)
        let baseline = FamilyBaseline(signature: ProcessSignature.from(root: root), sampleCount: 100,
            meanMemoryBytes: 400 * 1_048_576, peakMemoryBytes: 500 * 1_048_576, meanCPUPercent: 120, peakCPUPercent: 160,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0, firstSeenAt: Fixture.now.addingTimeInterval(-7_200),
            lastSeenAt: Fixture.now)
        let family = Fixture.family(root, level: .hot, heat: heat).enriched(baseline: baseline)

        let verdict = FamilyVerdict.synthesize(family: family, pattern: family.trend.resolvedPattern)
        XCTAssertNotEqual(verdict.headline, "Behaving normally")
        XCTAssertNotEqual(verdict.headline, "No unusual activity observed")
        XCTAssertEqual(verdict.headline, "CPU busy now")
        XCTAssertEqual(verdict.level, .hot)
    }
}
