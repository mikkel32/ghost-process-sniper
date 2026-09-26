import Foundation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class ShellSurfaceTests: XCTestCase {
    func testSeededSnapshotIsVisibleImmediately() {
        let store = ConsoleQueryStore(projector: HeldProjector())
        let seeded = snapshot("seed")
        store.seed(seeded)
        XCTAssertEqual(store.snapshot, seeded)
        XCTAssertFalse(store.isUpdating)
    }

    func testInFlightProjectionCannotOverwriteASeed() async throws {
        let projector = HeldProjector()
        let store = ConsoleQueryStore(projector: projector)
        let old = Task { await store.update(request("old")) }
        try await waitUntilHeld(projector)
        store.seed(snapshot("seed"))
        await projector.release()
        let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.snapshot.key.searchText, "seed")
        XCTAssertFalse(store.isUpdating)
    }

    func testProjectionStartedAfterASeedReplacesIt() async {
        let store = ConsoleQueryStore(projector: HeldProjector())
        store.seed(snapshot("seed"))
        let accepted = await store.update(request("newer"))
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.snapshot.key.searchText, "newer")
    }

    func testVisibleConsoleSamplesAtOnceWithTheRealtimePlan() async throws {
        let sampler = RecordingSampler()
        let monitor = ProcessMonitor(sampler: sampler, settings: .smart, store: nil)
        let asleep = try await startAndWaitForHiddenSleep(monitor, sampler)
        defer { monitor.stop() }

        monitor.setConsoleVisible(true)
        let woke = await waitUntil(timeout: 1) { await sampler.plans().count > asleep }
        XCTAssertTrue(woke, "showing the console should sample without waiting out the hidden interval")
        let visible = await sampler.plans().last
        XCTAssertEqual(visible?.uiVisible, true)
        XCTAssertEqual(visible?.performanceMode, .realtime)

        monitor.setConsoleVisible(false)
        await monitor.refresh()
        let hidden = await sampler.plans().last
        XCTAssertNotEqual(hidden?.performanceMode, .realtime, "a hidden, quiet radar should not keep the realtime plan")
    }

    func testRepeatedConsoleVisibilityDoesNotStartExtraSamples() async throws {
        let sampler = RecordingSampler()
        let monitor = ProcessMonitor(sampler: sampler, settings: .smart, store: nil)
        let asleep = try await startAndWaitForHiddenSleep(monitor, sampler)
        defer { monitor.stop() }

        monitor.setConsoleVisible(true)
        monitor.setConsoleVisible(true)
        let woke = await waitUntil(timeout: 1) { await sampler.plans().count > asleep }
        XCTAssertTrue(woke)
        // The visible cadence is a second, so nothing else is due yet.
        try await Task.sleep(for: .milliseconds(200))
        let count = await sampler.plans().count
        XCTAssertEqual(count, asleep + 1)
    }

    /// Starts the loop and returns the sample count once it sleeps hidden,
    /// after the first tick and the warm-start tick.
    private func startAndWaitForHiddenSleep(_ monitor: ProcessMonitor, _ sampler: RecordingSampler) async throws -> Int {
        monitor.start()
        guard await waitUntil(timeout: 5, { await sampler.plans().count >= 2 }) else {
            monitor.stop()
            throw NSError(domain: "ShellSurfaceTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No sample was taken"])
        }
        try await Task.sleep(for: .milliseconds(100))
        return await sampler.plans().count
    }

    private func request(_ query: String) -> ConsoleProjectionRequest {
        var state = RadarConsoleState.default
        state.searchText = query
        return ConsoleProjectionRequest(source: .empty, incidents: [], state: state)
    }

    private func snapshot(_ query: String) -> ConsoleDerivedSnapshot {
        var state = RadarConsoleState.default
        state.searchText = query
        return ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: [], state: state)
    }

    private func waitUntilHeld(_ projector: HeldProjector) async throws {
        for _ in 0..<2000 {
            if await projector.isHolding { return }
            await Task.yield()
        }
        throw NSError(domain: "ShellSurfaceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Projection did not start"])
    }
}

private actor HeldProjector: ConsoleProjecting {
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { continuation != nil }

    func project(_ request: ConsoleProjectionRequest) async throws -> ConsoleDerivedSnapshot {
        if request.state.searchText == "old" {
            await withCheckedContinuation { continuation = $0 }
        }
        return ConsoleDerivedSnapshot.build(snapshot: request.source, incidents: request.incidents, state: request.state)
    }

    func panel(familyKey: String, request: ConsoleProjectionRequest) async throws -> FamilyDetailPanelModel? {
        request.source.detailPanel(for: familyKey)
    }

    func release() { continuation?.resume(); continuation = nil }
}

private actor RecordingSampler: ProcessSampling {
    private var captured: [SamplingPlan] = []

    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        captured.append(plan)
        return ProcessSampleBatch(processes: [], sampledAt: plan.sampledAt, stats: .empty)
    }

    func plans() -> [SamplingPlan] { captured }
}
