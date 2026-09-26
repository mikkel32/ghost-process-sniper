import Observation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class MonitorPublishDietTests: XCTestCase {
    private func monitor(_ sampler: GatedSampler) -> ProcessMonitor {
        ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501), settings: .smart, store: nil)
    }

    private let processes = (0..<6).map { RefreshPerformanceFixture.process($0) }

    func testTicksThatOnlyAdvanceTimeLeaveDiagnosticsAndHealthAlone() async {
        let monitor = monitor(GatedSampler(processes: processes))
        // Let the cold first tick decay out of the average refresh cost.
        for _ in 0..<10 {
            await monitor.refresh()
        }
        let firstSample = monitor.lastSampleDate
        XCTAssertNotNil(firstSample)

        let invalidated = InvalidationLog()
        withObservationTracking {
            _ = monitor.engineDiagnostics
        } onChange: {
            invalidated.append("engineDiagnostics")
        }
        withObservationTracking {
            _ = monitor.health
        } onChange: {
            invalidated.append("health")
        }
        let before = monitor.engineDiagnostics
        await monitor.refresh()

        XCTAssertEqual(invalidated.entries, [], "\(before) -> \(monitor.engineDiagnostics)")
        XCTAssertNotEqual(monitor.lastSampleDate, firstSample, "the sample time is still published, on its own")
        XCTAssertEqual(monitor.health.processCount, processes.count)
        XCTAssertNil(monitor.health.lastSampleDate)
    }

    func testMainActorHitchIsCountedOnce() async {
        let monitor = monitor(GatedSampler(processes: processes))
        monitor.hitchMonitor.recordHeartbeat(milliseconds: 500)
        await monitor.refresh()

        let report = monitor.performanceMetrics.smoothnessReport
        XCTAssertEqual(report.recentSpikes.filter { $0.hasPrefix("main actor heartbeat") }.count, 1)
        XCTAssertEqual(report.hitchCount, report.recentSpikes.count, "worker spikes plus exactly one heartbeat spike")
        XCTAssertEqual(monitor.performanceMetrics.hitchCount, report.hitchCount)
        XCTAssertTrue(monitor.engineDiagnostics.smoothnessText.contains("\(report.hitchCount) hitches"),
                      "the published diagnostics carry the merged report")
    }

    func testDiagnosticsReportIsBuiltOnDemand() async {
        let monitor = monitor(GatedSampler(processes: processes))
        await monitor.refresh()
        let report = monitor.diagnosticsReport()
        XCTAssertTrue(report.hasPrefix("Ghost Process Sniper Diagnostics\nGenerated: "))
        XCTAssertTrue(report.contains("Processes: \(processes.count)"))
        XCTAssertTrue(report.contains("in flight: false"))
    }
}

private final class InvalidationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var entries: [String] { lock.withLock { names } }
    func append(_ name: String) { lock.withLock { names.append(name) } }
}
