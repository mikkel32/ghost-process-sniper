import XCTest
@testable import GhostProcessSniperCore

final class HardwareOffenderRankTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testLargestNormalAppIsWatchedNotHot() throws {
        var window = TrendWindow()
        var slack: ProcessFamily?
        for tick in 0..<12 {
            let date = Fixture.now.addingTimeInterval(Double(tick - 11) * 5)
            slack = Fixture.scored(world(at: date), window: &window, at: date).first { $0.root.name == "Slack" }
        }
        let family = try XCTUnwrap(slack)

        XCTAssertLessThanOrEqual(family.score.level, .watch)
        XCTAssertFalse(family.score.heat.shouldRaiseLiveAlert)
        XCTAssertNotEqual(family.alertState.kind, .new)
        let memorySignals = family.hardwareSignals.filter { $0.kind == .memoryPressure || $0.reason.contains("memory") }
        XCTAssertEqual(memorySignals.count, 1, "\(family.hardwareSignals.map(\.reason))")
        XCTAssertTrue(family.hardwareSignals.allSatisfy { $0.kind != .sampleOutlier || $0.level <= .watch })
    }

    func testOutliersNeverExceedWatchAndMergeIntoFixedSignals() throws {
        let detector = HardwareOffenderDetector(currentUserID: 501, physicalMemoryBytes: 16 * 1_073_741_824)
        let profiles = detector.detect(processes: world(at: Fixture.now), settings: .smart)
        let slack = try XCTUnwrap(profiles.values.first { $0.pid == 41_000 })

        XCTAssertEqual(slack.signals.count, 1)
        XCTAssertEqual(slack.signals.first?.kind, .memoryPressure)
        XCTAssertTrue(slack.signals.first?.reason.hasSuffix("(largest on this Mac)") == true)
        XCTAssertTrue(profiles.values.flatMap(\.signals).allSatisfy { $0.kind != .sampleOutlier || $0.level == .watch })
    }

    func testMemoryFarAboveTheLimitIsStillHot() throws {
        var window = TrendWindow()
        let big = Fixture.process(pid: 41_500, name: "node", megabytes: 1_600, cpu: 3)
        let family = try XCTUnwrap(Fixture.scored([big], window: &window).first)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
    }

    func testCPUReasonNeverClaimsPersistenceFromOneReading() {
        let detector = HardwareOffenderDetector(currentUserID: 501)
        let busy = Fixture.process(pid: 41_600, name: "worker", megabytes: 100, cpu: 150)
        let reasons = detector.detect(processes: [busy], settings: .smart).values.flatMap(\.signals).map(\.reason)
        XCTAssertFalse(reasons.contains { $0.localizedCaseInsensitiveContains("sustained") }, "\(reasons)")
        XCTAssertTrue(reasons.contains { $0.hasPrefix("CPU pressure") })
    }

    /// A steady 700 MB Slack at 3% CPU, the biggest of 21 ordinary apps.
    private func world(at date: Date) -> [ProcessMetrics] {
        let slack = Fixture.process(pid: 41_000, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack",
                                    command: "/Applications/Slack.app/Contents/MacOS/Slack", megabytes: 700, cpu: 3, date: date)
        let others = (1...20).map { index in
            Fixture.process(pid: 41_000 + Int32(index), name: "App\(index)",
                            path: "/Applications/App\(index).app/Contents/MacOS/App\(index)",
                            command: "App\(index)", megabytes: 40 + Double(index) * 8, cpu: 1, date: date)
        }
        return [slack] + others
    }
}
