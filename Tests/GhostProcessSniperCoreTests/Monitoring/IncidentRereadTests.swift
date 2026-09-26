import XCTest
@testable import GhostProcessSniperCore

final class IncidentRereadTests: XCTestCase {
    private let t0 = RefreshPerformanceFixture.now

    private func reread(lastReadAt: Date?, readAtFlush: Date?, storeFlush: Date?,
                        mode: RadarPerformanceMode = .realtime, at seconds: TimeInterval) -> Bool {
        RadarRefreshWorker.shouldRereadIncidents(
            lastReadAt: lastReadAt, readAtFlush: readAtFlush, storeFlush: storeFlush,
            performanceMode: mode, now: t0.addingTimeInterval(seconds))
    }

    func testFirstTickReads() {
        XCTAssertTrue(reread(lastReadAt: nil, readAtFlush: nil, storeFlush: nil, at: 0))
    }

    func testHotTicksBetweenFlushesDoNotRequery() {
        let flush = t0
        // Six 0.75 s hot ticks after reading at the last flush: all identical.
        for tick in 1...6 {
            XCTAssertFalse(reread(lastReadAt: t0, readAtFlush: flush, storeFlush: flush, at: Double(tick) * 0.75),
                           "tick \(tick)")
        }
    }

    func testTheTickOfANewFlushReadsItsIncidents() {
        XCTAssertTrue(reread(lastReadAt: t0, readAtFlush: t0, storeFlush: t0.addingTimeInterval(2), at: 2))
        XCTAssertTrue(reread(lastReadAt: t0, readAtFlush: nil, storeFlush: t0, at: 1))
    }

    func testSafetyNetStillRereadsOnTheQuietInterval() {
        XCTAssertFalse(reread(lastReadAt: t0, readAtFlush: t0, storeFlush: t0, mode: .balanced, at: 14))
        XCTAssertTrue(reread(lastReadAt: t0, readAtFlush: t0, storeFlush: t0, mode: .balanced, at: 15))
        XCTAssertTrue(reread(lastReadAt: t0, readAtFlush: t0, storeFlush: t0, mode: .realtime, at: 5))
        XCTAssertFalse(reread(lastReadAt: t0, readAtFlush: t0, storeFlush: t0, mode: .batterySaver, at: 29))
    }
}
