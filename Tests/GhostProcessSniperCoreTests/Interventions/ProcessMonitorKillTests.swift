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

    func testForceFollowUpIsRecordedButNotLearnedFrom() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gps-kill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try RadarStore(url: url)
        let family = Self.family(KillProcessLite.fake(pid: 810, name: "cruncher").asProcessMetrics())
        // A real SIGKILL went out, so only the follow-up flag keeps it from being learned.
        var report = KillReport(displayName: "cruncher", rootPID: 810, forcedPIDs: [810],
                                attempts: [KillAttempt(pid: 810, signal: SIGKILL, stage: "forced", succeeded: true)])
        report.isForceFollowUp = true

        try await store.recordKillOperation(report: report, family: family)

        let recorded = try await store.recentKillOperations()
        let history = try await store.killStrategyHistory(signatureID: family.signature.id)
        XCTAssertEqual(recorded.count, 1, "the stop stays in the audit trail")
        XCTAssertEqual(history.operationCount, 0, "forcing a held stop's survivors teaches nothing about the strategy")
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
