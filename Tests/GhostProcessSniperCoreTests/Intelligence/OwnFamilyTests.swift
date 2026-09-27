import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Ghost's own process can use real CPU while its console is open. It stays
/// visible, but it never asks the user to review or stop it.
final class OwnFamilyTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let cadence: TimeInterval = 3

    func testABusyLoopIsFlaggedUnlessItIsGhostItself() throws {
        let other = try XCTUnwrap(spin(minutes: 3.5, ownPID: 999).first)
        XCTAssertEqual(other.forecast.state, .runaway)
        XCTAssertGreaterThanOrEqual(other.score.level, .watch)

        let ghost = try XCTUnwrap(spin(minutes: 3.5, ownPID: 200).first)
        XCTAssertEqual(ghost.score.level, .quiet)
        XCTAssertEqual(ghost.forecast.state, RiskForecast.quiet.state)
        XCTAssertEqual(ghost.alertState.kind, AlertState.normal.kind)
        XCTAssertTrue(ghost.suggestions.isEmpty)
        XCTAssertGreaterThan(ghost.totalCPUPercent, 90, "still measured")
    }

    private func spin(minutes: Double, ownPID: Int32) -> [ProcessFamily] {
        var pipeline = RadarPipeline(
            builder: ProcessFamilyBuilder(currentUserID: 501, processorCount: 8),
            intelligence: RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8), ownPID: ownPID)
        )
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        let ticks = Int(minutes * 60 / cadence)
        let start = Fixture.now.addingTimeInterval(-Double(ticks) * cadence)
        var families: [ProcessFamily] = []
        for tick in 0...ticks {
            let date = start.addingTimeInterval(Double(tick) * cadence)
            let process = ProcessMetrics(
                identity: ProcessIdentity(pid: 200, startTimeSeconds: 40_000, startTimeMicroseconds: 0),
                parentPID: 1, userID: 501, ownerName: "dev", name: "GhostProcessSniper",
                executablePath: "/Applications/Ghost Process Sniper.app/Contents/MacOS/GhostProcessSniper",
                commandLine: "GhostProcessSniper", residentMemoryBytes: 200 * Fixture.mib,
                physicalFootprintBytes: 200 * Fixture.mib, virtualMemoryBytes: 400 * Fixture.mib, cpuPercent: 99,
                totalProcessorSeconds: 0.99 * cadence * Double(tick + 1), threadCount: 8, isSystemProcess: false,
                sampledAt: date
            )
            families = pipeline.run(processes: [process], settings: .smart, context: context, now: date).families
        }
        return families
    }
}
