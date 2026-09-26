import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The integer formatters must print exactly what printf printed, ties and
/// binary representation error included, or score text would change.
final class FixedFormatTests: XCTestCase {
    func testMatchesPrintfOnTiesAndEdges() {
        let values: [Double] = [
            0, -0.0, 0.04, -0.04, 0.05, 0.15, 0.25, 0.35, 0.45, 0.5, 1.5, 2.5, 3.5, -2.5,
            1.05, 1.15, 1.25, 2.675, 9.95, 9.96, 99.95, 0.95, 0.949_999_999_999_999_9,
            1e-9, 123_456.75, 999_999.95, 42, 1.0 / 3.0, 2.0 / 3.0, 5.55, 8.25, 0.125, 1.75,
        ]
        for value in values {
            XCTAssertEqual(RadarFormat.fixed1(value), String(format: "%.1f", value), "fixed1(\(value))")
            XCTAssertEqual(RadarFormat.fixed0(value), String(format: "%.0f", value), "fixed0(\(value))")
        }
    }

    func testMatchesPrintfAcrossScoringRanges() {
        var jitter = IntelligenceFixture.Jitter(seed: 7)
        for index in 0..<20_000 {
            let base = Double(index) / 20
            let value = base + jitter.next(amplitude: 0.05)
            XCTAssertEqual(RadarFormat.fixed1(value), String(format: "%.1f", value), "fixed1(\(value))")
            XCTAssertEqual(RadarFormat.fixed0(value), String(format: "%.0f", value), "fixed0(\(value))")
            let tie = Double(index) / 20
            XCTAssertEqual(RadarFormat.fixed1(tie), String(format: "%.1f", tie), "fixed1(\(tie))")
            XCTAssertEqual(RadarFormat.fixed0(tie / 10), String(format: "%.0f", tie / 10), "fixed0(\(tie / 10))")
        }
    }
}
