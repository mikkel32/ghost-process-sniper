import XCTest
@testable import GhostProcessSniperCore

final class RadarPerformanceMetricsTests: XCTestCase {
    func testSmoothnessFieldsReadThroughAfterMutatingACopy() {
        let original = RadarPerformanceMetrics.empty
        var metrics = original
        metrics.smoothness.coalescedRefreshCount = 2
        metrics.smoothness.contentRevision = SnapshotContentRevision(rawValue: 9)
        XCTAssertEqual(metrics.coalescedRefreshCount, 2)
        XCTAssertEqual(metrics.contentRevision, SnapshotContentRevision(rawValue: 9))
        XCTAssertEqual(original.coalescedRefreshCount, 0)
        XCTAssertNotEqual(metrics, original)
    }

    func testRecordingAReportUpdatesItsSummaryFields() {
        let report = RadarSmoothnessReport(hitchCount: 3, worstHitchMilliseconds: 41,
            latestSpikePhase: "store", recentSpikes: ["store 41ms"])
        var state = RadarSmoothnessState()
        state.record(report)
        XCTAssertEqual(state.hitchCount, 3)
        XCTAssertEqual(state.worstHitchMilliseconds, 41)
        XCTAssertEqual(state.latestSpikePhase, "store")
        XCTAssertEqual(state.smoothnessReport, report)
    }
}
