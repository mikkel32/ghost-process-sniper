import XCTest
@testable import GhostProcessSniperCore

final class BSDPassTests: XCTestCase {
    func testDeadlineDuringTheIdentityPassStillSamplesEveryProcess() async throws {
        let source = FakeProbeSource.table(count: 600)
        source.jumpClock(afterBSDReads: 10, by: 1)
        let sampler = NativeProcessSampler(source: source)
        let batch = try await sampler.sample(plan: .fixture(at: 0))
        XCTAssertEqual(batch.processes.count, 600)
        XCTAssertEqual(batch.stats.usageReadCount, 600, "CPU and memory are not deadline-bound")
        XCTAssertEqual(batch.stats.skippedPIDCount, 0)
        XCTAssertTrue(batch.stats.didHitDeadline)
    }

    func testDeadlineTickDoesNotPruneCaches() async throws {
        let source = FakeProbeSource.table(count: 50)
        let sampler = NativeProcessSampler(source: source)
        let flicker: Int32 = 1_010
        _ = try await sampler.sample(plan: .fixture(at: 0))

        // Gone for one slow tick past the prune interval, then back.
        source.update(pid: flicker) { $0.gone = true }
        source.advance(seconds: 20)
        source.jumpClock(afterBSDReads: source.recordedCalls.bsd + 1, by: 1)
        let slow = try await sampler.sample(plan: .fixture(at: 20))
        XCTAssertTrue(slow.stats.didHitDeadline)

        source.update(pid: flicker) {
            $0.gone = false
            $0.cpuSeconds = 1
        }
        source.advance(seconds: 1)
        source.resetCalls()
        let back = try await sampler.sample(plan: .fixture(at: 21))
        let process = try XCTUnwrap(back.processes.first { $0.pid == flicker })
        XCTAssertEqual(process.cpuMeasurementStatus, .fresh, "the CPU baseline survived the deadline tick")
        XCTAssertEqual(source.recordedCalls.path, 0, "telemetry survived the deadline tick")
    }

    func testSessionAndTerminalReachTheMetricsAndGetsidRunsOncePerIdentity() async throws {
        let source = FakeProbeSource([
            .init(pid: 1_000, name: "zsh", sessionID: 900, terminal: 0x1000002, terminalForegroundGroup: 1_000),
            .init(pid: 1_001, name: "node", sessionID: 1_001)
        ])
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        source.advance(seconds: 1)
        let batch = try await sampler.sample(plan: .fixture(at: 1))

        let shell = try XCTUnwrap(batch.processes.first { $0.pid == 1_000 })
        XCTAssertEqual(shell.sessionID, 900)
        XCTAssertEqual(shell.controllingTerminal, 0x1000002)
        XCTAssertEqual(shell.terminalForegroundGroupID, 1_000)
        XCTAssertEqual(shell.runState, .running)
        let server = try XCTUnwrap(batch.processes.first { $0.pid == 1_001 })
        XCTAssertEqual(server.sessionID, 1_001)
        XCTAssertNil(server.controllingTerminal)
        XCTAssertEqual(source.recordedCalls.sessionID, 2, "the session never changes, so the second tick reuses it")
    }

    func testCompleteTickPrunesExitedIdentities() async throws {
        let source = FakeProbeSource.table(count: 5)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        source.update(pid: 1_001) { $0.gone = true }
        source.advance(seconds: 11)
        _ = try await sampler.sample(plan: .fixture(at: 11))
        source.update(pid: 1_001) { $0.gone = false }
        source.resetCalls()
        _ = try await sampler.sample(plan: .fixture(at: 12))
        XCTAssertEqual(source.recordedCalls.path, 1)
    }

    func testOtherUsersProcessesAreCountedNotSampled() async throws {
        let source = FakeProbeSource.table(count: 10)
        for pid: Int32 in [1_001, 1_002, 1_003] {
            source.update(pid: pid) { $0.bsdDenied = true }
        }
        let sampler = NativeProcessSampler(source: source)
        let batch = try await sampler.sample(plan: .fixture(at: 0))
        XCTAssertEqual(batch.processes.count, 7)
        XCTAssertEqual(batch.stats.bsdDeniedCount, 3)
        XCTAssertEqual(batch.scannerHealth.costLedger.bsdDeniedCount, 3)
        XCTAssertEqual(source.recordedCalls.usage, 7)
    }
}
