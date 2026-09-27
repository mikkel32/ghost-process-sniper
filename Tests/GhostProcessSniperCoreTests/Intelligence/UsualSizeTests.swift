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

    /// Hot for its size alone, with heat at the top of the scale.
    private func bigOnly(leaking: Bool = false, at seconds: Int) -> ProcessFamily {
        let date = Fixture.now.addingTimeInterval(Double(seconds))
        let root = Fixture.process(pid: 11_850, name: "Claude", path: app, command: app, megabytes: 2_560, cpu: 3, date: date)
        var components = [GhostScoreComponent(kind: .memory, title: "Memory footprint", detail: "", impact: 38, level: .critical)]
        if leaking { components.append(GhostScoreComponent(kind: .leak, title: "Leak", detail: "", impact: 26, level: .hot)) }
        let heat = GhostHeat(value: 100, level: .hot, confidence: 0.6, evidence: [], sustainedSignalCount: leaking ? 1 : 0)
        return ProcessFamily(
            root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
            totalPhysicalFootprintBytes: root.memoryForScoringBytes, totalCPUPercent: 3, devConfidence: 0.9,
            commandHints: [], trend: .empty,
            score: GhostScore(value: 90, level: .hot, reasons: [], components: components, heat: heat),
            ownedIdentities: [root.identity], protectedPIDs: [], lastScoredAt: date)
    }

    /// Before, an app that was Hot for being big was never learned, so it stayed Hot for good.
    func testAnAppHotOnlyForItsSizeIsLearnedAndIsNotAnIncident() {
        let learner = FamilyBaselineLearner()
        var baseline: FamilyBaseline?
        for step in 0...650 {
            baseline = learner.updated(existing: baseline, family: bigOnly(at: step * 2), now: Fixture.now.addingTimeInterval(Double(step * 2)))
        }
        XCTAssertTrue(baseline?.isMeasurementTrusted ?? false)
        XCTAssertEqual((baseline?.meanMemoryBytes ?? 0) / Double(Fixture.mib), 2_560, accuracy: 1)
        XCTAssertTrue(bigOnly(at: 0).hasOnlySizeAgainstIt)

        let leaking = learner.updated(existing: nil, family: bigOnly(leaking: true, at: 0), now: Fixture.now)
        XCTAssertEqual(leaking.sampleCount, 0, "a leak is still never learned as normal")
        XCTAssertFalse(bigOnly(leaking: true, at: 0).hasOnlySizeAgainstIt)
    }
}
