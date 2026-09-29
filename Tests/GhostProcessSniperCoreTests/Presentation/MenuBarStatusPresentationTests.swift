import XCTest
@testable import GhostProcessSniperCore

/// The hover text and the right-click header are the two glanceable menu-bar
/// surfaces: each fact appears once, counts agree with the console's
/// "to review", and the header stays short enough not to widen the menu.
final class MenuBarStatusPresentationTests: XCTestCase {
    private func summary(
        _ statusText: String = "Quiet",
        level: GhostLevel = .quiet,
        families: Int = 28,
        hot: Int = 0,
        leaking: Int = 0
    ) -> RadarSummary {
        RadarSummary(statusText: statusText, level: level, familyCount: families, hotCount: hot,
                     totalMemoryBytes: 4_000_000_000, topFamilyName: "ChatGPT", leakingCount: leaking)
    }

    private func presentation(_ summary: RadarSummary, duplicateClusters: Int = 0, storeError: String? = nil) -> MenuBarStatusPresentation {
        var metrics = RadarPerformanceMetrics.empty
        metrics.smoothness.duplicateClusterCount = duplicateClusters
        return MenuBarStatusPresentation(summary: summary, engineStatus: .empty, metrics: metrics, storeError: storeError)
    }

    func testTheTooltipDoesNotRepeatTheHotCount() {
        let tooltip = presentation(summary("4 hot", level: .hot, hot: 4)).tooltip
        XCTAssertEqual(tooltip.components(separatedBy: "4").count - 1, 1, tooltip)
        XCTAssertTrue(tooltip.contains("4 to review"), tooltip)
        XCTAssertFalse(tooltip.contains("hot"), "the console says \"to review\": \(tooltip)")
        XCTAssertEqual(presentation(summary("4 hot", level: .hot, hot: 4)).reviewText, "4 to review")
        XCTAssertNil(presentation(summary()).reviewText)
    }

    func testAForecastStatusStillShowsBesideTheReviewCount() {
        let tooltip = presentation(summary("Leak 12m", level: .hot, hot: 1, leaking: 1)).tooltip
        XCTAssertEqual(tooltip, "Ghost Process Sniper: 1 to review - Leak 12m - 1 leak - 28 families")
    }

    func testNothingToReviewSaysSoAndDropsZeroCounts() {
        XCTAssertEqual(presentation(summary()).tooltip, "Ghost Process Sniper: Quiet - 28 families")
    }

    func testSingularsAreSingular() {
        let tooltip = presentation(summary("Leak 5m", level: .hot, families: 1, leaking: 1), duplicateClusters: 1).tooltip
        XCTAssertTrue(tooltip.contains("1 leak "), tooltip)
        XCTAssertFalse(tooltip.contains("leaks"), tooltip)
        XCTAssertTrue(tooltip.contains("1 family"), tooltip)
        XCTAssertFalse(tooltip.contains("families"), tooltip)
        XCTAssertTrue(tooltip.hasSuffix("1 duplicate cluster"), tooltip)

        let plural = presentation(summary("Leak 5m", level: .hot, families: 3, leaking: 2), duplicateClusters: 2).tooltip
        XCTAssertTrue(plural.contains("2 leaks"), plural)
        XCTAssertTrue(plural.hasSuffix("2 duplicate clusters"), plural)
    }

    func testTheMenuTitleStaysShortAndDropsTheCounts() {
        let busy = presentation(summary("Memory critical in 12m · Google Chrome Helper (Renderer)", level: .critical, hot: 12, leaking: 3),
                                duplicateClusters: 4)
        XCTAssertLessThanOrEqual(busy.menuTitle.count, 60, busy.menuTitle)
        XCTAssertFalse(busy.menuTitle.contains("famil"))
        XCTAssertFalse(busy.menuTitle.contains("duplicate"))
        XCTAssertEqual(presentation(summary("4 hot", level: .hot, hot: 4)).menuTitle, "Ghost Process Sniper: 4 to review")
    }

    func testALongStoreErrorShortensInTheMenuTitleButNotTheHoverText() {
        let error = String(repeating: "The radar database could not be opened. ", count: 8)
        let result = presentation(summary(), storeError: error)
        XCTAssertLessThanOrEqual(result.menuTitle.count, 60)
        XCTAssertTrue(result.menuTitle.contains("History not saved"), result.menuTitle)
        XCTAssertTrue(result.tooltip.contains("The radar database could not be opened."), "the hover text keeps the reason")
    }

    func testTheSpokenLabelUsesTheReviewWording() {
        XCTAssertEqual(presentation(summary("2 hot", level: .hot, hot: 2)).accessibilityLabel, "Ghost Process Sniper, 2 need review")
        XCTAssertEqual(presentation(summary("1 hot", level: .hot, hot: 1)).accessibilityLabel, "Ghost Process Sniper, 1 needs review")
        XCTAssertEqual(presentation(summary("Critical", level: .critical, hot: 3)).accessibilityLabel, "Ghost Process Sniper, Critical")
        XCTAssertEqual(presentation(summary("Leak 12m", level: .watch, leaking: 1)).accessibilityLabel, "Ghost Process Sniper, Leak detected")
    }

    func testDiagnosticsOnlyChangesDoNotInvalidateTheRenderKey() {
        var slow = RadarPerformanceMetrics.empty
        slow.smoothness.hitchCount = 9
        let quiet = summary("2 hot", level: .hot, hot: 2)
        let first = MenuBarStatusPresentation(summary: quiet, engineStatus: .empty, metrics: .empty)
        let second = MenuBarStatusPresentation(summary: quiet, engineStatus: .empty, metrics: slow)
        XCTAssertEqual(first.renderKey, second.renderKey)
    }
}
