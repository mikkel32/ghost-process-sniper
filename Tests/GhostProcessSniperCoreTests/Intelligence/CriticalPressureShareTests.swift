import XCTest
@testable import GhostProcessSniperCore

/// Critical memory pressure made every big family Urgent at once: the
/// Simulator, ChatGPT and a build all read Urgent while only one of them held
/// much of the memory. Urgent is for the families the Mac is short of memory
/// because of; the rest stay Review.
final class CriticalPressureShareTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let starved = SystemMemoryPressure(level: .critical, usedFraction: 0.97, totalBytes: 16 << 30,
                                               availableBytes: 512 << 20, compressedBytes: 5 << 30)

    /// Ten flat scans of two apps, scored with the pressure shared between them.
    private func scored() throws -> (big: ProcessFamily, small: ProcessFamily) {
        var window = TrendWindow()
        let builder = ProcessFamilyBuilder(currentUserID: 501, processorCount: 8)
        let intelligence = RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8))
        var result: [ProcessFamily] = []
        for step in 0..<10 {
            let date = Fixture.now.addingTimeInterval(Double(step - 9) * 5)
            let processes = [
                Fixture.process(pid: 9_100, name: "Simulator", path: "/Applications/Simulator.app/Contents/MacOS/Simulator",
                                megabytes: 4_600, cpu: 3, date: date),
                Fixture.process(pid: 9_200, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                                megabytes: 1_500, cpu: 3, date: date),
            ]
            let built = builder.buildFamilies(from: processes, settings: .smart, trendWindow: &window, now: date)
            let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: starved)
                .attributingPressure(to: built)
            result = built.map { intelligence.enrich(family: $0, context: context, settings: .smart, now: date) }
        }
        let big = try XCTUnwrap(result.first { $0.root.pid == 9_100 })
        let small = try XCTUnwrap(result.first { $0.root.pid == 9_200 })
        return (big, small)
    }

    func testOnlyAFamilyHoldingMuchOfTheMemoryIsUrgent() throws {
        let (big, small) = try scored()
        XCTAssertEqual(big.score.level, .critical, "about 29% of the memory in use")
        XCTAssertEqual(small.score.level, .hot, "about 9%: worth a look, not the reason the Mac is starved")
    }
}
