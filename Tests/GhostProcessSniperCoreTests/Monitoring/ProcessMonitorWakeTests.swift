import XCTest
@testable import GhostProcessSniperCore

private actor CountingThermalSampler: ThermalSampling {
    private(set) var calls = 0

    func sample(now: Date) -> ThermalSnapshot {
        calls += 1
        return .unknown
    }
}

@MainActor
final class ProcessMonitorWakeTests: XCTestCase {
    private func monitor(_ sampler: GatedSampler, thermals: CountingThermalSampler = CountingThermalSampler()) -> ProcessMonitor {
        ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501), settings: .smart,
                       store: nil, thermalSampler: thermals)
    }

    func testShowingASurfaceWakesTheHiddenSleepAtOnce() async {
        let sampler = GatedSampler()
        let monitor = monitor(sampler)
        monitor.start()
        defer { monitor.stop() }

        // The first tick, then the warm-start tick a second later.
        let warmedUp = await waitUntil(timeout: 5) { await sampler.calls >= 2 }
        XCTAssertTrue(warmedUp)
        XCTAssertGreaterThanOrEqual(monitor.performanceMetrics.nextRefreshInterval, 3.5, "hidden and quiet")
        try? await Task.sleep(for: .milliseconds(100))
        let asleep = await sampler.calls

        let shown = Date()
        monitor.setSurface(.popover, visible: true)
        let woke = await waitUntil(timeout: 1) { await sampler.calls > asleep }
        XCTAssertTrue(woke)
        XCTAssertLessThan(Date().timeIntervalSince(shown), 0.5, "must not wait out the hidden interval")
        let plan = await sampler.plans.last
        XCTAssertEqual(plan?.uiVisible, true)
        XCTAssertEqual(plan?.performanceMode, .realtime)
    }

    func testHiddenSleepDoesNotKeepAReleasedMonitorAlive() async {
        let sampler = GatedSampler()
        var monitor: ProcessMonitor? = monitor(sampler)
        weak let released = monitor
        monitor?.start()
        let warmedUp = await waitUntil(timeout: 5) { await sampler.calls >= 2 }
        XCTAssertTrue(warmedUp)
        try? await Task.sleep(for: .milliseconds(100))

        monitor = nil
        let gone = await waitUntil(timeout: 1) { released == nil }
        XCTAssertTrue(gone, "the loop must not hold the monitor through a 3.5 s sleep")
    }

    func testHiddenThermalsAreReadOnlyAtALowRate() async {
        let thermals = CountingThermalSampler()
        let monitor = monitor(GatedSampler(), thermals: thermals)
        await monitor.refresh()
        await monitor.refresh()
        var calls = await thermals.calls
        XCTAssertEqual(calls, 1, "hidden, the second refresh comes too soon for another reading")

        monitor.setSurface(.console, visible: true)
        await monitor.refresh()
        calls = await thermals.calls
        XCTAssertEqual(calls, 2, "on screen every refresh reads")

        monitor.setConsoleVisible(false)
        await monitor.refresh()
        calls = await thermals.calls
        XCTAssertEqual(calls, 2)
    }

    func testHiddenReadingsStayCloseEnoughForAContinuousTrend() {
        let monitor = monitor(GatedSampler())
        let read = Date(timeIntervalSince1970: 1_000)
        monitor.lastThermalReadAt = read
        XCTAssertFalse(monitor.readsThermals(at: read.addingTimeInterval(3.5)))
        XCTAssertTrue(monitor.readsThermals(at: read.addingTimeInterval(4)))
        // The longest hidden sleep, with its timer slack, still lands under the window's gap.
        XCTAssertLessThan(ProcessMonitor.hiddenThermalInterval + 8 * 1.15, ThermalObservationWindow.maximumGap)
    }

    func testHeartbeatRunsOnlyWhileRunningAndOnScreen() {
        let monitor = monitor(GatedSampler())
        monitor.setSurface(.popover, visible: true)
        XCTAssertFalse(monitor.hitchMonitor.isRunning, "not before start")
        monitor.setPopoverVisible(false)
        monitor.start()
        XCTAssertFalse(monitor.hitchMonitor.isRunning, "hidden")
        monitor.setSurface(.console, visible: true)
        XCTAssertTrue(monitor.hitchMonitor.isRunning)
        monitor.setSurface(.popover, visible: true)
        monitor.setSurface(.console, visible: false)
        XCTAssertTrue(monitor.hitchMonitor.isRunning, "the popover is still open")
        monitor.setPopoverVisible(false)
        XCTAssertFalse(monitor.hitchMonitor.isRunning)
        monitor.setPopoverVisible(true)
        monitor.stop()
        XCTAssertFalse(monitor.hitchMonitor.isRunning)
    }

    func testSurfaceDemandReachesTheRequest() async {
        let sampler = GatedSampler()
        let monitor = monitor(sampler)
        monitor.setSurface(.console, visible: true)
        await monitor.refresh()
        monitor.setSurface(.console, visible: false)
        await monitor.refresh()
        let plans = await sampler.plans
        XCTAssertEqual(plans.map(\.uiVisible), [true, false])
        XCTAssertEqual(plans.map(\.performanceMode), [.realtime, .balanced])
    }
}
