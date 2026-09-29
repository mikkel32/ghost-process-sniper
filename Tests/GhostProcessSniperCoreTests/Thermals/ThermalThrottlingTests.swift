import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The menu-bar popover says when macOS itself reports that it is holding the
/// Mac back. Only Serious and Critical count: Fair is common under load, and
/// a stale or future reading says nothing about now.
final class ThermalThrottlingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)

    private func reading(_ state: ThermalDiagnosis.State, age: TimeInterval = 0) -> ThermalPressureReading {
        ThermalPressureReading(state: state, sampledAt: now.addingTimeInterval(-age))
    }

    func testSeriousPressureIsThrottling() {
        let throttling = reading(.serious).throttling(at: now)
        XCTAssertEqual(throttling?.label, "Throttling")
        XCTAssertEqual(throttling?.isCritical, false)
        XCTAssertFalse(throttling?.detail.isEmpty ?? true)
    }

    func testCriticalPressureIsSaidPlainlyAndFlaggedCritical() {
        let throttling = reading(.critical).throttling(at: now)
        XCTAssertEqual(throttling?.label, "Critical heat")
        XCTAssertEqual(throttling?.isCritical, true)
    }

    func testNormalFairAndUnknownPressureSayNothing() {
        for state in [ThermalDiagnosis.State.normal, .warm, .checking] {
            XCTAssertNil(reading(state).throttling(at: now), "\(state) is not throttling")
        }
    }

    func testAStaleOrFutureReadingSaysNothing() {
        for age in [16.0, 600, -1] {
            XCTAssertNil(reading(.serious, age: age).throttling(at: now), "age \(age) s")
            XCTAssertNil(reading(.critical, age: age).throttling(at: now), "age \(age) s")
        }
        XCTAssertNotNil(reading(.serious, age: 15).throttling(at: now), "15 s is still current, as for the diagnosis")
    }
}
