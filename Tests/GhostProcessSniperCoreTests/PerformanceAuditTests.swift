import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Opt-in release benchmark. No live process is sampled or signalled.
@MainActor
final class PerformanceAuditTests: XCTestCase {
    func testRefreshPipelineBenchmark() async throws {
        guard let reportPath = ProcessInfo.processInfo.environment["RADAR_BENCHMARK_REPORT"] else {
            throw XCTSkip("Set RADAR_BENCHMARK_REPORT to capture release timings")
        }
        var report: [[String: Any]] = []
        for count in [250, 1000] {
            var timings: [Double] = []
            var detailCounts: [Int] = []
            for iteration in 0..<9 {
                let now = Date(timeIntervalSince1970: 2_000_000_000)
                let processes: [ProcessMetrics] = (0..<count).map { Self.process(index: $0, at: now) }
                var settings = ThresholdSettings.aggressive
                settings.radarMode = .all
                settings.groupFamilies = false
                let worker = RadarRefreshWorker(store: nil, builder: ProcessFamilyBuilder(currentUserID: 501))
                let request = RefreshRequest(settings: settings, currentFamilies: [], currentIncidents: [],
                                             currentStoreHealth: .empty, previousRefresh: .empty,
                                             popoverVisible: true,
                                             focusedSignatureIDs: [ProcessSignature.from(root: processes[0]).id],
                                             now: now, startedAt: Date())
                let started = DispatchTime.now().uptimeNanoseconds
                let result = await worker.ingest(batch: ProcessSampleBatch(processes: processes, sampledAt: now, stats: .empty), request: request)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                XCTAssertEqual(result.families.count, count)
                XCTAssertEqual(result.payload.state.consoleSnapshot.families.count, count)
                XCTAssertNotNil(result.payload.state.detailViewModels[ProcessSignature.from(root: processes[0]).id])
                if iteration >= 2 {
                    timings.append(elapsed)
                    detailCounts.append(result.payload.state.consoleSnapshot.detailPanels.count)
                }
            }
            report.append(["families": count, "milliseconds": timings,
                           "median_ms": timings.sorted()[timings.count / 2],
                           "materialized_detail_entries": detailCounts])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func process(index: Int, at now: Date) -> ProcessMetrics {
        let memory = UInt64(32 + index % 120) * UInt64(1_048_576)
        let identity = ProcessIdentity(pid: Int32(40_000 + index), startTimeSeconds: 1_999_990_000, startTimeMicroseconds: 0)
        return ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "benchmark",
                              name: "worker-\(index)", executablePath: "/benchmark/worker-\(index)",
                              commandLine: "worker-\(index) --job benchmark", residentMemoryBytes: memory,
                              physicalFootprintBytes: memory, virtualMemoryBytes: 536_870_912,
                              cpuPercent: Double(index % 10), totalProcessorSeconds: 10, threadCount: 2,
                              isSystemProcess: false, sampledAt: now)
    }
}
