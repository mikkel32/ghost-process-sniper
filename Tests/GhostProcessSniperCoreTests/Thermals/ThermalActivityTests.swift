import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testNestedHelpersAreGroupedUnderTheirApplication() {
        let result = summary([
            sample(1, path: "/Applications/Editor.app/Contents/MacOS/Editor", cpu: 100),
            sample(2, path: "/Applications/Editor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", cpu: 50)
        ])
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(result.contributors.first?.displayName, "Editor")
        XCTAssertEqual(result.contributors.first?.cpuPercent, 150)
        XCTAssertEqual(result.contributors.first?.processCount, 2)
        XCTAssertEqual(result.contributors.first?.familyKey, "family-1")
    }

    func testStaleMissingAndFutureMeasurementsAreExcluded() {
        let result = summary([
            sample(1, cpu: 400, date: now.addingTimeInterval(-13)),
            sample(2, cpu: 400, date: now.addingTimeInterval(1)),
            ThermalActivitySample(identity: identity(3), familyKey: "missing", name: "Missing",
                executablePath: "/bin/missing", cpuPercent: 400, gpuPercent: 0, measuredAt: nil)
        ])
        XCTAssertTrue(result.contributors.isEmpty)
        XCTAssertEqual(result.unavailableProcessCount, 3)
    }

    func testDuplicateIdentityUsesNewestMeasurementOnce() {
        let result = summary([
            sample(1, cpu: 200, date: now.addingTimeInterval(-2)),
            sample(1, cpu: 20),
            sample(1, cpu: 20)
        ])
        XCTAssertEqual(result.observedProcessCount, 1)
        XCTAssertEqual(result.contributors.first?.cpuPercent, 20)
    }

    func testInvalidNumbersDoNotBecomeContributors() {
        let result = summary([sample(1, cpu: .nan), sample(2, cpu: .infinity), sample(3, cpu: -1)])
        XCTAssertTrue(result.contributors.isEmpty)
        XCTAssertEqual(result.unavailableProcessCount, 3)
    }

    func testRankingAccountsForGPUWithoutInventingHeatShares() {
        let result = summary([sample(1, cpu: 400), sample(2, cpu: 5, gpu: 75)])
        XCTAssertEqual(result.contributors.map(\.familyKey), ["family-2", "family-1"])
        XCTAssertEqual(result.contributors.first?.gpuPercent, 75)
    }

    func testEqualActivityHasStableOrdering() {
        let samples = [sample(2, cpu: 100), sample(1, cpu: 100)]
        XCTAssertEqual(summary(samples), summary(Array(samples.reversed())))
    }

    func testRowsExpireEvenWithoutAnotherRefresh() {
        let result = summary([sample(1, cpu: 100, date: now.addingTimeInterval(-10))])
        XCTAssertEqual(result.visibleContributors(at: now).count, 1)
        XCTAssertTrue(result.visibleContributors(at: now.addingTimeInterval(3)).isEmpty)
    }

    func testQuietProcessesAreNotBlamedForHeat() {
        let result = summary([sample(1, cpu: 0), sample(2, cpu: 1)])
        XCTAssertTrue(result.contributors.isEmpty)
        XCTAssertEqual(result.observedProcessCount, 2)
        XCTAssertEqual(result.unavailableProcessCount, 0)
    }

    func testCPUAndGPUFreshnessAreIndependent() {
        let result = summary([
            ThermalActivitySample(identity: identity(1), familyKey: "cpu-stale", name: "GPU Worker",
                executablePath: "/bin/gpu-worker", cpuPercent: 500, gpuPercent: 30,
                measuredAt: now.addingTimeInterval(-13), gpuMeasuredAt: now),
            ThermalActivitySample(identity: identity(2), familyKey: "gpu-stale", name: "CPU Worker",
                executablePath: "/bin/cpu-worker", cpuPercent: 80, gpuPercent: 90,
                measuredAt: now, gpuMeasuredAt: now.addingTimeInterval(-13)),
            ThermalActivitySample(identity: identity(3), familyKey: "unknown", name: "Unknown",
                executablePath: "/bin/unknown", cpuPercent: 0, gpuPercent: 0,
                measuredAt: nil)
        ])
        XCTAssertEqual(result.cpuObservedProcessCount, 1)
        XCTAssertEqual(result.gpuObservedProcessCount, 1)
        XCTAssertEqual(result.unavailableProcessCount, 1)
        XCTAssertEqual(result.contributors.first { $0.familyKey == "cpu-stale" }?.cpuPercent, 0)
        XCTAssertEqual(result.contributors.first { $0.familyKey == "gpu-stale" }?.gpuPercent, 0)
    }

    func testQuietMeasuredAppRemainsAvailableForBeforeAfterCheck() {
        let result = summary([sample(1, cpu: 1)])
        XCTAssertTrue(result.contributors.isEmpty)
        XCTAssertEqual(result.measuredContributor(id: "family-1", at: now)?.cpuPercent, 1)
    }

    func testExpiredCPUValueCannotKeepAContributorAtTheTop() {
        let result = summary([
            ThermalActivitySample(identity: identity(1), familyKey: "older-cpu", name: "Older CPU",
                executablePath: "/bin/older", cpuPercent: 200, gpuPercent: 5,
                measuredAt: now.addingTimeInterval(-11), gpuMeasuredAt: now),
            sample(2, cpu: 100)
        ])
        XCTAssertEqual(result.visibleContributors(at: now).first?.familyKey, "older-cpu")
        XCTAssertEqual(result.visibleContributors(at: now.addingTimeInterval(2)).first?.familyKey, "family-2")
    }

    func testNextExpiryIsTheEarliestReadingBoundary() {
        let result = summary([
            sample(1, cpu: 400, date: now.addingTimeInterval(-5)),
            sample(2, cpu: 300, gpu: 20, date: now.addingTimeInterval(-2))
        ])
        XCTAssertEqual(result.nextExpiry(after: now), now.addingTimeInterval(7))
        XCTAssertEqual(result.nextExpiry(after: now.addingTimeInterval(7)), now.addingTimeInterval(10))
        XCTAssertEqual(result.nextExpiry(after: now.addingTimeInterval(11)), now.addingTimeInterval(12))
        XCTAssertNil(result.nextExpiry(after: now.addingTimeInterval(12)))
        XCTAssertNil(ThermalActivitySummary.empty.nextExpiry(after: now))
        XCTAssertEqual(result.expiryDates(after: now), [7, 10, 12].map { now.addingTimeInterval($0) })
    }

    func testSnapshotExpiresFifteenSecondsAfterItsReading() {
        let snapshot = ThermalSnapshot(sampledAt: now, cpuCelsius: 70, gpuCelsius: nil, sensorCount: 1,
                                       sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
        XCTAssertEqual(snapshot.expiresAt, now.addingTimeInterval(15))
        XCTAssertEqual(snapshot.temperatureText(70, at: snapshot.expiresAt), "70.0°C")
        XCTAssertEqual(snapshot.temperatureText(70, at: snapshot.expiresAt.addingTimeInterval(0.01)), "Unavailable")
    }

    private func summary(_ samples: [ThermalActivitySample]) -> ThermalActivitySummary {
        ThermalActivitySummary.build(samples: samples, now: now, processorCount: 10)
    }

    private func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeSeconds: 1, startTimeMicroseconds: 0)
    }

    private func sample(_ pid: Int32, path: String = "/usr/local/bin/worker", cpu: Double,
                        gpu: Double = 0, date: Date? = nil) -> ThermalActivitySample {
        ThermalActivitySample(identity: identity(pid), familyKey: "family-\(pid)", name: "Worker \(pid)",
            executablePath: path, cpuPercent: cpu, gpuPercent: gpu, measuredAt: date ?? now,
            gpuMeasuredAt: gpu > 0 ? date ?? now : nil)
    }
}
