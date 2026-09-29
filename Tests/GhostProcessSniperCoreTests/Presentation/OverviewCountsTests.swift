import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A number on the Overview invites a click, so it has to be the size of the
/// list the click opens, and one definition of "needs review" serves the
/// hero, the card, the Risk Queue and the filter.
final class OverviewCountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 30_000)

    // MARK: Needs review

    func testTheNeedsReviewCardCountsExactlyWhatItOpens() {
        let hot = (0..<10).map { family(pid: Int32(100 + $0), level: .hot) }
        let watched = (0..<3).map { family(pid: Int32(200 + $0), level: .watch) }
        let snapshot = build(hot + watched)

        let card = snapshot.compact.commandCenter.chips.first { $0.title == "Needs review" }
        XCTAssertEqual(card?.value, "10")
        XCTAssertEqual(card?.destination, .review)
        XCTAssertEqual(card?.destination?.filter, .review)
        XCTAssertEqual(snapshot.families(query: "", filter: .attention, sort: .smart).count, 13, "Attention is the wider list")
        XCTAssertEqual(snapshot.compact.commandCenter.statusText, "10 to review")
    }

    /// Every card that opens a list says how long the list is.
    func testEveryCountedCardMatchesItsDestinationList() {
        let leaker = family(pid: 300, level: .hot, components: [leakComponent(.hot)], forecast: forecast(.warming))
        let escalating = family(pid: 310, level: .watch, forecast: forecast(.leaking), trend: history(samples: 6))
        let families = [leaker, escalating, family(pid: 320, level: .hot), family(pid: 330, level: .watch),
                        family(pid: 340, level: .quiet)]
        let snapshot = build(families)

        var checked = 0
        for chip in snapshot.compact.commandCenter.chips {
            guard let filter = chip.destination?.filter, chip.title != "Memory" else { continue }
            XCTAssertEqual(Int(chip.value), snapshot.families(query: "", filter: filter, sort: .smart).count, chip.title)
            checked += 1
        }
        XCTAssertEqual(checked, 3, "Families, Needs review and Leaks")
    }

    func testTheReviewFilterIsTheSummaryDefinition() {
        let families = [family(pid: 400, level: .hot),
                        family(pid: 410, level: .watch, forecast: forecast(.leaking), trend: history(samples: 6)),
                        family(pid: 420, level: .watch, forecast: forecast(.leaking), trend: history(samples: 2)),
                        family(pid: 430, level: .watch), family(pid: 440, level: .quiet)]
        let snapshot = build(families)
        let reviewed = snapshot.families(query: "", filter: .review, sort: .smart)
        XCTAssertEqual(Set(reviewed.map(\.familyKey)), Set([families[0], families[1]].map(\.familyKey)))
        XCTAssertEqual(snapshot.summary.hotCount, reviewed.count)
        XCTAssertEqual(families.filter(\.needsReview).count, reviewed.count)
        XCTAssertEqual(snapshot.compact.allRows.filter(\.needsReview).count, reviewed.count)
    }

    // MARK: Risk Queue

    func testTheRiskQueueCountsEveryFamilyAndShowsTheTopEight() {
        let snapshot = build((0..<11).map { family(pid: Int32(500 + $0), level: .hot) } +
                             (0..<3).map { family(pid: Int32(600 + $0), level: .watch) })
        XCTAssertEqual(snapshot.summary.hotCount, 11)
        XCTAssertEqual(snapshot.compact.riskCount, 11, "uncapped, like the hero's count")
        XCTAssertEqual(snapshot.compact.topRiskRows.count, 8, "the queue keeps its cap")
        XCTAssertEqual(snapshot.families(query: "", filter: .review, sort: .smart).count, 11)
    }

    func testTheRiskCountSurvivesAnEngineStatusRefresh() {
        let snapshot = build((0..<11).map { family(pid: Int32(700 + $0), level: .hot) })
        let refreshed = snapshot.compact.updatingEngineStatus(.empty, summary: snapshot.summary)
        XCTAssertEqual(refreshed.riskCount, 11)
    }

    /// Two samples can make any allocation jump look like a leak: such a
    /// forecast waits in Warming Up until it has history, as the count says.
    func testAForecastWithoutHistoryIsNotAReviewItemYet() {
        let thin = family(pid: 800, level: .watch, forecast: forecast(.leaking), trend: history(samples: 2))
        let snapshot = build([thin])
        XCTAssertFalse(thin.needsReview)
        XCTAssertEqual(snapshot.summary.hotCount, 0)
        XCTAssertTrue(snapshot.compact.topRiskRows.isEmpty)
        XCTAssertEqual(snapshot.compact.riskCount, 0)
        XCTAssertEqual(snapshot.compact.warmingRows.map(\.familyKey), [thin.familyKey])
    }

    func testAForecastWithHistoryIsInTheQueueAndTheCount() {
        let proven = family(pid: 810, level: .watch, forecast: forecast(.leaking), trend: history(samples: 6))
        let snapshot = build([proven])
        XCTAssertTrue(proven.needsReview)
        XCTAssertEqual(snapshot.summary.hotCount, 1)
        XCTAssertEqual(snapshot.compact.topRiskRows.map(\.familyKey), [proven.familyKey])
        XCTAssertEqual(snapshot.compact.riskCount, 1)
    }

    // MARK: Leaks

    /// "Sustained memory growth" reads from any credible leak, so the count
    /// and the Leaks list cannot leave one out.
    func testALeakComponentAtHotIsCountedByTheLeaksCard() {
        let leaking = family(pid: 900, level: .hot, components: [leakComponent(.hot)], forecast: forecast(.warming))
        XCTAssertTrue(leaking.hasCredibleLeak)
        let snapshot = build([leaking])
        XCTAssertEqual(snapshot.summary.leakingCount, 1)
        XCTAssertEqual(snapshot.families(query: "", filter: .leaking, sort: .smart).count, 1)
        XCTAssertEqual(snapshot.compact.commandCenter.chips.first { $0.title == "Leaks" }?.value, "1")
    }

    // MARK: Destinations

    func testEveryCardOpensTheListItCountsOrItsOwnPage() {
        XCTAssertEqual(OverviewMetricDestination.families.filter, .all)
        XCTAssertEqual(OverviewMetricDestination.review.filter, .review)
        XCTAssertEqual(OverviewMetricDestination.leaking.filter, .leaking)
        XCTAssertNil(OverviewMetricDestination.duplicates.filter)
        XCTAssertNil(OverviewMetricDestination.memory.filter, "sorted, not filtered")
    }

    func testReviewIsTheSecondFilterAndSurvivesItsStoredName() {
        XCTAssertEqual(RadarFilter.allCases.prefix(2).map(\.label), ["All", "Review"])
        XCTAssertEqual(RadarFilter(rawValue: RadarFilter.review.rawValue), .review)
    }

    // MARK: Fixtures

    private func build(_ families: [ProcessFamily]) -> RadarConsoleSnapshot {
        let summary = ProcessFamilyBuilder(currentUserID: 501).summary(for: families)
        return RadarConsoleSnapshot.build(
            families: families, summary: summary, incidents: [], rules: [], metrics: .empty,
            health: .starting, storeHealth: .empty, storeError: nil, previous: nil,
            generatedAt: now, detailSignatures: [], processes: []
        )
    }

    private func leakComponent(_ level: GhostLevel) -> GhostScoreComponent {
        GhostScoreComponent(slot: "leak", kind: .leak, title: "Memory growth", detail: "", impact: 26, level: level)
    }

    private func forecast(_ state: ForecastState, confidence: Double = 0.6) -> RiskForecast {
        RiskForecast(
            state: state, horizon: .later, confidence: confidence, etaSeconds: nil, etaText: "No threshold ETA",
            whyNow: "test", recommendedAction: TriageRecommendation(title: "Watch closely", detail: "", action: .highlight,
                                                                    confidence: confidence),
            projectedMemoryBytes: 0, projectedCPUPercent: 0, leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0, staleLikelihood: 0, baseline: .unknown, generatedAt: now)
    }

    /// A flat memory history of the given length.
    private func history(samples count: Int) -> TrendMetrics {
        let dated = (0..<count).map { index in
            TrendSample(date: now.addingTimeInterval(Double(index - count + 1) * 12), memoryBytes: 900_000_000, cpuPercent: 3)
        }
        return TrendMetrics(memoryVelocityMegabytesPerMinute: 0, cpuSlopePerMinute: 0,
                            memoryPoints: dated.map { Double($0.memoryBytes) }, samples: dated)
    }

    private func family(pid: Int32, level: GhostLevel, components: [GhostScoreComponent] = [],
                        forecast: RiskForecast = .quiet, trend: TrendMetrics = .empty) -> ProcessFamily {
        let root = ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "test", name: "family\(pid)",
            executablePath: "/usr/local/bin/family\(pid)", commandLine: "family\(pid) --serve",
            residentMemoryBytes: 900_000_000, physicalFootprintBytes: 900_000_000,
            virtualMemoryBytes: 1_800_000_000, cpuPercent: 95, totalProcessorSeconds: 100,
            threadCount: 8, isSystemProcess: false, sampledAt: now)
        return ProcessFamily(
            root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
            totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: 95, devConfidence: 0.9,
            commandHints: [root.commandLine], trend: trend,
            score: GhostScore(value: 60, level: level, reasons: ["CPU pinned"], components: components),
            ownedIdentities: [root.identity], protectedPIDs: [], forecast: forecast, lastScoredAt: now)
    }
}
