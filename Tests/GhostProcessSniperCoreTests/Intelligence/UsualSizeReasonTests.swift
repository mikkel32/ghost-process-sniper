import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A big app's row says what it was compared with: "1.7x its usual size",
/// never the bare "Memory footprint", and never a reassurance while the
/// family is Hot.
final class UsualSizeReasonTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let app = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    private let squeezed = SystemMemoryPressure(level: .warning, usedFraction: 0.92, totalBytes: 16 << 30,
                                                availableBytes: 1 << 30, compressedBytes: 4 << 30)
    private let starved = SystemMemoryPressure(level: .critical, usedFraction: 0.97, totalBytes: 16 << 30,
                                               availableBytes: 500 << 20, compressedBytes: 6 << 30)

    private func chat(megabytes: Double) -> ProcessMetrics {
        Fixture.process(pid: 11_850, name: "ChatGPT", path: app, command: app, megabytes: megabytes, cpu: 3)
    }

    /// The family scored against a trusted baseline of `usual` megabytes.
    private func score(_ process: ProcessMetrics, usual megabytes: Double, spread: Double = 150,
                       pressure: SystemMemoryPressure = .unknown) throws -> ProcessFamily {
        var window = TrendWindow()
        let probe = try XCTUnwrap(Fixture.scored([process], window: &window).first)
        let mib = Double(Fixture.mib)
        let baseline = FamilyBaseline(
            signature: probe.signature, sampleCount: 2_000, meanMemoryBytes: megabytes * mib,
            peakMemoryBytes: UInt64(megabytes * 1.2 * mib), meanCPUPercent: 3, peakCPUPercent: 40,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: Fixture.now.addingTimeInterval(-86_400), lastSeenAt: Fixture.now.addingTimeInterval(-5),
            memoryVariance: (spread * mib) * (spread * mib), cpuVariance: 25, observedSeconds: 36_000, sessionCount: 4)
        let context = RadarContext(baselines: [probe.signature.id: baseline], recentIncidentCounts: [:], rules: [],
                                   systemPressure: pressure)
        var fresh = TrendWindow()
        return try XCTUnwrap(Fixture.scored([process], context: context, window: &fresh).first)
    }

    /// ChatGPT at 1.7 GB against a usual 1 GB.
    func testAFamilyBiggerThanItsUsualSizeSaysByHowMuch() throws {
        let family = try score(chat(megabytes: 1_700), usual: 1_000, spread: 600)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)

        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "1.7x its usual size")
        XCTAssertTrue(assessment.evidence.contains("against a usual"), assessment.evidence)
        XCTAssertFalse(assessment.evidence.contains("Size alone"), assessment.evidence)
        XCTAssertEqual(CompactSidebarRowModel(item: FamilyTriageViewModel(family: family)).subtitle, "1.7x its usual size")
    }

    /// A small family far above its own usual is on the radar for that.
    func testASmallFamilyFarAboveItsUsualSaysSoToo() throws {
        let family = try score(Fixture.process(pid: 40_100, megabytes: 450, cpu: 3), usual: 100, spread: 20)
        XCTAssertLessThan(family.totalPhysicalFootprintBytes, 512 * Fixture.mib)
        XCTAssertGreaterThanOrEqual(family.score.level, .watch)
        XCTAssertEqual(ProcessAssessment(family: family).reason, "4.5x its usual size")
    }

    /// Claude at 1.7 GB against a usual 2.4 GB is Review because the Mac is
    /// critically short of memory, and the page must not say it is big for itself.
    func testBelowItsUsualSizeItIsThePressureNotTheSize() throws {
        let family = try score(chat(megabytes: 1_700), usual: 2_450, pressure: starved)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)

        XCTAssertEqual(ProcessAssessment(family: family).reason, "Memory is tight on this Mac")
        let verdict = FamilyVerdict.synthesize(family: family, pattern: family.trend.resolvedPattern)
        XCTAssertEqual(verdict.headline, "Memory is tight on this Mac")
        XCTAssertTrue(verdict.detail.hasSuffix("Not confirmed as a leak yet."), verdict.detail)
        XCTAssertEqual(verdict.level, family.score.level)
    }

    /// The family page and the row agree: one multiple, in the same words.
    func testTheFamilyPageAndTheRowAgreeOnTheMultiple() throws {
        let family = try score(chat(megabytes: 1_700), usual: 1_000, spread: 600)
        let panel = FamilyDetailPanelModel(family: family)

        XCTAssertEqual(panel.brief.headline, "Bigger than usual for it")
        XCTAssertEqual(panel.brief.level, family.score.level, "Hot stays Hot")
        XCTAssertTrue(panel.brief.detail.contains("against a usual"), panel.brief.detail)
        XCTAssertTrue(panel.brief.detail.hasSuffix("Not confirmed as a leak yet."), panel.brief.detail)
        XCTAssertEqual(panel.brief.baselineText, "1.7x usual")
        XCTAssertTrue(panel.assessment.reason.hasPrefix("1.7x"), panel.assessment.reason)
        XCTAssertEqual(panel.brief.recommendationText, panel.assessment.recommendation, "one wording, not a second opinion")
    }

    /// At Watch with nothing else against it, the row says why it is calm.
    func testABigAppAtItsUsualSizeSaysItIsNormalForIt() throws {
        let family = try score(chat(megabytes: 2_560), usual: 2_450, spread: 150)
        XCTAssertEqual(family.score.level, .watch)

        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Large, but normal for it")
        XCTAssertTrue(assessment.evidence.contains("usual"), assessment.evidence)
        XCTAssertEqual(assessment.status, "Observe")
    }

    /// A Mac that is short of memory does not make a big app's usual size a
    /// problem: it is Watch with the reason it was before, and Claude at 1.7
    /// GB against a usual 2.4 GB is not blamed for the Mac's memory.
    func testItStaysNormalForItWhileTheMacIsShortOfMemory() throws {
        let family = try score(chat(megabytes: 2_560), usual: 2_450, spread: 150, pressure: squeezed)
        XCTAssertEqual(family.score.level, .watch)
        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Large, but normal for it")
        XCTAssertEqual(assessment.status, "Observe")

        let smaller = try score(chat(megabytes: 1_700), usual: 2_450, pressure: squeezed)
        XCTAssertEqual(smaller.score.level, .watch)
        XCTAssertEqual(ProcessAssessment(family: smaller).reason, "Large, but normal for it")
    }

    /// Never a reassurance next to a Hot badge: with the Mac critically short
    /// of memory the family is not held at Watch, and does not say it is normal.
    func testANormalSizeIsNotClaimedForAHotFamily() throws {
        let family = try score(chat(megabytes: 2_560), usual: 2_450, spread: 150, pressure: starved)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        XCTAssertNotEqual(ProcessAssessment(family: family).reason, "Large, but normal for it")

        let stale = family.enriched(score: GhostScore(
            value: family.score.value, level: .hot, reasons: [], components: family.score.components,
            heat: family.score.heat.replacing(evidence: ["\(GhostHeat.usualSizeEvidence): about 2.4 GB is its usual size"])))
        XCTAssertNotEqual(ProcessAssessment(family: stale).reason, "Large, but normal for it", "Hot, whatever the evidence says")
    }

    /// Without a learned normal there is nothing to compare with, and the
    /// verdict says exactly what it did.
    func testWithoutABaselineTheVerdictIsUnchanged() throws {
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([Fixture.process(parent: 999, megabytes: 1_700, cpu: 3)], window: &window).first)
        let verdict = FamilyVerdict.synthesize(family: family, pattern: family.trend.resolvedPattern)
        XCTAssertEqual(verdict.headline, "Using a lot of memory now")
        XCTAssertEqual(ProcessAssessment(family: family).reason, "Over its memory limit")
    }
}
