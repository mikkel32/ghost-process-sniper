import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A row says why a family is on the radar. Before, every big family read
/// "Memory footprint" and every other flagged one "Activity to review", so
/// nine rows in a queue were told apart only by their names.
final class AttentionReasonTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let app = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    private let squeezed = SystemMemoryPressure(level: .warning, usedFraction: 0.92, totalBytes: 16 << 30,
                                                availableBytes: 1 << 30, compressedBytes: 4 << 30)

    private func chat(megabytes: Double = 1_700) -> ProcessMetrics {
        Fixture.process(pid: 11_850, name: "ChatGPT", path: app, command: app, megabytes: megabytes, cpu: 3)
    }

    private func scored(_ process: ProcessMetrics, pressure: SystemMemoryPressure = .unknown) throws -> ProcessFamily {
        var window = TrendWindow()
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: pressure)
        return try XCTUnwrap(Fixture.scored([process], context: context, window: &window).first)
    }

    private func node(_ pid: Int32, _ script: String) -> ProcessMetrics {
        Fixture.process(pid: pid, name: "node", path: "/usr/local/bin/node", command: "node \(script)", megabytes: 200, cpu: 1)
    }

    private func row(_ family: ProcessFamily) -> CompactSidebarRowModel {
        CompactSidebarRowModel(item: FamilyTriageViewModel(family: family))
    }

    /// The Overview hero for a family that is the only one in the queue.
    private func hero(_ family: ProcessFamily) -> RadarIntelligenceBrief {
        let summary = RadarSummary(statusText: "1 hot", level: family.score.level, familyCount: 1, hotCount: 1,
                                   totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName,
                                   leakingCount: 0, suggestionCount: 0)
        return CompactConsoleSnapshot.build(
            summary: summary, triage: [FamilyTriageViewModel(family: family)],
            detailPanels: [family.familyKey: FamilyDetailPanelModel(family: family)], engineStatus: .empty
        ).intelligenceBrief
    }

    /// Claude at 1.7 GB with the Mac short of memory: the limit tightens, the
    /// family holds a big share, and that, not its size, is why it is Review.
    func testAFamilyHoldingTheMemoryAMacIsShortOfSaysSo() throws {
        let family = try scored(chat(), pressure: squeezed)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        XCTAssertTrue(family.score.components.contains { $0.slot == "pressure" }, "\(family.score.components.map(\.slot))")

        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Memory is tight on this Mac")
        XCTAssertTrue(assessment.evidence.contains("system pressure is warning"), assessment.evidence)
        XCTAssertFalse(assessment.evidence.contains("Size alone"), "no hedge next to a specific reason")
        XCTAssertEqual(assessment.cause, "Memory footprint", "the category stays")

        let sidebar = row(family)
        XCTAssertEqual(sidebar.subtitle, "Memory is tight on this Mac")
        XCTAssertTrue(sidebar.helpText.hasPrefix("Memory is tight on this Mac."), sidebar.helpText)
    }

    func testAFamilyOverItsLimitWithNothingElseSaysSo() throws {
        let family = try scored(chat())
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        XCTAssertFalse(family.score.components.contains { $0.slot == "pressure" })

        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Over its memory limit")
        XCTAssertTrue(assessment.evidence.contains("limit"), assessment.evidence)
        XCTAssertEqual(row(family).subtitle, "Over its memory limit")
    }

    /// Two vites is why a 200 MB family is on the radar at all.
    func testCopiesAreTheReasonForASmallFamily() throws {
        var window = TrendWindow()
        let builder = ProcessFamilyBuilder(currentUserID: 501)
        let vite = "/Users/dev/web/node_modules/.bin/vite"
        let families = builder.buildFamiliesWithDuplicates(
            from: [node(900, "\(vite) --port 5173"), node(901, "\(vite) --port 5174")],
            settings: .smart, trendWindow: &window, now: Fixture.now).families
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        let family = RadarIntelligence().enrich(family: try XCTUnwrap(families.first), context: context, settings: .smart, now: Fixture.now)
        XCTAssertEqual(family.duplicateCluster?.countsAsIndependentCopies, true)
        XCTAssertLessThan(family.totalPhysicalFootprintBytes, 512 * Fixture.mib)
        XCTAssertGreaterThanOrEqual(family.score.level, .watch)

        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "2 copies running")
        XCTAssertEqual(assessment.cause, "Activity to review")
        XCTAssertTrue(assessment.evidence.contains("2 independent copies"), assessment.evidence)
        XCTAssertEqual(row(family).subtitle, "2 copies running")
    }

    func testAForgottenFamilySaysSo() {
        let root = Fixture.process(pid: 5_100, megabytes: 300, cpu: 0)
        let forgotten = GhostScoreComponent(slot: "forgotten", kind: .background, title: "likely forgotten",
                                            detail: "No CPU use for 3 h", impact: 8, level: .watch)
        let score = GhostScore(value: 30, level: .watch, reasons: [], components: [forgotten],
                               heat: GhostHeat(value: 32, level: .watch, confidence: 0.5, evidence: [], sustainedSignalCount: 0))
        let family = Fixture.family(root, level: .watch).enriched(score: score)

        let assessment = ProcessAssessment(family: family)
        XCTAssertEqual(assessment.reason, "Probably forgotten")
        XCTAssertTrue(assessment.evidence.contains("No CPU use for 3 h"), assessment.evidence)
    }

    /// Only the two generic labels are replaced, and only where there is
    /// something to say: quiet, unexplained and already specific families
    /// read exactly as before.
    func testOtherFamiliesKeepTheirCause() {
        let big = Fixture.family(Fixture.process(pid: 5_200, megabytes: 700, cpu: 1), level: .quiet)
        XCTAssertEqual(ProcessAssessment(family: big).reason, "Memory footprint")

        let unexplained = Fixture.family(Fixture.process(pid: 5_201, megabytes: 40, cpu: 1), level: .watch)
        XCTAssertEqual(ProcessAssessment(family: unexplained).reason, "Activity to review")

        let busy = Fixture.family(Fixture.process(pid: 5_202, megabytes: 40, cpu: 150), level: .watch)
        XCTAssertEqual(ProcessAssessment(family: busy).reason, "CPU activity")

        let stale = Fixture.family(Fixture.process(pid: 5_203, megabytes: 40, cpu: 1, status: .unavailable), level: .watch)
        XCTAssertEqual(ProcessAssessment(family: stale).reason, "Waiting for a complete reading")
    }

    /// "ChatGPT: memory is tight on this Mac": the reason ends the sentence,
    /// and its capitals ("Mac", "CPU") survive the hero's lower case.
    func testTheHeroNamesTheReasonAndDropsTheContradictingHedge() throws {
        let brief = hero(try scored(chat(), pressure: squeezed))
        XCTAssertEqual(brief.title, "ChatGPT: memory is tight on this Mac")
        XCTAssertTrue(brief.detail.contains("1.7 GB"), brief.detail)
        XCTAssertFalse(brief.detail.contains("Size alone"), brief.detail)
    }

    func testTheReasonReadsAsTheEndOfASentence() {
        XCTAssertEqual(AttentionReason.inSentence("Memory is tight on this Mac"), "memory is tight on this Mac")
        XCTAssertEqual(AttentionReason.inSentence("Probably forgotten"), "probably forgotten")
        XCTAssertEqual(AttentionReason.inSentence("CPU above its usual"), "CPU above its usual")
        XCTAssertEqual(AttentionReason.inSentence("2 copies running"), "2 copies running")
        XCTAssertEqual(AttentionReason.inSentence("1.7x its usual size"), "1.7x its usual size")
        XCTAssertEqual(AttentionReason.inSentence(""), "")
    }
}
