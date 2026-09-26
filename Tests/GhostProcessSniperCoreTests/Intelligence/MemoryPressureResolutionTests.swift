import XCTest
@testable import GhostProcessSniperCore

final class MemoryPressureResolutionTests: XCTestCase {
    private let swapBurst = MemoryPressureLevel.swapGrowthThresholdBytes + 1

    func testKernelVerdictAndSwapGrowthResolveTheLevel() {
        let cases: [(kernel: Int?, used: Double, swap: UInt64, expected: MemoryPressureLevel, line: UInt)] = [
            // The kernel's verdict wins over the used-fraction bands.
            (4, 0.10, 0, .critical, #line),
            (2, 0.10, 0, .warning, #line),
            (1, 0.95, 0, .elevated, #line),
            (1, 0.88, 0, .elevated, #line),
            (1, 0.50, 0, .nominal, #line),
            // Unknown kernel values fall back to the bands.
            (nil, 0.95, 0, .critical, #line),
            (nil, 0.86, 0, .warning, #line),
            (nil, 0.75, 0, .elevated, #line),
            (nil, 0.50, 0, .nominal, #line),
            (3, 0.50, 0, .nominal, #line),
            // Fast swap growth raises one step, capped at Warning.
            (1, 0.50, swapBurst, .elevated, #line),
            (1, 0.80, swapBurst, .warning, #line),
            (2, 0.50, swapBurst, .warning, #line),
            (4, 0.50, swapBurst, .critical, #line),
            (nil, 0.95, swapBurst, .critical, #line),
            (nil, 0.50, MemoryPressureLevel.swapGrowthThresholdBytes, .nominal, #line)
        ]
        for item in cases {
            XCTAssertEqual(
                MemoryPressureLevel.resolve(kernelLevel: item.kernel, usedFraction: item.used, swapGrowthBytes: item.swap),
                item.expected,
                "kernel \(String(describing: item.kernel)), used \(item.used), swap \(item.swap)",
                line: item.line
            )
        }
    }

    func testSwapGrowthIsMeasuredOverFiveMinutesOfMinuteSamples() {
        let start = Date(timeIntervalSince1970: 10_000)
        let mib: UInt64 = 1_048_576
        var history = SwapGrowthHistory()
        XCTAssertEqual(history.record(1_000 * mib, at: start), 0)
        XCTAssertEqual(history.record(1_100 * mib, at: start.addingTimeInterval(20)), 100 * mib,
                       "readings between samples still report growth")
        for minute in 1...5 {
            _ = history.record((1_000 + UInt64(minute) * 60) * mib, at: start.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertEqual(history.record(1_360 * mib, at: start.addingTimeInterval(330)), 360 * mib)
        _ = history.record(1_360 * mib, at: start.addingTimeInterval(360))
        XCTAssertEqual(history.record(1_360 * mib, at: start.addingTimeInterval(370)), 300 * mib,
                       "the oldest minute rolls out of the window")
        XCTAssertEqual(history.record(200 * mib, at: start.addingTimeInterval(420)), 0, "shrinking swap is not growth")
    }
}
