import XCTest
@testable import GhostProcessSniperCore

final class FullCoverageSamplingTests: XCTestCase {
    private let tick: Double = 3.5

    func testQuietProcessThatStartsSpinningReadsFullCoreOnTheNextTick() async throws {
        let source = FakeProbeSource.table(count: 600)
        let sampler = NativeProcessSampler(source: source)
        let spinner: Int32 = 1_417
        var last: ProcessSampleBatch?
        for index in 0..<4 {
            if index == 3 { source.update(pid: spinner) { $0.cpuSeconds += self.tick } }
            last = try await sampler.sample(plan: .fixture(at: Double(index) * tick))
            source.advance(seconds: tick)
        }
        let batch = try XCTUnwrap(last)
        let process = try XCTUnwrap(batch.processes.first { $0.pid == spinner })
        XCTAssertEqual(process.cpuPercent, 100, accuracy: 2)
        XCTAssertEqual(process.cpuMeasurementStatus, .fresh)
        XCTAssertEqual(process.measurementStatus, .fresh)
        XCTAssertEqual(batch.stats.usageReadCount, 600)
        XCTAssertLessThanOrEqual(batch.stats.taskInfoReadCount, SamplingPlan.fixture(at: 0).metricsEnrichmentBudget)
    }

    func testLargeFamilyIsFullyMeasuredOnEveryTick() async throws {
        let source = FakeProbeSource((0..<60).map { index in
            FakeProbeSource.Process(pid: 2_000 + Int32(index), name: "Browser Helper",
                                    parentPID: index == 0 ? 1 : 2_000)
        } + (0..<300).map { FakeProbeSource.Process(pid: 5_000 + Int32($0), name: "other-\($0)") })
        let sampler = NativeProcessSampler(source: source)
        for index in 0..<6 {
            let plan = SamplingPlan.fixture(at: Double(index) * tick)
            let batch = try await sampler.sample(plan: plan)
            let members = batch.processes.filter { (2_000..<2_060).contains($0.pid) }
            XCTAssertEqual(members.count, 60)
            let family = RefreshPerformanceFixture.family(members[0], members: members)
            XCTAssertTrue(family.hasRecentMeasurements(at: plan.sampledAt), "tick \(index)")
            source.advance(seconds: tick)
        }
    }

    func testDeniedUsageIsUnavailableAndNeverBorrowsAnotherIdentity() async throws {
        let source = FakeProbeSource.table(count: 20)
        source.update(pid: 1_005) { $0.usageDenied = true }
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        source.advance(seconds: tick)
        source.update(pid: 1_006) { $0.cpuSeconds = 3.5 }
        let batch = try await sampler.sample(plan: .fixture(at: tick))
        let denied = try XCTUnwrap(batch.processes.first { $0.pid == 1_005 })
        XCTAssertEqual(denied.cpuMeasurementStatus, .unavailable)
        XCTAssertEqual(denied.measurementStatus, .unavailable)
        XCTAssertEqual(denied.cpuPercent, 0)
        XCTAssertEqual(denied.physicalFootprintBytes, 0)
        XCTAssertEqual(batch.stats.usageFailedCount, 1)
    }

    func testReusedPIDBetweenReadsNeverProducesACrossIdentityDelta() async throws {
        let source = FakeProbeSource.table(count: 10)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        source.advance(seconds: tick)
        let reused = FakeProbeSource.Process(pid: 1_003, name: "impostor", cpuSeconds: 900,
                                             footprint: 9 << 30, startStamp: 42)
        source.impersonateUsage(of: 1_003, with: reused)
        let batch = try await sampler.sample(plan: .fixture(at: tick))
        let process = try XCTUnwrap(batch.processes.first { $0.pid == 1_003 })
        XCTAssertNotEqual(process.cpuMeasurementStatus, .fresh)
        XCTAssertLessThan(process.cpuPercent, 1)
        XCTAssertLessThan(process.physicalFootprintBytes, 1 << 30)
        XCTAssertEqual(batch.stats.usageFailedCount, 1)

        // The real process is measured again once its own reading returns.
        source.impersonateUsage(of: 1_003, with: nil)
        source.advance(seconds: tick)
        source.update(pid: 1_003) { $0.cpuSeconds = 1.75 }
        let after = try await sampler.sample(plan: .fixture(at: tick * 2))
        let recovered = try XCTUnwrap(after.processes.first { $0.pid == 1_003 })
        XCTAssertEqual(recovered.cpuMeasurementStatus, .fresh)
        XCTAssertEqual(recovered.cpuPercent, 25, accuracy: 0.5)
    }

    func testWallClockJumpingBackwardsKeepsCPUMeasured() async throws {
        let source = FakeProbeSource.table(count: 5)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 10_000))
        source.advance(seconds: 2)
        source.update(pid: 1_002) { $0.cpuSeconds = 1 }
        let batch = try await sampler.sample(plan: .fixture(at: 0))
        let process = try XCTUnwrap(batch.processes.first { $0.pid == 1_002 })
        XCTAssertEqual(process.cpuMeasurementStatus, .fresh)
        XCTAssertEqual(process.cpuPercent, 50, accuracy: 0.5)
    }

    func testCriticalThermalStateStillMeasuresHotFamilies() async throws {
        var scheduler = RadarScheduler(pressureProvider: { .critical })
        let hot = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(0, pid: 1_001), level: .hot)
        let plan = scheduler.plan(settings: .smart, families: [hot], popoverVisible: false,
                                  now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(plan.probePolicy.allowsRichMetrics)
        XCTAssertGreaterThanOrEqual(plan.metricsEnrichmentBudget, 4)
        XCTAssertFalse(plan.allowsOptionalForensics)

        let source = FakeProbeSource.table(count: 50)
        let sampler = NativeProcessSampler(source: source)
        for index in 0..<3 {
            var tickPlan = plan
            tickPlan.sampledAt = plan.sampledAt.addingTimeInterval(Double(index) * tick)
            source.update(pid: 1_001) { $0.cpuSeconds += self.tick }
            let batch = try await sampler.sample(plan: tickPlan)
            let process = try XCTUnwrap(batch.processes.first { $0.pid == 1_001 })
            XCTAssertEqual(process.measurementStatus, .fresh)
            XCTAssertGreaterThan(batch.stats.taskInfoReadCount, 0)
            if index > 0 { XCTAssertEqual(process.cpuMeasurementStatus, .fresh) }
            source.advance(seconds: tick)
        }
    }
}
