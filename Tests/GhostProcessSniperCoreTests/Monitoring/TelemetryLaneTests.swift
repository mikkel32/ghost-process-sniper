import XCTest
@testable import GhostProcessSniperCore

final class TelemetryLaneTests: XCTestCase {
    func testColdStartFillsPathsInOneTickAndArgumentsWithinThree() async throws {
        let source = FakeProbeSource.table(count: 600)
        source.setReadCost(pathMicroseconds: 5, argumentsMicroseconds: 200)
        let sampler = NativeProcessSampler(source: source)
        var batches: [ProcessSampleBatch] = []
        for index in 0..<3 {
            batches.append(try await sampler.sample(plan: .fixture(at: Double(index) * 3.5)))
            source.advance(seconds: 3.5)
        }
        XCTAssertTrue(batches[0].processes.allSatisfy { !$0.executablePath.isEmpty })
        XCTAssertGreaterThan(batches[0].stats.telemetryDeferredCount, 0, "argv should be deadline-bound")
        XCTAssertTrue(batches[2].processes.allSatisfy { $0.commandLine.hasSuffix("--serve") })
        XCTAssertEqual(source.recordedCalls.path, 600, "a path is read once per identity")
    }

    func testDisabledTelemetrySkipsPathAndArgumentReads() async throws {
        let source = FakeProbeSource.table(count: 50)
        let sampler = NativeProcessSampler(source: source)
        let batch = try await sampler.sample(plan: .fixture(at: 0) { $0.telemetryDisabled = true })
        XCTAssertEqual(batch.processes.count, 50, "the process graph is still complete")
        XCTAssertEqual(source.recordedCalls.path, 0)
        XCTAssertEqual(source.recordedCalls.arguments, 0)
        XCTAssertTrue(batch.processes.allSatisfy { $0.executablePath.isEmpty })
    }

    func testDeferredIdentityIsRetriedNextTickAndNeverCountedAsAHit() async throws {
        let source = FakeProbeSource.table(count: 100)
        source.setReadCost(pathMicroseconds: 2_000, argumentsMicroseconds: 2_000)
        let sampler = NativeProcessSampler(source: source)
        let first = try await sampler.sample(plan: .fixture(at: 0))
        let placeholders = Set(first.processes.filter { $0.executablePath.isEmpty }.map(\.identity))
        XCTAssertFalse(placeholders.isEmpty)
        let placeholder = try XCTUnwrap(first.processes.first { placeholders.contains($0.identity) })
        XCTAssertEqual(placeholder.commandLine, placeholder.name)
        let fullyRead = first.stats.commandRefreshCount

        source.setReadCost(pathMicroseconds: 0, argumentsMicroseconds: 0)
        source.advance(seconds: 1)
        let second = try await sampler.sample(plan: .fixture(at: 1))
        XCTAssertEqual(second.stats.commandCacheHitCount, fullyRead)
        XCTAssertTrue(second.processes.filter { placeholders.contains($0.identity) }
            .allSatisfy { !$0.executablePath.isEmpty && $0.commandLine.hasSuffix("--serve") })
    }

    func testExecUnderANewNameRefreshesTelemetryInTheSameTick() async throws {
        let source = FakeProbeSource.table(count: 20)
        source.update(pid: 1_004) {
            $0.name = "sh"
            $0.path = "/bin/sh"
            $0.arguments = "sh -c postgres -D data"
            $0.ports = [5432]
        }
        let sampler = NativeProcessSampler(source: source)
        let focus = SamplingPlan.fixture(at: 0) { $0.includeForensicsForPIDs = [1_004] }
        _ = try await sampler.sample(plan: focus)
        source.update(pid: 1_004) {
            $0.name = "postgres"
            $0.path = "/opt/pg/bin/postgres"
            $0.arguments = "postgres -D data"
        }
        source.resetCalls()
        source.advance(seconds: 1)
        let batch = try await sampler.sample(plan: .fixture(at: 1))
        let process = try XCTUnwrap(batch.processes.first { $0.pid == 1_004 })
        XCTAssertEqual(process.name, "postgres")
        XCTAssertEqual(process.executablePath, "/opt/pg/bin/postgres")
        XCTAssertEqual(process.commandLine, "postgres -D data")
        XCTAssertTrue(process.listeningPorts.isEmpty, "the pre-exec forensics must not survive exec")
        XCTAssertEqual(source.recordedCalls.path, 1)
        XCTAssertEqual(source.recordedCalls.arguments, 1)
    }

    func testStableProcessesCostNoTelemetryReadsAfterWarmUp() async throws {
        let source = FakeProbeSource.table(count: 200)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        source.resetCalls()
        source.advance(seconds: 3.5)
        let batch = try await sampler.sample(plan: .fixture(at: 3.5))
        XCTAssertEqual(source.recordedCalls.path, 0)
        XCTAssertEqual(source.recordedCalls.arguments, 0)
        XCTAssertEqual(batch.stats.commandCacheHitCount, 200)
    }

    func testTelemetryRefreshesOnlyAfterTheSafetyNetAge() async throws {
        let source = FakeProbeSource.table(count: 3)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        source.resetCalls()
        _ = try await sampler.sample(plan: .fixture(at: 300))
        XCTAssertEqual(source.recordedCalls.arguments, 0)
        let late = SamplingPlan.telemetryRefreshInterval + SamplingPlan.fixture(at: 0).scannerBudget.staleTelemetryGrace + 1
        _ = try await sampler.sample(plan: .fixture(at: late))
        XCTAssertEqual(source.recordedCalls.arguments, 3)
        XCTAssertEqual(source.recordedCalls.path, 0, "a refresh keeps the known path")
    }
}

private extension ProcessMetrics {
    var listeningPorts: [Int] { forensics.listeningPorts }
}
