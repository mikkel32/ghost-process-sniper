import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalObservationTraceTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000_000)

    private func sample(_ seconds: Double, cpu: Double? = 65, gpu: Double? = 61) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: epoch.addingTimeInterval(seconds), cpuCelsius: cpu, gpuCelsius: gpu,
                        sensorCount: 2, sensorKeys: ["cpu", "gpu"], systemState: "Nominal", unavailableReason: nil)
    }

    func testThermalTraceDoesNotDuplicateCachedReadings() {
        var window = ThermalObservationWindow()
        window.record(sample(0), at: epoch)
        window.record(sample(0), at: epoch.addingTimeInterval(3))
        window.record(sample(-1), at: epoch)
        XCTAssertEqual(window.count, 1)
    }

    func testFutureAndStaleReadingsCannotEnterTheTrace() {
        var window = ThermalObservationWindow()
        window.record(sample(1), at: epoch)
        window.record(sample(-16), at: epoch)
        XCTAssertEqual(window.count, 0)
        window.record(sample(0), at: epoch.addingTimeInterval(15))
        XCTAssertEqual(window.count, 1)
    }

    func testThermalTraceIsBoundedByCountAndElapsedTime() {
        var window = ThermalObservationWindow()
        for index in 0..<200 { window.record(sample(Double(index)), at: epoch.addingTimeInterval(Double(index))) }
        XCTAssertEqual(window.count, 90)
        XCTAssertEqual(window.segments(for: .cpu, at: epoch.addingTimeInterval(199)).flatMap(\.points).count, 90)
        XCTAssertTrue(window.segments(for: .cpu, at: epoch.addingTimeInterval(199 + 181)).isEmpty)
        window.record(sample(400), at: epoch.addingTimeInterval(400))
        XCTAssertEqual(window.count, 1)
    }

    func testMissingCPUDoesNotBreakTheGPUSeries() {
        var window = ThermalObservationWindow()
        window.record(sample(0), at: epoch)
        window.record(sample(3, cpu: nil, gpu: 62), at: epoch.addingTimeInterval(3))
        window.record(sample(6, cpu: 66, gpu: 63), at: epoch.addingTimeInterval(6))
        XCTAssertEqual(window.segments(for: .cpu, at: epoch.addingTimeInterval(6)).count, 2)
        XCTAssertEqual(window.segments(for: .gpu, at: epoch.addingTimeInterval(6)).count, 1)
        XCTAssertEqual(window.segments(for: .gpu, at: epoch.addingTimeInterval(6))[0].points.map(\.celsius), [61, 62, 63])
    }

    func testLongSensorGapsNeverGetConnected() {
        var window = ThermalObservationWindow()
        for time in [0.0, 3, 30, 33] { window.record(sample(time), at: epoch.addingTimeInterval(time)) }
        let segments = window.segments(for: .cpu, at: epoch.addingTimeInterval(33))
        XCTAssertEqual(segments.map { $0.points.count }, [2, 2])
        XCTAssertNotEqual(segments[0].id, segments[1].id)
    }

    func testNonFiniteAndImplausibleTemperaturesAreGapsNotZeros() {
        var window = ThermalObservationWindow()
        for (index, value) in [Double.nan, .infinity, -5, 0, 130].enumerated() {
            let time = Double(index) * 3
            window.record(sample(time, cpu: value, gpu: nil), at: epoch.addingTimeInterval(time))
        }
        XCTAssertTrue(window.segments(for: .cpu, at: epoch.addingTimeInterval(12)).isEmpty)
        XCTAssertTrue(window.segments(for: .gpu, at: epoch.addingTimeInterval(12)).isEmpty)
    }

    func testPresentationHistoryLeavesItsInputUnchanged() {
        let original = sample(0)
        var window = ThermalObservationWindow()
        window.record(original, at: epoch)
        XCTAssertEqual(original, sample(0))
        XCTAssertEqual(window.segments(for: .cpu, at: epoch)[0].points[0].celsius, 65)
    }

    func testCachedSnapshotIsNotRepublished() throws {
        var window = ThermalObservationWindow()
        let first = try XCTUnwrap(ThermalSnapshotStore.update(.unknown, window, with: sample(0), at: epoch))
        XCTAssertEqual(first.0, sample(0))
        XCTAssertEqual(first.1.count, 1)
        window = first.1
        XCTAssertNil(ThermalSnapshotStore.update(sample(0), window, with: sample(0), at: epoch.addingTimeInterval(2)))
        let second = try XCTUnwrap(ThermalSnapshotStore.update(sample(0), window, with: sample(3, cpu: 70),
                                                               at: epoch.addingTimeInterval(3)))
        XCTAssertEqual(second.1.count, 2)
        XCTAssertEqual(second.1.segments(for: .cpu, at: epoch.addingTimeInterval(3))[0].points.map(\.celsius), [65, 70])
    }

    func testTrendIsReadyFromTheMonitorWindowWithoutAViewRecording() {
        var window = ThermalObservationWindow()
        var latest = ThermalSnapshot.unknown
        for (index, value) in [70.0, 72, 76, 80].enumerated() {
            let next = sample(Double(index * 10), cpu: value)
            if let update = ThermalSnapshotStore.update(latest, window, with: next, at: next.sampledAt) {
                (latest, window) = update
            }
        }
        let result = ThermalTemperatureAssessment.evaluate(snapshot: latest, observations: window, at: latest.sampledAt)
        XCTAssertEqual(result.trajectory.direction, .rising)
    }
}
