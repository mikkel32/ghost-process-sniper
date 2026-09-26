import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Every builder family carries a classification, so the developer test
/// must look at its substance: on a real workstation in All mode, plain
/// apps must neither be sampling hints nor take port-census slots.
final class DeveloperDemandPipelineTests: XCTestCase {
    func testAllModeKeepsPlainAppsOutOfDeveloperDemandAndTheCensus() {
        var settings = ThresholdSettings.smart
        settings.radarMode = .all
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: RadarRule.builtIns(settings: settings))
        var pipeline = RadarPipeline(
            builder: ProcessFamilyBuilder(currentUserID: DevWorkstationFixture.user, processorCount: 8,
                                          physicalMemoryBytes: 32 << 30, directoryExists: { _ in true }),
            intelligence: RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8, physicalMemoryBytes: 32 << 30))
        )
        var families: [ProcessFamily] = []
        for tick in 0..<4 {
            families = pipeline.run(processes: DevWorkstationFixture.processes(count: 600, tick: tick), settings: settings,
                                    context: context, now: DevWorkstationFixture.date(tick: tick)).families
        }
        XCTAssertTrue(families.allSatisfy { $0.classification != nil }, "the builder always classifies")
        let plainApps = families.filter {
            $0.devConfidence < FamilySamplingDemand.developerConfidence && $0.classification?.kind == .unknownHeavy
        }
        XCTAssertFalse(plainApps.isEmpty, "the fixture must include plain apps for this test to mean anything")
        let plainIDs = Set(plainApps.flatMap { $0.members.map(\.identity) })

        let demand = FamilySamplingDemand(families: families, focusedKeys: [])
        XCTAssertFalse(demand.devIdentities.isEmpty)
        XCTAssertTrue(demand.devIdentities.isDisjoint(with: plainIDs))

        var scheduler = RadarScheduler(pressureProvider: { .nominal })
        var censusPicks = 0
        for step in 0..<30 {
            let plan = scheduler.plan(settings: settings, families: families, uiVisible: false,
                                      now: DevWorkstationFixture.date(tick: 4).addingTimeInterval(Double(step) * 3.5))
            censusPicks += plan.portCensusIdentities.count
            XCTAssertTrue(plan.portCensusIdentities.isDisjoint(with: plainIDs), "step \(step) gave a census slot to a plain app")
        }
        XCTAssertGreaterThan(censusPicks, 0, "the census still runs for developer families")
    }
}
