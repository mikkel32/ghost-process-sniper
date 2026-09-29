import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The Incidents page publishes only the newest 80 incidents; search and the
/// Resolved and Critical filters read the whole log instead.
final class IncidentHistoryProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)

    // MARK: Which queries need the history

    func testOnlySearchAndOlderFiltersReachTheHistory() {
        XCTAssertFalse(IncidentQuery.default.reachesHistory)
        XCTAssertFalse(IncidentQuery(text: "   ").reachesHistory, "blank text searches nothing")
        XCTAssertFalse(IncidentQuery(filter: .active).reachesHistory, "active incidents always sit in the newest rows")
        XCTAssertFalse(IncidentQuery(sort: .memory).reachesHistory)
        XCTAssertTrue(IncidentQuery(text: "chrome").reachesHistory)
        XCTAssertTrue(IncidentQuery(filter: .resolved).reachesHistory)
        XCTAssertTrue(IncidentQuery(filter: .critical).reachesHistory)
    }

    // MARK: Projection

    func testSearchFindsAnIncidentOlderThanThePublishedWindow() {
        let log = makeLog(400)
        var state = RadarConsoleState.default
        state.incidentQuery.text = "job-000"

        let published = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: log.published, state: state)
        XCTAssertTrue(published.incidentRows.isEmpty, "the published window does not hold the oldest incident")

        let searched = ConsoleDerivedSnapshot.build(
            snapshot: .empty, incidents: log.published, incidentHistory: log.history, state: state
        )
        XCTAssertEqual(searched.incidentRows.map(\.familyName), ["job-000"])
    }

    func testCriticalFilterAnswersForTheWholeLog() {
        // Only the three oldest episodes were ever critical.
        let log = makeLog(400, critical: [0, 1, 2])
        var state = RadarConsoleState.default
        state.incidentQuery.filter = .critical

        let published = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: log.published, state: state)
        XCTAssertEqual(published.incidentRows.count, 0)
        let filtered = ConsoleDerivedSnapshot.build(
            snapshot: .empty, incidents: log.published, incidentHistory: log.history, state: state
        )
        XCTAssertEqual(filtered.incidentRows.map(\.familyName), ["job-002", "job-001", "job-000"])
    }

    func testHistoryIsNotCutOffAtThePublishedWindow() {
        let log = makeLog(400)
        var state = RadarConsoleState.default
        state.incidentQuery.text = "job"

        let published = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: log.published, state: state)
        XCTAssertEqual(published.incidentRows.count, 80)
        let searched = ConsoleDerivedSnapshot.build(
            snapshot: .empty, incidents: log.published, incidentHistory: log.history, state: state
        )
        XCTAssertEqual(searched.incidentRows.count, 400, "a broad search lists every match, not the newest 80 of them")
    }

    func testTheHistoryKeepsTheSortOrder() {
        let log = makeLog(400)
        var state = RadarConsoleState.default
        state.incidentQuery = IncidentQuery(text: "job", sort: .memory)

        let rows = ConsoleDerivedSnapshot.build(
            snapshot: .empty, incidents: log.published, incidentHistory: log.history, state: state
        ).incidentRows
        XCTAssertEqual(rows.first?.familyName, "job-399", "memory grows with the index in this log")
        XCTAssertEqual(rows.last?.familyName, "job-000")
    }

    func testAnIdleConsoleIgnoresTheHistory() {
        let log = makeLog(400)
        let rows = ConsoleDerivedSnapshot.build(
            snapshot: .empty, incidents: log.published, incidentHistory: nil, state: .default
        ).incidentRows
        XCTAssertEqual(rows.count, 80)
    }

    // MARK: Cache

    func testAnotherHistoryReadNeverReusesACachedProjection() {
        let log = makeLog(400)
        var state = RadarConsoleState.default
        state.incidentQuery.text = "job-000"
        let plain = ConsoleProjectionRequest(source: .empty, incidents: log.published, state: state)
        let first = ConsoleProjectionRequest(source: .empty, incidents: log.published, incidentHistory: log.history, state: state)
        let second = ConsoleProjectionRequest(
            source: .empty, incidents: log.published,
            incidentHistory: IncidentHistory(incidents: log.history.incidents, revision: 2, writeCount: 0, isTruncated: false),
            state: state
        )
        XCTAssertNotEqual(ConsoleDerivedSnapshotKey(plain), ConsoleDerivedSnapshotKey(first))
        XCTAssertNotEqual(ConsoleDerivedSnapshotKey(first), ConsoleDerivedSnapshotKey(second))

        var cache = ConsoleDerivedSnapshotCache()
        XCTAssertEqual(cache.update(plain).incidentRows.count, 0)
        XCTAssertEqual(cache.update(first).incidentRows.count, 1, "the content revision is the same, but the rows searched are not")
        XCTAssertEqual(cache.update(first).incidentRows.count, 1)
        XCTAssertEqual(cache.hitCount, 1, "the same read is projected once")
        XCTAssertEqual(cache.update(plain).incidentRows.count, 0, "leaving the history restores the published rows")
    }

    // MARK: Scope and caption

    func testTheProjectionSaysWhichRowsItSearched() {
        let log = makeLog(400)
        var state = RadarConsoleState.default
        state.incidentQuery.text = "job"

        let published = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: log.published, state: state)
        XCTAssertEqual(published.incidentScope, .published(total: 80))
        let searched = ConsoleDerivedSnapshot.build(
            snapshot: .empty, incidents: log.published, incidentHistory: log.history, state: state
        )
        XCTAssertEqual(searched.incidentScope, .history(total: 400, isTruncated: false))
        XCTAssertEqual(ConsoleDerivedSnapshot.empty.incidentScope, .published(total: 0))
    }

    func testCaptionSaysWhatTheListCovers() {
        let plain = IncidentQuery.default
        let search = IncidentQuery(text: "chrome")

        XCTAssertEqual(IncidentListScope.published(total: 12).caption(shown: 12, query: plain, isLoadingHistory: false), "12 events shown")
        XCTAssertEqual(
            IncidentListScope.published(total: 80).caption(shown: 80, query: plain, isLoadingHistory: false),
            "Latest 80 events; search or filter to look further back"
        )
        XCTAssertEqual(
            IncidentListScope.published(total: 80).caption(shown: 3, query: IncidentQuery(filter: .active), isLoadingHistory: false),
            "3 events shown", "the newest rows hold every active incident, so nothing is left out"
        )
        XCTAssertEqual(
            IncidentListScope.history(total: 340, isTruncated: false).caption(shown: 12, query: search, isLoadingHistory: false),
            "Showing 12 of 340 logged events"
        )
        XCTAssertEqual(
            IncidentListScope.history(total: 2_000, isTruncated: true).caption(shown: 12, query: search, isLoadingHistory: false),
            "Showing 12 of the newest 2000 logged events", "a log longer than one read says so"
        )
        XCTAssertEqual(
            IncidentListScope.published(total: 80).caption(shown: 12, query: search, isLoadingHistory: true),
            "Searching the whole log\u{2026}"
        )
        XCTAssertEqual(
            IncidentListScope.published(total: 80).caption(shown: 2, query: search, isLoadingHistory: false),
            "Showing 2 of the latest 80 events", "when the log could not be read, the caption admits the window"
        )
        XCTAssertEqual(
            IncidentListScope.published(total: 30).caption(shown: 2, query: search, isLoadingHistory: false),
            "Showing 2 of 30 events"
        )
    }

    func testOverviewNoLongerCallsTheWindowATotal() {
        XCTAssertEqual(IncidentListScope.published(total: 12).overviewText, "12 total")
        XCTAssertEqual(IncidentListScope.published(total: 80).overviewText, "latest 80")
    }

    // MARK: Fixtures

    /// What the refresh publishes and what a history read returns, newest first.
    private struct Log {
        let published: [RadarIncident]
        let history: IncidentHistory
    }

    /// `count` closed episodes, `job-000` the oldest. Memory grows with the index.
    private func makeLog(_ count: Int, critical: Set<Int> = []) -> Log {
        let newestFirst = (0..<count).reversed().map { index -> RadarIncident in
            let name = "job-" + String(format: "%03d", index)
            return RadarIncident(
                signature: ProcessSignature(displayName: name, canonicalPath: "/bin/\(name)", commandLine: name),
                familyName: name, level: critical.contains(index) ? .critical : .hot, maxScore: 80,
                memoryBytes: UInt64(index + 1) * 1_000_000, cpuPercent: 0,
                leakVelocityMegabytesPerMinute: 0, reasons: ["memory"],
                startedAt: start.addingTimeInterval(Double(index) * 1_200),
                lastSeenAt: start.addingTimeInterval(Double(index) * 1_200 + 60),
                resolvedAt: start.addingTimeInterval(Double(index) * 1_200 + 60)
            )
        }
        return Log(
            published: Array(newestFirst.prefix(IncidentHistory.publishedWindow)),
            history: IncidentHistory(incidents: newestFirst, revision: 1, writeCount: 0, isTruncated: false)
        )
    }
}
