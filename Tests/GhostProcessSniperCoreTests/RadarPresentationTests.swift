import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class RadarPresentationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000_000)

    private func sample(_ seconds: Double, cpu: Double? = 65, gpu: Double? = 61) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: epoch.addingTimeInterval(seconds), cpuCelsius: cpu, gpuCelsius: gpu,
                        sensorCount: 2, sensorKeys: ["cpu", "gpu"], systemState: "Nominal", unavailableReason: nil)
    }

    func testContinuousMotionNeedsEveryVisibilityAndPowerGate() {
        XCTAssertTrue(RadarMotionPolicy.runsContinuousMotion(reduceMotion: false, lowPower: false, inViewport: true, windowVisible: true, applicationActive: true))
        for gate in 0..<5 {
            XCTAssertFalse(RadarMotionPolicy.runsContinuousMotion(reduceMotion: gate == 0, lowPower: gate == 1,
                                                                 inViewport: gate != 2, windowVisible: gate != 3, applicationActive: gate != 4))
        }
    }

    func testRadarBearingIsStableAndUrgencyMovesInward() {
        let quiet = RadarScopeGeometry.position(key: "node|pid:10", urgency: 0, width: 320, height: 240)
        let urgent = RadarScopeGeometry.position(key: "node|pid:10", urgency: 100, width: 320, height: 240)
        let center = CGPoint(x: 160, y: 120)
        XCTAssertEqual(RadarScopeGeometry.angle(for: "node|pid:10"), RadarScopeGeometry.angle(for: "node|pid:10"))
        XCTAssertGreaterThan(hypot(quiet.x - center.x, quiet.y - center.y), hypot(urgent.x - center.x, urgent.y - center.y))
        XCTAssertEqual(atan2(quiet.y - center.y, quiet.x - center.x), atan2(urgent.y - center.y, urgent.x - center.x), accuracy: 0.00001)
    }

    func testRadarGeometryHandlesTinyAndInvalidBounds() {
        for urgency in [Double.nan, .infinity, -100, 10_000] {
            let point = RadarScopeGeometry.position(key: "tiny", urgency: urgency, width: 1, height: 1)
            XCTAssertEqual(point, CGPoint(x: 0.5, y: 0.5))
        }
        let invalid = RadarScopeGeometry.position(key: "bad", urgency: 50, width: .nan, height: -.infinity)
        XCTAssertEqual(invalid, .zero)
    }

    func testThermalTraceDoesNotDuplicateCachedReadings() {
        var history = ThermalTraceHistory()
        XCTAssertTrue(history.append(sample(0), at: epoch))
        XCTAssertFalse(history.append(sample(0), at: epoch.addingTimeInterval(3)))
        XCTAssertFalse(history.append(sample(-1), at: epoch))
        XCTAssertEqual(history.count, 1)
    }

    func testFutureAndStaleReadingsCannotEnterTheTrace() {
        var history = ThermalTraceHistory()
        XCTAssertFalse(history.append(sample(1), at: epoch))
        XCTAssertFalse(history.append(sample(-16), at: epoch))
        XCTAssertEqual(history.count, 0)
        XCTAssertTrue(history.append(sample(0), at: epoch.addingTimeInterval(15)))
    }

    func testThermalTraceIsBoundedByCountAndElapsedTime() {
        var history = ThermalTraceHistory(capacity: 5, retention: 30)
        for index in 0..<12 { history.append(sample(Double(index) * 3), at: epoch.addingTimeInterval(Double(index) * 3)) }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.segments(for: .cpu, at: epoch.addingTimeInterval(33)).flatMap(\.points).count, 5)
        XCTAssertTrue(history.segments(for: .cpu, at: epoch.addingTimeInterval(64)).isEmpty)
        history.append(sample(100), at: epoch.addingTimeInterval(100))
        XCTAssertEqual(history.count, 1)
    }

    func testMissingCPUDoesNotBreakTheGPUSeries() {
        var history = ThermalTraceHistory()
        history.append(sample(0), at: epoch)
        history.append(sample(3, cpu: nil, gpu: 62), at: epoch.addingTimeInterval(3))
        history.append(sample(6, cpu: 66, gpu: 63), at: epoch.addingTimeInterval(6))
        XCTAssertEqual(history.segments(for: .cpu, at: epoch.addingTimeInterval(6)).count, 2)
        XCTAssertEqual(history.segments(for: .gpu, at: epoch.addingTimeInterval(6)).count, 1)
        XCTAssertEqual(history.segments(for: .gpu, at: epoch.addingTimeInterval(6))[0].points.map(\.celsius), [61, 62, 63])
    }

    func testLongSensorGapsNeverGetConnected() {
        var history = ThermalTraceHistory()
        for time in [0.0, 3, 30, 33] { history.append(sample(time), at: epoch.addingTimeInterval(time)) }
        let segments = history.segments(for: .cpu, at: epoch.addingTimeInterval(33))
        XCTAssertEqual(segments.map { $0.points.count }, [2, 2])
        XCTAssertNotEqual(segments[0].id, segments[1].id)
    }

    func testNonFiniteAndImplausibleTemperaturesAreGapsNotZeros() {
        var history = ThermalTraceHistory()
        for (index, value) in [Double.nan, .infinity, -5, 0, 130].enumerated() {
            let time = Double(index) * 3
            history.append(sample(time, cpu: value, gpu: nil), at: epoch.addingTimeInterval(time))
        }
        XCTAssertTrue(history.segments(for: .cpu, at: epoch.addingTimeInterval(12)).isEmpty)
        XCTAssertTrue(history.segments(for: .gpu, at: epoch.addingTimeInterval(12)).isEmpty)
    }

    func testPresentationHistoryLeavesItsInputUnchanged() {
        let original = sample(0)
        var history = ThermalTraceHistory()
        history.append(original, at: epoch)
        XCTAssertEqual(original, sample(0))
        XCTAssertEqual(history.segments(for: .cpu, at: epoch)[0].points[0].celsius, 65)
    }
}
