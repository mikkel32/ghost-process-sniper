import XCTest
@testable import GhostProcessSniperCore

/// Being big is worth watching; it is not a problem once the learned normal
/// says this size is usual for the app.
final class UsualSizeTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let app = "/Applications/Claude.app/Contents/MacOS/Claude"

    private func chat(cpu: Double = 3) -> ProcessMetrics {
        Fixture.process(pid: 11_850, name: "Claude", path: app, command: app, megabytes: 2_560, cpu: cpu)
    }

    private func score(_ process: ProcessMetrics, usual megabytes: Double?, pressure: SystemMemoryPressure = .unknown) -> ProcessFamily? {
        var window = TrendWindow()
        let probe = Fixture.scored([process], window: &window)
        guard let signature = probe.first?.signature else { return nil }
        var baselines: [String: FamilyBaseline] = [:]
        if let megabytes {
            let mib = Double(Fixture.mib)
            baselines[signature.id] = FamilyBaseline(
                signature: signature, sampleCount: 2_000, meanMemoryBytes: megabytes * mib,
                peakMemoryBytes: UInt64(megabytes * 1.2 * mib), meanCPUPercent: 3, peakCPUPercent: 40,
                meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
                firstSeenAt: Fixture.now.addingTimeInterval(-86_400), lastSeenAt: Fixture.now.addingTimeInterval(-5),
                memoryVariance: (150 * mib) * (150 * mib), cpuVariance: 25, observedSeconds: 36_000, sessionCount: 4)
        }
        let context = RadarContext(baselines: baselines, recentIncidentCounts: [:], rules: [], systemPressure: pressure)
        var fresh = TrendWindow()
        return Fixture.scored([process], context: context, window: &fresh).first
    }

    func testABigAppAtItsUsualSizeIsWatchedNotHot() throws {
        XCTAssertEqual(try XCTUnwrap(score(chat(), usual: nil)).score.level, .hot, "unknown size: Hot, as before")
        let usual = try XCTUnwrap(score(chat(), usual: 2_450))
        XCTAssertEqual(usual.score.level, .watch)
        XCTAssertTrue(usual.score.heat.evidence.contains { $0.hasPrefix("Large, but normal for it") }, "\(usual.score.heat.evidence)")
    }

    func testTwiceItsUsualSizeBusyOrUnderPressureStaysHot() throws {
        XCTAssertEqual(try XCTUnwrap(score(chat(), usual: 1_200)).score.level, .hot)
        let busy = try XCTUnwrap(score(chat(cpu: 900), usual: 2_450))
        XCTAssertGreaterThanOrEqual(busy.score.level, .hot)
        let squeezed = SystemMemoryPressure(level: .warning, usedFraction: 0.92, totalBytes: 16 << 30,
                                            availableBytes: 1 << 30, compressedBytes: 4 << 30)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score(chat(), usual: 2_450, pressure: squeezed)).score.level, .hot)
    }
}
