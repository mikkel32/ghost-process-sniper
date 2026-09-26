import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The sampler's per-tick shortcuts: the scan deadline, reused telemetry,
/// negative forensics and CPU tracker pruning.
final class ScannerCacheTests: XCTestCase {
    private let process = RefreshPerformanceFixture.process(0, pid: 215, start: 1)

    func testDeadlineAllowsWorkInsideTheBudgetOnly() {
        let budget = ScannerBudget.budget(for: .batterySaver)
        let startedAt: UInt64 = 100_000_000_000
        let deadline = TickDeadline(startedAt: startedAt, budgetMilliseconds: budget.targetMilliseconds)
        XCTAssertFalse(deadline.isExpired(at: startedAt + 1_000_000))
        XCTAssertTrue(deadline.isExpired(at: startedAt + 1_000_000_000))
        XCTAssertFalse(deadline.isExpired(at: startedAt - 1), "a clock read before the start never expires the tick")
        XCTAssertLessThanOrEqual(ScannerBudget.budget(for: .balanced).maxTelemetryRefreshes, 16, "command/path refresh bursts are capped")
    }

    func testQuietTelemetryIsReusedUntilMaxAgePlusGrace() {
        var cache = ProcessScanCache()
        cache.update(ProcessRecord(identity: process.identity, process: process, telemetryRefreshedAt: Date(timeIntervalSince1970: 1_000)))
        func refreshes(at seconds: TimeInterval, priority: Bool) -> Bool {
            cache.shouldRefreshTelemetry(identity: process.identity, now: Date(timeIntervalSince1970: seconds),
                                         maxAge: 10, grace: 10, isPriority: priority)
        }
        XCTAssertFalse(refreshes(at: 1_005, priority: false), "an unchanged quiet process reuses its telemetry")
        XCTAssertTrue(refreshes(at: 1_030, priority: false), "quiet telemetry refreshes after max age plus grace")
        XCTAssertTrue(refreshes(at: 1_012, priority: true), "priority telemetry uses the shorter window")
    }

    func testPartialForensicsAreNegativeCached() {
        var forensics = ForensicsCache()
        let partial = ProcessForensics.unavailable(reason: "protected")
        forensics.update(partial, for: process.identity, at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(forensics.negativeEntry(for: process.identity, now: Date(timeIntervalSince1970: 2_090), maxAge: 120)?.forensics, partial)
    }

    func testPruningDropsOldCPUState() {
        var cpu = CPUUsageTracker<ProcessIdentity>()
        _ = cpu.percent(key: process.identity, totalProcessorSeconds: 1, wallClock: Date(timeIntervalSince1970: 1))
        cpu.prune(keeping: [])
        XCTAssertNil(cpu.percent(key: process.identity, totalProcessorSeconds: 2, wallClock: Date(timeIntervalSince1970: 2)))
    }
}
