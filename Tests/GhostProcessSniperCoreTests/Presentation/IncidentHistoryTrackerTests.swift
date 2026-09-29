import XCTest
@testable import GhostProcessSniperCore

/// When the console reads the incident log, keeps it, and lets go of it.
final class IncidentHistoryTrackerTests: XCTestCase {
    private func history(revision: UInt64 = 1, writes: Int) -> IncidentHistory {
        IncidentHistory(incidents: [], revision: revision, writeCount: writes, isTruncated: false)
    }

    func testNothingLoadsUntilTheIncidentsPageIsSearched() {
        var tracker = IncidentHistoryTracker()
        XCTAssertEqual(tracker.update(isWanted: false, incidentWrites: 4), .none)
        XCTAssertNil(tracker.history)
        XCTAssertFalse(tracker.isLoading)
    }

    func testTheFirstSearchStartsOneRead() {
        var tracker = IncidentHistoryTracker()
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .load(ticket: 1))
        XCTAssertTrue(tracker.isLoading)
        XCTAssertTrue(tracker.isAwaitingFirstRead)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .none, "one read at a time, however often the console updates")
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 5), .none, "a write during a read waits for that read to land")
    }

    func testALoadedLogIsKeptWhileTheTableIsUnchanged() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        XCTAssertTrue(tracker.received(history(writes: 4), ticket: 1))
        XCTAssertNotNil(tracker.history)
        XCTAssertFalse(tracker.isLoading)

        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .none, "every sample would otherwise re-read the table")
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 3), .none)
    }

    func testAWriteAfterTheReadReadsAgainAndKeepsShowingTheOldRowsMeanwhile() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        _ = tracker.received(history(writes: 4), ticket: 1)

        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 5), .load(ticket: 2))
        XCTAssertNotNil(tracker.history, "the list must not blank while the newer read is in flight")
        XCTAssertTrue(tracker.isLoading)
        XCTAssertFalse(tracker.isAwaitingFirstRead, "rows are on screen, so there is nothing to wait for")
        XCTAssertTrue(tracker.received(history(revision: 2, writes: 5), ticket: 2))
        XCTAssertEqual(tracker.history?.revision, 2)
    }

    func testAReadNewerThanThePublishedCounterIsCurrent() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        // The store wrote once more between the flush that was published and the read.
        _ = tracker.received(history(writes: 5), ticket: 1)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .none)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 5), .none)
    }

    func testTheLogIsDroppedWhenTheSearchEnds() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        _ = tracker.received(history(writes: 4), ticket: 1)

        XCTAssertEqual(tracker.update(isWanted: false, incidentWrites: 4), .none)
        XCTAssertNil(tracker.history, "a console on another page holds none of it")
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .load(ticket: 2), "coming back reads it afresh")
    }

    func testAReadThatLandsAfterTheSearchEndedIsIgnored() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        _ = tracker.update(isWanted: false, incidentWrites: 4)

        XCTAssertFalse(tracker.received(history(writes: 4), ticket: 1))
        XCTAssertNil(tracker.history)
        XCTAssertFalse(tracker.isLoading)
    }

    func testAnOlderReadCannotReplaceANewerOne() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        _ = tracker.update(isWanted: false, incidentWrites: 4)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .load(ticket: 2))

        XCTAssertFalse(tracker.received(history(revision: 1, writes: 4), ticket: 1), "the first search's read is stale")
        XCTAssertTrue(tracker.isLoading, "the current read is still awaited")
        XCTAssertTrue(tracker.received(history(revision: 2, writes: 4), ticket: 2))
    }

    func testAFailedReadWaitsForTheNextSearchInsteadOfRetryingEverySample() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        XCTAssertFalse(tracker.received(nil, ticket: 1))
        XCTAssertFalse(tracker.isLoading)
        XCTAssertNil(tracker.history)

        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .none)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 9), .none)
        _ = tracker.update(isWanted: false, incidentWrites: 9)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 9), .load(ticket: 2))
    }

    func testAFailedRefreshKeepsTheRowsAlreadyLoaded() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        _ = tracker.received(history(writes: 4), ticket: 1)
        _ = tracker.update(isWanted: true, incidentWrites: 5)
        XCTAssertFalse(tracker.received(nil, ticket: 2))
        XCTAssertNotNil(tracker.history)
    }

    func testResetForgetsEverything() {
        var tracker = IncidentHistoryTracker()
        _ = tracker.update(isWanted: true, incidentWrites: 4)
        _ = tracker.received(history(writes: 4), ticket: 1)
        tracker.reset()
        XCTAssertNil(tracker.history)
        XCTAssertFalse(tracker.isLoading)
        XCTAssertEqual(tracker.update(isWanted: true, incidentWrites: 4), .load(ticket: 2))
    }
}
