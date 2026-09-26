import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Stands in for a notifier whose first pass never returns on its own, as
/// when it waits on a system permission prompt nobody answers.
private actor StallingNotifier: RadarNotifying {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private(set) var processedGenerations: [Date] = []

    func process(model: RadarModel) async {
        calls += 1
        if calls == 1 { await withCheckedContinuation { waiting.append($0) } }
        processedGenerations.append(model.generatedAt)
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor
final class NotifierStallTests: XCTestCase {
    func testAStalledNotifierBlocksNeitherRefreshesStopsNorShutdown() async throws {
        let notifier = StallingNotifier()
        let sampler = GatedSampler()
        let monitor = ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501),
                                     settings: .smart, store: nil, notifier: notifier)
        let first = Task { await monitor.refresh(reason: .loop) }
        let stalled = await waitUntil { await notifier.calls == 1 }
        XCTAssertTrue(stalled)

        let second = Task { await monitor.refresh() }
        let sampledAgain = await waitUntil(timeout: 1) { await sampler.calls == 2 }
        XCTAssertTrue(sampledAgain, "Scan now must sample while a notification pass is pending")

        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 800, name: "cruncher")
        table.add(worker)
        let family = Self.family(worker.asProcessMetrics())
        _ = await monitor.confirmKill(family: family, killer: table.killer(), forceKillDelay: 1)
        var planned = false
        let plan = Task { _ = await monitor.killPlan(for: family); planned = true }
        let planReturned = await waitUntil(timeout: 1) { planned }
        XCTAssertTrue(planReturned, "the next stop preview must not wait on the notifier")

        var shutDown = false
        let quit = Task { await monitor.shutdown(); shutDown = true }
        let quitReturned = await waitUntil(timeout: 1) { shutDown }
        XCTAssertTrue(quitReturned, "quitting must not wait on the notifier")

        await notifier.release()
        await first.value
        await second.value
        await plan.value
        await quit.value
    }

    func testAStalledNotifierLaterSeesOnlyTheLatestModel() async throws {
        let notifier = StallingNotifier()
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501),
                                     settings: .smart, store: nil, notifier: notifier)
        let start = Date(timeIntervalSince1970: 2_000_000)
        await monitor.refresh(now: start)
        _ = await waitUntil { await notifier.calls == 1 }
        for tick in 1...3 {
            await monitor.refresh(now: start.addingTimeInterval(Double(tick)))
        }
        let latest = monitor.model.generatedAt
        await notifier.release()

        let drained = await waitUntil { await notifier.calls == 2 }
        XCTAssertTrue(drained)
        _ = await waitUntil(timeout: 0.2) { await notifier.calls > 2 }
        let generations = await notifier.processedGenerations
        XCTAssertEqual(generations.count, 2, "passes queued behind a stalled one collapse into the latest")
        XCTAssertEqual(generations.last, latest)
    }

    private static func family(_ root: ProcessMetrics) -> ProcessFamily {
        ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                      totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: root.cpuPercent,
                      devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                      score: GhostScore(value: 0, level: .quiet, reasons: []),
                      ownedIdentities: [root.identity], protectedPIDs: [], lastScoredAt: root.sampledAt)
    }
}
