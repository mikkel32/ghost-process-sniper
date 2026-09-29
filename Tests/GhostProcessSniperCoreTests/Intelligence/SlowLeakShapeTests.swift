import XCTest
@testable import GhostProcessSniperCore

/// The long-term fit must tell growth that keeps going from one allocation
/// that happened to land in the middle of the window.
final class SlowLeakShapeTests: XCTestCase {
    private let ram: UInt64 = 16 << 30

    /// Closed minute buckets from a shape in MB, with deterministic ±`jitter` noise.
    private func buckets(_ minutes: Int = 89, jitter: Double = 6, shape: (Int) -> Double) -> [MemberTrendStore.MinuteBucket] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<minutes).map { minute in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = (Double(seed >> 33) / Double(1 << 31) - 1) * jitter
            let value = Float(shape(minute) + noise)
            return MemberTrendStore.MinuteBucket(minute: Int32(1_000 + minute), minimum: value - 3, maximum: value + 3,
                                                 mean: value, count: 20)
        }
    }

    func testOneAllocationInTheMiddleOfTheWindowIsNotASlowLeak() {
        for stepAt in 3...84 {
            let trend = MemberTrendStore.fit(buckets { minute in
                minute < stepAt ? 500 : minute < stepAt + 3 ? 500 + Double(minute - stepAt + 1) * 200 : 1_100
            })
            XCTAssertFalse(trend.isSlowLeak(physicalMemoryBytes: ram),
                           "a 600 MB step at minute \(stepAt) read as \(trend.slopeMegabytesPerMinute) MB/min, R² \(trend.rSquared)")
        }
    }

    func testSteadyStaircaseAndSawtoothLeaksAreStillSlowLeaks() {
        let steady = MemberTrendStore.fit(buckets { 400 + 6 * Double($0) })
        XCTAssertTrue(steady.isSlowLeak(physicalMemoryBytes: ram))
        // 60 MB every ten minutes: many steps, each one small.
        let staircase = MemberTrendStore.fit(buckets { 400 + 60 * Double($0 / 10) })
        XCTAssertTrue(staircase.isSlowLeak(physicalMemoryBytes: ram))
        // A garbage collector saws 150 MB up and down every 7 minutes while the troughs rise 6 MB/min.
        let sawtooth = MemberTrendStore.fit(buckets { 400 + 6 * Double($0) + 150 * Double($0 % 7) / 7 })
        XCTAssertTrue(sawtooth.isSlowLeak(physicalMemoryBytes: ram))
        // A leak that began half an hour ago still counts once it dominates the window.
        let recent = MemberTrendStore.fit(buckets { $0 < 30 ? 400 : 400 + 9 * Double($0 - 30) })
        XCTAssertTrue(recent.isSlowLeak(physicalMemoryBytes: ram))
    }
}
