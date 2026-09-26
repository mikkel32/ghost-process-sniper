import XCTest
@testable import GhostProcessSniperCore

final class StableIdentityTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private let notify = RadarRule(name: "Notify vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .quiet),
                                   action: .notify)
    private let highlight = RadarRule(name: "Highlight vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .quiet),
                                      action: .highlight)

    func testEnrichingTwiceKeepsSuggestionAndComponentIDs() throws {
        let first = try enriched(megabytes: 1_400, cpu: 140, at: Fixture.now)
        let second = try enriched(megabytes: 1_430, cpu: 151, at: Fixture.now.addingTimeInterval(1))

        XCTAssertFalse(first.suggestions.isEmpty)
        XCTAssertEqual(first.suggestions.map(\.id), second.suggestions.map(\.id))
        XCTAssertEqual(first.score.components.map(\.id), second.score.components.map(\.id))
        XCTAssertNotEqual(first.score.components.map(\.impact), second.score.components.map(\.impact))
    }

    func testComponentIDsAreUniqueWithinAFamily() throws {
        let family = try enriched(megabytes: 1_400, cpu: 140, at: Fixture.now)
        let ids = family.score.components.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNormalizationKeepsTheLargerOfTwoComponentsInOneSlot() {
        let components = [
            GhostScoreComponent(slot: "baseline.memory", kind: .baseline, title: "a", detail: "", impact: 2, level: .watch),
            GhostScoreComponent(slot: "baseline.memory", kind: .baseline, title: "b", detail: "", impact: 6, level: .hot),
            GhostScoreComponent(slot: "cpu", kind: .cpu, title: "c", detail: "", impact: 2, level: .watch)
        ]
        let normalized = GhostScoreComponentMath.normalized(components, to: 16)
        XCTAssertEqual(normalized.map(\.slot), ["baseline.memory", "cpu"])
        XCTAssertEqual(normalized.first?.title, "b")
        XCTAssertEqual(normalized.reduce(0) { $0 + $1.impact }, 16, accuracy: 0.001)
    }

    func testSuggestionIDsDependOnlyOnSourceAndAction() {
        let rule = UUID()
        XCTAssertEqual(RadarActionSuggestion.stableID(ruleID: rule, type: .notify),
                       RadarActionSuggestion(type: .notify, title: "x", detail: "y", ruleID: rule).id)
        XCTAssertNotEqual(RadarActionSuggestion.stableID(ruleID: rule, type: .notify),
                          RadarActionSuggestion.stableID(ruleID: rule, type: .highlight))
        XCTAssertNotEqual(RadarActionSuggestion.stableID(ruleID: nil, type: .inspect),
                          RadarActionSuggestion.stableID(ruleID: rule, type: .inspect))
    }

    func testPipelineCarriesSuggestionStartTimes() throws {
        let families = try runPipeline(rules: [notify, highlight])
        let first = try XCTUnwrap(families.first)
        let last = try XCTUnwrap(families.last)
        XCTAssertFalse(first.suggestions.isEmpty)
        let lastDates = Dictionary(uniqueKeysWithValues: last.suggestions.map { ($0.id, $0.createdAt) })
        for suggestion in first.suggestions {
            XCTAssertEqual(lastDates[suggestion.id], suggestion.createdAt, suggestion.title)
        }
    }

    func testPipelineCarriesAlertStartTime() throws {
        let snooze = RadarRule(name: "Snooze vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .quiet),
                               action: .snooze, expiresAt: Fixture.now.addingTimeInterval(600))
        let families = try runPipeline(rules: [snooze])
        XCTAssertEqual(families.map(\.alertState.kind), [.snoozed, .snoozed, .snoozed])
        XCTAssertEqual(Set(families.map(\.alertState.since)), [Fixture.now])
    }

    private func runPipeline(rules: [RadarRule]) throws -> [ProcessFamily] {
        var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: 501))
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: rules)
        return try (0..<3).map { tick in
            let date = Fixture.now.addingTimeInterval(Double(tick) * 2)
            let root = Fixture.process(pid: 46_000, command: "node node_modules/.bin/vite",
                                       megabytes: 3_000 + Double(tick) * 7, cpu: 150 + Double(tick) * 3, date: date)
            let output = pipeline.run(processes: [root], settings: .smart, context: context, now: date)
            return try XCTUnwrap(output.families.first { $0.root.pid == 46_000 })
        }
    }

    private func enriched(megabytes: Double, cpu: Double, at date: Date) throws -> ProcessFamily {
        let root = Fixture.process(pid: 46_010, command: "node node_modules/.bin/vite", megabytes: megabytes, cpu: cpu, date: date)
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [notify, highlight])
        var window = TrendWindow()
        return try XCTUnwrap(Fixture.scored([root], context: context, window: &window, at: date).first)
    }
}
