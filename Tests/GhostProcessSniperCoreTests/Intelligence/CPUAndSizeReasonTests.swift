import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Busy families all read "CPU activity" and big ones "Memory footprint",
/// and a family over its memory limit that also kept a core busy was filed
/// under CPU: its row said "CPU activity" when memory was why it was there.
final class CPUAndSizeReasonTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let start = Date(timeIntervalSince1970: 600_000)

    /// On a fixed 8-core Mac: the family CPU limit is 360%.
    private func scored(_ process: ProcessMetrics) throws -> ProcessFamily {
        var window = TrendWindow()
        return try XCTUnwrap(Fixture.scored([process], processorCount: 8, window: &window).first)
    }

    /// Finished minutes at `cores`, then the minute in progress.
    private func activity(_ cores: [Double], dominantShare: Double = 1, changes: Int = 0) -> FamilyCPUActivity {
        let buckets = (cores + [cores.last ?? 0]).enumerated().map { index, level in
            CPUMinuteBucket(start: start.addingTimeInterval(Double(index) * 60), cpuSeconds: level * 60, wallSeconds: 60,
                            dominantCPUSeconds: level * 60 * dominantShare, memberChanges: changes)
        }
        return FamilyCPUActivity(buckets: buckets, lastActiveAt: start, measuredSince: start)
    }

    /// Scores `family` as it stands, then runs the real forecaster (8 cores) over its CPU ledger.
    private func enriched(_ family: ProcessFamily, components: [GhostScoreComponent] = []) -> ProcessFamily {
        let heat = GhostHeat(value: 40, level: .watch, confidence: 0.6, evidence: [], sustainedSignalCount: 0)
        let scored = family.enriched(score: GhostScore(value: 40, level: .watch, reasons: [], components: components, heat: heat))
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        return RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8))
            .enrich(family: scored, context: context, settings: .smart, now: Fixture.now)
    }

    func testAFamilyOverItsMemoryLimitIsNotFiledUnderCPU() throws {
        let app = "/Applications/Claude.app/Contents/MacOS/Claude"
        let family = try scored(Fixture.process(pid: 7_100, name: "Claude", path: app, command: app, megabytes: 1_700, cpu: 96))
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Over its memory limit")
        XCTAssertEqual(assessment.cause, "Memory footprint")
        XCTAssertEqual(assessment.systemImage, "memorychip")
    }

    func testAFamilyOverItsCPULimitSaysSo() throws {
        let family = try scored(Fixture.process(pid: 7_101, megabytes: 40, cpu: 420))
        XCTAssertGreaterThanOrEqual(family.score.level, .watch)
        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Over its CPU limit")
        XCTAssertEqual(assessment.cause, "CPU activity")
        XCTAssertTrue(assessment.evidence.contains("360% limit"), assessment.evidence)
    }

    /// Busy but inside its limit, with nothing proven: the generic label stays.
    func testBusyInsideItsLimitKeepsTheGenericLabel() throws {
        let family = enriched(Fixture.family(Fixture.process(pid: 7_102, megabytes: 40, cpu: 150)))
        XCTAssertEqual(ProcessAssessment(family: family).reason, "CPU activity")
    }

    func testABusyLoopSaysSo() {
        let root = Fixture.process(pid: 7_103, megabytes: 40, cpu: 100)
        let family = enriched(Fixture.family(root, activity: activity([1, 0.98, 1.01])))
        XCTAssertEqual(family.forecast.cpuBehavior?.kind, .spin)
        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Busy-looping on one core")
        XCTAssertTrue(assessment.evidence.hasPrefix("Busy-looping on one core for 3 min"), assessment.evidence)
    }

    func testMostOfTheMacSaysSo() {
        let root = Fixture.process(pid: 7_104, megabytes: 40, cpu: 700)
        let family = enriched(Fixture.family(root, activity: activity([7, 7.2, 6.9, 7.1], dominantShare: 0.3)))
        XCTAssertEqual(family.forecast.cpuBehavior?.kind, .machineSaturation)
        XCTAssertEqual(ProcessAssessment(family: family).reason, "Using most of this Mac's CPU")
    }

    /// A build over its limit is doing its job; the row says what it is.
    func testABuildOverItsLimitSaysBuildWork() {
        let root = Fixture.process(pid: 7_105, name: "swift-frontend", path: "/usr/bin/swift-frontend", megabytes: 400, cpu: 420)
        let build = Fixture.family(root, activity: activity([4.2, 4.1, 4.3], dominantShare: 0.4))
            .enriched(classification: DevClassification(kind: .swiftBuild, confidence: 0.95, reason: "Swift build toolchain",
                                                        traits: .buildOrTest))
        let cpu = GhostScoreComponent(slot: "cpu", kind: .cpu, title: "CPU above threshold", detail: "420% is 1.2x the 360% limit",
                                      impact: 40, level: .critical, ratio: 1.17)
        let family = enriched(build, components: [cpu])
        XCTAssertEqual(family.forecast.cpuBehavior?.kind, .expectedBurst)
        XCTAssertEqual(ProcessAssessment(family: family).reason, "Build or test work")
    }

    /// The last stretch before its limit is what makes a big family Hot: the row says so.
    func testAFamilyNearItsMemoryLimitSaysSo() throws {
        let family = try scored(Fixture.process(pid: 7_106, megabytes: 900, cpu: 1))
        XCTAssertEqual(family.score.level, .hot, "the hardware floor: 85% of the limit or more")
        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Near its memory limit")
        XCTAssertTrue(assessment.evidence.contains("0.9x the 1.0 GB limit"), assessment.evidence)
    }

    /// Big, not near its limit, and no usual size learned yet: say that it is being learned.
    func testALargeFamilyWithNoUsualYetSaysItIsLearning() throws {
        let family = try scored(Fixture.process(pid: 7_107, megabytes: 600, cpu: 1))
        XCTAssertEqual(family.score.level, .watch)
        XCTAssertNil(family.baseline)
        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Large; learning its usual")
        XCTAssertTrue(assessment.evidence.contains("twenty minutes"), assessment.evidence)
    }

    func testTheNewReasonsFitARowAndReadAsTheEndOfASentence() {
        let reasons = ["Near its memory limit", "Large; learning its usual", "Over its CPU limit", "Build or test work",
                       "Busy-looping on one core", "Using most of this Mac's CPU", "Busy; it usually idles", "Busy for 12 min"]
        for reason in reasons {
            XCTAssertLessThanOrEqual(reason.count, 28, reason)
        }
        XCTAssertEqual(AttentionReason.inSentence("Using most of this Mac's CPU"), "using most of this Mac's CPU")
    }
}
