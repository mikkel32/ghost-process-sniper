import Foundation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class ProcessMonitorKillTests: XCTestCase {
    func testStopResultDoesNotWaitForRecordingAndRefresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gps-kill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = GateOpeningSampler()
        let monitor = ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501), store: RadarStore(url: url))
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

    func testBatchStopsAreRecordedBeforeTheNextPlan() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gps-kill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = GateOpeningSampler()
        let monitor = ProcessMonitor(sampler: sampler, builder: ProcessFamilyBuilder(currentUserID: 501), store: RadarStore(url: url))
        let table = FakeProcessTable()
        let copies = [KillProcessLite.fake(pid: 820, name: "alpha"), KillProcessLite.fake(pid: 821, name: "beta")]
        var stops: [(family: ProcessFamily, report: KillReport)] = []
        for copy in copies {
            table.add(copy)
            let family = Self.family(copy.asProcessMetrics())
            let plan = await monitor.killPlan(for: family)
            stops.append((family, await table.killer().kill(plan: plan, forceKillDelay: 1)))
        }

        monitor.recordKills(stops)
        await sampler.open()
        let plan = await monitor.killPlan(for: stops[0].family)
        XCTAssertEqual(plan.killHistory?.operationCount, 1, "a plan made after a batch sees the batch's stops")
        let audit = try await RadarStore(url: url).recentKillOperations()
        XCTAssertEqual(audit.count, 2)
    }

    func testForceFollowUpIsRecordedButNotLearnedFrom() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gps-kill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RadarStore(url: url)
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
private actor GateOpeningSampler: ProcessSampling {
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
