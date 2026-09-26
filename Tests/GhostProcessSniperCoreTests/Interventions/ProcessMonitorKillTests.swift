import Foundation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class ProcessMonitorKillTests: XCTestCase {
    func testStopResultDoesNotWaitForRecordingAndRefresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gps-kill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = GatedSampler()
        let monitor = ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501), store: try RadarStore(url: url))
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 800, name: "cruncher")
        table.add(worker)
        let family = Self.family(worker.asProcessMetrics())

        let report = await monitor.confirmKill(family: family, killer: table.killer(), forceKillDelay: 1)
        let refreshedBeforeReturn = await sampler.wasOpened

        XCTAssertTrue(report.succeeded, report.summary)
        XCTAssertFalse(refreshedBeforeReturn, "the result must not wait for the radar refresh")
        await sampler.open()
        let plan = await monitor.killPlan(for: family)
        XCTAssertEqual(plan.killHistory?.operationCount, 1, "the next plan sees the stop that was just recorded")
    }

    private static func family(_ root: ProcessMetrics) -> ProcessFamily {
        ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                      totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: root.cpuPercent,
                      devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                      score: GhostScore(value: 0, level: .quiet, reasons: []),
                      ownedIdentities: [root.identity], protectedPIDs: [], lastScoredAt: root.sampledAt)
    }
}

/// A sampler whose first sample waits until the test opens it, or three
/// seconds pass, so a test can tell whether a caller waited on a refresh.
private actor GatedSampler: ProcessSampling {
    private(set) var wasOpened = false

    func open() {
        wasOpened = true
    }

    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        let deadline = Date().addingTimeInterval(3)
        while !wasOpened, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        wasOpened = true
        return ProcessSampleBatch(processes: [], sampledAt: plan.sampledAt, stats: .empty)
    }
}
