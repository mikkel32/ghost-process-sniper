import XCTest
@testable import GhostProcessSniperCore

/// The sampler's CPU tracker has nothing to compare a new process with, so
/// its first sighting has a usage read but no CPU rate. The ledger counts
/// from that read, so its minutes agree with the sampler's own percent.
final class ActivityLedgerFirstSightTests: XCTestCase {
    /// On a minute boundary, so both sightings share one bucket.
    private let start = Date(timeIntervalSince1970: 600_000)
    private let identity = ProcessIdentity(pid: 800, startTimeSeconds: 500_000, startTimeMicroseconds: 0)

    private func worker(cpuSeconds: Double, at date: Date,
                        measurement: ProcessMeasurementStatus, cpu: ProcessMeasurementStatus) -> ProcessMetrics {
        ProcessMetrics(
            identity: identity, parentPID: 1, userID: 501, ownerName: "dev", name: "watcher",
            executablePath: "/usr/local/bin/node", commandLine: "node watch.js",
            residentMemoryBytes: 0, physicalFootprintBytes: 0, virtualMemoryBytes: 0,
            cpuPercent: 0, totalProcessorSeconds: cpuSeconds, threadCount: 4, isSystemProcess: false,
            sampledAt: date, measurementStatus: measurement, cpuMeasurementStatus: cpu
        )
    }

    private func record(_ ledger: inout ActivityLedger, _ process: ProcessMetrics) -> FamilyCPUActivity {
        ledger.recordProcesses([process], now: process.sampledAt)
        return ledger.recordFamily(key: "watcher", members: [process], now: process.sampledAt)
    }

    func testSecondSightingCreditsTheIntervalSinceTheFirstRead() {
        var ledger = ActivityLedger()
        let second = start.addingTimeInterval(8)
        // What the sampler reports for a new process: usage read, no rate yet.
        _ = record(&ledger, worker(cpuSeconds: 10, at: start, measurement: .fresh, cpu: .unavailable))
        let activity = record(&ledger, worker(cpuSeconds: 14, at: second, measurement: .fresh, cpu: .fresh))
        XCTAssertEqual(activity.buckets.last?.cpuSeconds ?? -1, 4, accuracy: 0.001, "4 s of CPU over 8 s")
        XCTAssertEqual(activity.buckets.last?.cores ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(activity.lastActiveAt, second)
        XCTAssertEqual(activity.measuredSince, start, "measured from the first read")
    }

    func testDeniedFirstReadCreditsNothingWhenAReadFinallyLands() {
        var ledger = ActivityLedger()
        _ = record(&ledger, worker(cpuSeconds: 0, at: start, measurement: .unavailable, cpu: .unavailable))
        // 900 CPU-seconds since birth: the first real read is a baseline, not a burst.
        let activity = record(&ledger, worker(cpuSeconds: 900, at: start.addingTimeInterval(8),
                                              measurement: .fresh, cpu: .fresh))
        XCTAssertEqual(activity.buckets.last?.cpuSeconds, 0)
        XCTAssertNil(activity.lastActiveAt)
        XCTAssertNil(activity.measuredSince)
        let third = record(&ledger, worker(cpuSeconds: 902, at: start.addingTimeInterval(16),
                                           measurement: .fresh, cpu: .fresh))
        XCTAssertEqual(third.buckets.last?.cpuSeconds ?? -1, 2, accuracy: 0.001, "counting starts from the first real read")
    }

    /// The real sampler, not a hand-built shape: a process that is already
    /// busy when the radar first sees it counts from the second scan.
    func testSamplerShapeOfANewProcessIsCreditedOnTheNextScan() async throws {
        let tick = 3.5
        let source = FakeProbeSource.table(count: 5)
        let sampler = NativeProcessSampler(source: source)
        let pid: Int32 = 1_002
        var ledger = ActivityLedger()
        var activity = FamilyCPUActivity.empty
        source.update(pid: pid) { $0.cpuSeconds = 20 }
        for index in 0..<2 {
            let batch = try await sampler.sample(plan: .fixture(at: Double(index) * tick))
            let process = try XCTUnwrap(batch.processes.first { $0.pid == pid })
            XCTAssertEqual(process.measurementStatus, .fresh)
            XCTAssertEqual(process.cpuMeasurementStatus, index == 0 ? .unavailable : .fresh)
            activity = record(&ledger, process)
            source.update(pid: pid) { $0.cpuSeconds += tick }
            source.advance(seconds: tick)
        }
        XCTAssertEqual(activity.buckets.last?.cpuSeconds ?? -1, tick, accuracy: 0.001)
    }
}
