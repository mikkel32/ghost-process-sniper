import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The Overview hero's evidence falls back to the score's components when the
/// heat has no evidence lines of its own; it must not list scope relevance
/// or a quiet component's ratio as the reason for a Hot family.
final class HeroEvidenceTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testTheOverviewHeroListsWhatWasRaisedNotScopeRelevance() {
        let root = Fixture.process(pid: 5_400, megabytes: 900, cpu: 95)
        let components = [
            GhostScoreComponent(slot: "relevance", kind: .background, title: "Process relevance",
                                detail: "85% confidence this belongs to the selected radar scope", impact: 40, level: .watch),
            GhostScoreComponent(slot: "memory", kind: .memory, title: "memory above threshold",
                                detail: "900 MB is 1.1x the 800 MB limit", impact: 30, level: .hot),
            GhostScoreComponent(slot: "gpu", kind: .gpu, title: "GPU activity", detail: "0% GPU utilization", impact: 1, level: .quiet)
        ]
        let heat = GhostHeat(value: 70, level: .hot, confidence: 0.7, evidence: [], sustainedSignalCount: 1)
        let family = Fixture.family(root, level: .hot).enriched(
            score: GhostScore(value: 70, level: .hot, reasons: [], components: components, heat: heat))
        let summary = RadarSummary(statusText: "1 hot", level: .hot, familyCount: 1, hotCount: 1,
                                   totalMemoryBytes: family.totalPhysicalFootprintBytes, topFamilyName: family.displayName,
                                   leakingCount: 0, suggestionCount: 0)

        let brief = CompactConsoleSnapshot.build(
            summary: summary, triage: [FamilyTriageViewModel(family: family)],
            detailPanels: [family.familyKey: FamilyDetailPanelModel(family: family)], engineStatus: .empty
        ).intelligenceBrief

        XCTAssertEqual(brief.familyKey, family.familyKey)
        XCTAssertEqual(brief.evidence, ["memory above threshold"])
    }
}
