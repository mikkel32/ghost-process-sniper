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
                                             currentStoreHealth: .empty, uiVisible: true,
                                             focusedSignatureIDs: [ProcessSignature.from(root: processes[0]).id],
                                             now: now, startedAt: Date())
                let started = DispatchTime.now().uptimeNanoseconds
                let result = await worker.ingest(batch: ProcessSampleBatch(processes: processes, sampledAt: now, stats: .empty), request: request)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                XCTAssertEqual(result.families.count, count)
                XCTAssertEqual(result.payload.state.consoleSnapshot.families.count, count)
                let focused = try XCTUnwrap(result.families.first { $0.root.pid == processes[0].pid })
                XCTAssertNotNil(result.payload.state.consoleSnapshot.detailPanels[focused.familyKey])
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

    /// The 10k and 30k timings that used to be wall-clock budgets in the debug checks.
    /// Written next to the pipeline report as `<name>-scale.json`.
    func testLargeSampleScaleBenchmark() async throws {
        guard let reportPath = ProcessInfo.processInfo.environment["RADAR_BENCHMARK_REPORT"] else {
            throw XCTSkip("Set RADAR_BENCHMARK_REPORT to capture release timings")
        }
        var report: [[String: Any]] = []
        for count in [2_000, 10_000, 30_000] {
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: 501))
            var settings = ThresholdSettings.aggressive
            settings.radarMode = .all
            let context = RadarContext(baselines: [:], recentIncidentCounts: [:],
                                       rules: RadarRule.builtIns(settings: settings))
            let processes = (0..<count).map { Self.process(index: $0, at: now) }
            var started = DispatchTime.now().uptimeNanoseconds
            let output = pipeline.run(processes: processes, settings: settings, context: context, now: now)
            let pipelineMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            XCTAssertFalse(output.families.isEmpty)

            let table = FakeProcessTable()
            let root = KillProcessLite.fake(pid: 10_000, name: "generic")
            table.add(root)
            table.add(.fake(pid: 10_001, parent: root.pid, name: "generic"))
            for offset in 2..<count {
                table.add(.fake(pid: Int32(10_000 + offset), userID: offset.isMultiple(of: 7) ? 501 : 502, memory: 0))
            }
            let killer = ProcessKiller(snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper)
            started = DispatchTime.now().uptimeNanoseconds
            let preview = await killer.preview(
                plan: KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity], protectedPIDs: [],
                               displayName: "generic"),
                forceKillDelay: 0)
            let previewMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            XCTAssertEqual(Set(preview.targetPIDs), [10_000, 10_001])
            XCTAssertEqual(preview.targetConversionCount, 0)
            report.append(["processes": count, "pipeline_ms": pipelineMilliseconds, "kill_preview_ms": previewMilliseconds])
        }
        let url = URL(fileURLWithPath: reportPath)
        let scaleURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-scale.json")
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: scaleURL)
        print(String(decoding: data, as: UTF8.self))
    }

    /// A realistic 600-process developer Mac for 20 ticks through the whole
    /// pipeline. The budget holds in optimized builds; debug builds only
    /// exercise the path.
    func testPipelineTickCostOnADeveloperMac() {
        var settings = ThresholdSettings.smart
        settings.radarMode = .all
        var pipeline = RadarPipeline(builder: ProcessFamilyBuilder(currentUserID: DevWorkstationFixture.user))
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: RadarRule.builtIns(settings: settings))
        let ticks = (0..<20).map { DevWorkstationFixture.processes(count: 600, tick: $0) }
        var timings: [Double] = []
        for (tick, processes) in ticks.enumerated() {
            let started = DispatchTime.now().uptimeNanoseconds
            let output = pipeline.run(processes: processes, settings: settings, context: context, now: DevWorkstationFixture.date(tick: tick))
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            XCTAssertFalse(output.families.isEmpty)
        }
        // The first ticks fill the caches; steady state is what the user feels.
        let steady = timings.dropFirst(2).sorted()
        let median = steady[steady.count / 2]
        print("pipeline tick median \(median) ms over \(steady.count) ticks")
        #if !DEBUG
        XCTAssertLessThanOrEqual(median, 25, "600-process tick took \(median) ms")
        #endif
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
