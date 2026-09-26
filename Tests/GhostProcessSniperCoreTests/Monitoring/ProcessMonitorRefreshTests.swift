import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class ProcessMonitorRefreshTests: XCTestCase {
    private func monitor(_ sampler: GatedSampler) -> ProcessMonitor {
        ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501), settings: .smart, store: nil)
    }

    func testRefreshDuringARunningOneReturnsAfterAFreshSample() async {
        let sampler = GatedSampler(holding: [1])
        let monitor = monitor(sampler)
        let first = Task { await monitor.refresh() }
        let firstHeld = await waitUntil { await sampler.waitingCount == 1 }
        XCTAssertTrue(firstHeld)
        let before = monitor.sampleRevision

        let second = Task { () -> UInt64 in
            await monitor.refresh()
            return monitor.sampleRevision
        }
        let secondQueued = await waitUntil { monitor.coalescedCount == 1 }
        XCTAssertTrue(secondQueued)
        await sampler.release()

        let seenBySecond = await second.value
        await first.value
        let calls = await sampler.calls
        XCTAssertEqual(calls, 2, "the queued call must rerun, not be dropped")
        XCTAssertEqual(seenBySecond, before + 2, "the second caller returns only after the rerun publishes")
        XCTAssertEqual(monitor.rerunCount, 1)
    }

    func testManyOverlappingCallersShareOneRerun() async {
        let sampler = GatedSampler(holding: [1])
        let monitor = monitor(sampler)
        let first = Task { await monitor.refresh() }
        _ = await waitUntil { await sampler.waitingCount == 1 }
        let callers = (0..<5).map { _ in Task { await monitor.refresh() } }
        let allQueued = await waitUntil { monitor.coalescedCount == 5 }
        XCTAssertTrue(allQueued)
        await sampler.release()
        for caller in callers { await caller.value }
        await first.value

        let calls = await sampler.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(monitor.rerunCount, 1)
        XCTAssertEqual(monitor.performanceMetrics.coalescedRefreshCount, 5)
        XCTAssertFalse(monitor.performanceMetrics.refreshInFlight)
    }

    func testLoopTickJoinsARunningRefreshWithoutQueueingOne() async {
        let sampler = GatedSampler(holding: [1])
        let monitor = monitor(sampler)
        let manual = Task { await monitor.refresh() }
        _ = await waitUntil { await sampler.waitingCount == 1 }
        let tick = Task { await monitor.refresh(reason: .loop) }
        _ = await waitUntil { monitor.coalescedCount == 1 }
        await sampler.release()
        await tick.value
        await manual.value

        let calls = await sampler.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(monitor.rerunCount, 0)
    }

    func testRefreshAfterTheRunningOneFinishedStartsAnother() async {
        let sampler = GatedSampler()
        let monitor = monitor(sampler)
        await monitor.refresh()
        await monitor.refresh()
        let calls = await sampler.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(monitor.coalescedCount, 0)
    }
}
