import XCTest
@testable import GhostProcessSniperCore

final class BaselineLearnerTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let learner = FamilyBaselineLearner()

    func testSlowLeakDoesNotBecomeTheNormal() throws {
        // 500 -> 1099 MB over 20 minutes at a 2 s cadence.
        let steps = 601
        var baseline: FamilyBaseline?
        for step in 0..<steps {
            let megabytes = 500 + 599 * Double(step) / Double(steps - 1)
            baseline = learner.updated(existing: baseline, family: family(megabytes: megabytes, cpu: 3, at: step * 2), now: date(step * 2))
        }
        let learned = try XCTUnwrap(baseline)
        let current = UInt64(1_099 * Double(Fixture.mib))

        XCTAssertTrue(learned.isMeasurementTrusted)
        XCTAssertGreaterThanOrEqual(learned.memoryMultiple(for: current), 1.8)
        XCTAssertGreaterThanOrEqual(learned.memoryZScore(for: current), 3)
    }

    func testCadenceDoesNotChangeTheLearnedNormal() throws {
        func learn(cadence: Int) -> FamilyBaseline? {
            var baseline: FamilyBaseline?
            for seconds in stride(from: 0, through: 3_600, by: cadence) {
                let megabytes = 600 + 200 * sin(Double(seconds) / 600)
                baseline = learner.updated(existing: baseline, family: family(megabytes: megabytes, cpu: 5, at: seconds), now: date(seconds))
            }
            return baseline
        }
        let fast = try XCTUnwrap(learn(cadence: 2))
        let slow = try XCTUnwrap(learn(cadence: 5))
        XCTAssertEqual(fast.meanMemoryBytes, slow.meanMemoryBytes, accuracy: fast.meanMemoryBytes * 0.02)
        XCTAssertEqual(fast.observedSeconds, slow.observedSeconds, accuracy: 5)
    }

    func testTrustNeedsTwentyMinutesOfLearning() throws {
        var baseline: FamilyBaseline?
        for step in 0...570 {
            baseline = learner.updated(existing: baseline, family: family(megabytes: 400, cpu: 2, at: step * 2), now: date(step * 2))
        }
        XCTAssertFalse(try XCTUnwrap(baseline).isMeasurementTrusted, "19 minutes is still learning")
        for step in 571...630 {
            baseline = learner.updated(existing: baseline, family: family(megabytes: 400, cpu: 2, at: step * 2), now: date(step * 2))
        }
        XCTAssertTrue(try XCTUnwrap(baseline).isMeasurementTrusted)
    }

    func testCredibleGrowthIsNotLearnedAsNormal() throws {
        let seeded = learner.updated(existing: nil, family: family(megabytes: 500, cpu: 2, at: 0), now: date(0))
        let climb = Fixture.trend(megabytes: [500, 520, 540, 560, 580, 600], cadence: 5)
        let growing = Fixture.family(Fixture.process(megabytes: 600, cpu: 2, date: date(30)), trend: climb)
            .enriched(lastScoredAt: date(30))
        let updated = learner.updated(existing: seeded, family: growing, now: date(30))
        XCTAssertEqual(updated.meanMemoryBytes, seeded.meanMemoryBytes)
        XCTAssertEqual(updated.observedSeconds, 30)
        XCTAssertEqual(updated.sampleCount, 2)
    }

    func testLongGapStartsANewSession() throws {
        let first = learner.updated(existing: nil, family: family(megabytes: 400, cpu: 2, at: 0), now: date(0))
        let second = learner.updated(existing: first, family: family(megabytes: 400, cpu: 2, at: 4_000), now: date(4_000))
        XCTAssertEqual(second.sessionCount, 2)
        XCTAssertEqual(second.observedSeconds, 300, "a long gap counts as one bounded step")
    }

    private func date(_ seconds: Int) -> Date {
        Fixture.now.addingTimeInterval(Double(seconds))
    }

    private func family(megabytes: Double, cpu: Double, at seconds: Int) -> ProcessFamily {
        let measured = date(seconds)
        return Fixture.family(Fixture.process(parent: 999, megabytes: megabytes, cpu: cpu, date: measured))
            .enriched(lastScoredAt: measured)
    }
}

final class BaselineCPUAnomalyTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testIdleFamilyPinnedAtHighCPUIsAnAnomaly() throws {
        let enriched = try enrich(meanCPU: 0.4, currentCPU: 80)
        XCTAssertTrue(enriched.score.components.contains { $0.kind == .baseline && $0.title == "80% CPU vs about 0.4% normally" },
                      "\(enriched.score.components.map(\.title))")
        XCTAssertTrue(enriched.score.heat.evidence.contains { $0.contains("80% CPU vs about 0.4% normally") },
                      "\(enriched.score.heat.evidence)")
    }

    func testSmallOrProportionateCPUIsNotAnAnomaly() throws {
        for (mean, current) in [(0.4, 8.0), (30.0, 45.0)] {
            let enriched = try enrich(meanCPU: mean, currentCPU: current)
            XCTAssertFalse(enriched.score.components.contains { $0.kind == .baseline }, "\(mean) -> \(current)")
        }
    }

    func testIdleBaselineRatioIsNotCapped() {
        let baseline = FamilyBaseline(signature: ProcessSignature.from(root: Fixture.process()), sampleCount: 100,
            meanMemoryBytes: 200 * 1_048_576, peakMemoryBytes: 200 * 1_048_576, meanCPUPercent: 0.4, peakCPUPercent: 2,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0, firstSeenAt: Fixture.now, lastSeenAt: Fixture.now)
        XCTAssertEqual(baseline.cpuMultiple(for: 80), 40)
    }

    private func enrich(meanCPU: Double, currentCPU: Double) throws -> ProcessFamily {
        var window = TrendWindow()
        let root = Fixture.process(parent: 999, megabytes: 200, cpu: currentCPU)
        let baseline = FamilyBaseline(signature: ProcessSignature.from(root: root), sampleCount: 100,
            meanMemoryBytes: 200 * 1_048_576, peakMemoryBytes: 220 * 1_048_576, meanCPUPercent: meanCPU,
            peakCPUPercent: meanCPU * 2, meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: Fixture.now.addingTimeInterval(-7_200), lastSeenAt: Fixture.now)
        let context = RadarContext(baselines: [baseline.signature.id: baseline], recentIncidentCounts: [:], rules: [])
        return try XCTUnwrap(Fixture.scored([root], context: context, window: &window).first)
    }
}
