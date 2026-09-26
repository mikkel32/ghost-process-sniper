import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Paired comparison in one process, with identical immutable synthetic input.
final class DuplicateIndexPerformanceTests: XCTestCase {
    func testPairedDuplicateResolutionBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["RADAR_INDEX_BENCHMARK_REPORT"] else {
            throw XCTSkip("Set RADAR_INDEX_BENCHMARK_REPORT for the opt-in release benchmark")
        }
        var report: [[String: Any]] = []
        for count in [250, 1_000, 4_000] {
            let fixture = RefreshPerformanceFixture.population(count)
            var legacyTimes: [Double] = []
            var indexedTimes: [Double] = []
            for iteration in 0..<9 {
                let old: ([DuplicateProcessCluster], Double)
                let new: ([DuplicateProcessCluster], Double)
                // Alternate order to reduce first-run and thermal bias.
                if iteration.isMultiple(of: 2) {
                    old = timed { RefreshPerformanceFixture.legacyResolve(fixture.clusters, families: fixture.families) }
                    new = timed { DuplicateFamilyResolver.resolve(fixture.clusters, families: fixture.families) }
                } else {
                    new = timed { DuplicateFamilyResolver.resolve(fixture.clusters, families: fixture.families) }
                    old = timed { RefreshPerformanceFixture.legacyResolve(fixture.clusters, families: fixture.families) }
                }
                XCTAssertEqual(new.0, old.0)
                if iteration >= 2 {
                    legacyTimes.append(old.1)
                    indexedTimes.append(new.1)
                }
            }
            let oldMedian = legacyTimes.sorted()[legacyTimes.count / 2]
            let newMedian = indexedTimes.sorted()[indexedTimes.count / 2]
            report.append([
                "families": count, "clusters": fixture.clusters.count,
                "legacy_ms": legacyTimes, "indexed_ms": indexedTimes,
                "legacy_median_ms": oldMedian, "indexed_median_ms": newMedian,
                "speedup": oldMedian / max(newMedian, 0.000_001),
                "identical_results": true
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        print(String(decoding: data, as: UTF8.self))
    }

    private func timed(_ operation: () -> [DuplicateProcessCluster]) -> ([DuplicateProcessCluster], Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = operation()
        return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
