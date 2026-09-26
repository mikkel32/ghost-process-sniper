import XCTest
@testable import GhostProcessSniperCore

final class MeasurementCoverageTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private var root: ProcessMetrics {
        Fixture.process(pid: 43_000, parent: 999, command: "node node_modules/.bin/vite", megabytes: 6_000, cpu: 150)
    }

    func testOneUnmeasuredChildDoesNotBlankARunawayFamily() throws {
        let child = Fixture.process(pid: 43_001, parent: 43_000, name: "esbuild", path: "/usr/local/bin/esbuild",
                                    megabytes: 0, status: .unavailable)
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([root, child], window: &window).first { $0.root.pid == 43_000 })

        XCTAssertEqual(family.members.count, 2)
        XCTAssertTrue(family.coverage.isScorable)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        XCTAssertNotEqual(family.score.reasons, ["Measurements incomplete or stale"])
    }

    func testSmallStaleHelperIsEstimatedAndItsCachedCPUIsNotCounted() throws {
        let cachedAt = Fixture.now.addingTimeInterval(-60)
        let helper = Fixture.process(pid: 43_002, parent: 43_000, name: "esbuild", path: "/usr/local/bin/esbuild",
                                     megabytes: 120, cpu: 300, status: .cached(cachedAt))
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([root, helper], window: &window).first { $0.root.pid == 43_000 })

        XCTAssertTrue(family.coverage.isScorable)
        XCTAssertTrue(family.isEstimated)
        XCTAssertEqual(family.totalCPUPercent, 150, "a stale helper's cached CPU must not read as a runaway")
        XCTAssertEqual(family.totalPhysicalFootprintBytes, UInt64(6_120 * Double(Fixture.mib)), "memory carries the last-known value")
        XCTAssertEqual(family.trend.sampleCount, 1)
        XCTAssertEqual(ProcessAssessment(family: family).measurementText, "Estimated from 1 of 2 processes")
    }

    func testLargeStaleMemberStillGatesTheFamily() throws {
        let cachedAt = Fixture.now.addingTimeInterval(-60)
        let small = Fixture.process(pid: 43_010, parent: 999, command: "node node_modules/.bin/vite", megabytes: 600, cpu: 5)
        let worker = Fixture.process(pid: 43_011, parent: 43_010, name: "worker", path: "/usr/local/bin/worker",
                                     megabytes: 400, cpu: 90, status: .cached(cachedAt))
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([small, worker], window: &window).first { $0.root.pid == 43_010 })

        XCTAssertFalse(family.coverage.isScorable)
        XCTAssertEqual(family.score.level, .quiet)
        // The trend holds the stale worker at its last reading instead of
        // dropping the sample; scoring is what stays gated.
        XCTAssertEqual(family.trend.sampleCount, 1)
        XCTAssertEqual(family.trend.samples.last?.memoryBytes, family.totalPhysicalFootprintBytes)
        XCTAssertEqual(ProcessAssessment(family: family).status, "Measuring")
    }

    func testUnscorableFamilyKeepsItsSnooze() throws {
        let stale = Fixture.process(pid: 43_020, parent: 999, command: "node node_modules/.bin/vite", megabytes: 600,
                                    status: .cached(Fixture.now.addingTimeInterval(-60)))
        let snooze = RadarRule(name: "Snooze vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .quiet),
                               action: .snooze, expiresAt: Fixture.now.addingTimeInterval(600))
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [snooze])
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([stale], context: context, window: &window).first)

        XCTAssertFalse(family.coverage.isScorable)
        XCTAssertEqual(family.alertState.kind, .snoozed)
        XCTAssertEqual(family.suggestions.map(\.type), [.snooze])
    }

    func testIncompleteDevFamiliesBecomeSamplingCandidates() {
        let stale = (0..<6).map { index in
            Fixture.family(Fixture.process(pid: 43_100 + Int32(index), megabytes: 200,
                                           status: .cached(Fixture.now.addingTimeInterval(-60))))
        }
        XCTAssertTrue(stale.allSatisfy { !$0.coverage.isScorable })
        let first = FamilySamplingDemand(families: stale, focusedKeys: [], pass: 0)
        XCTAssertEqual(first.candidateIdentities.count, FamilySamplingDemand.incompleteFamiliesPerPass)
        let second = FamilySamplingDemand(families: stale, focusedKeys: [], pass: 1)
        XCTAssertEqual(first.candidateIdentities.union(second.candidateIdentities).count, stale.count,
                       "rotation reaches every incomplete family")
    }
}
