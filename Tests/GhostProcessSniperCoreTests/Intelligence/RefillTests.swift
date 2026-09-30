import XCTest
@testable import GhostProcessSniperCore

/// A restarted or purged app climbing back toward the size it normally uses
/// is refilling, not leaking. Being above the memory limit plus a few MB/min
/// of growth was called a leak, and "large, but normal for it" switched off
/// the moment the app grew at all: it read as a problem until it was full.
final class RefillTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let app = "/Applications/Claude.app/Contents/MacOS/Claude"
    private let mib = Double(Fixture.mib)
    /// Two cores keep the automatic CPU limit at the profile's own 90%; the
    /// RAM is pinned because the slow-leak floor scales with it.
    private let forecaster = FamilyRiskForecaster(processorCount: 2, physicalMemoryBytes: 16 << 30)

    private func usual(_ megabytes: Double, spread: Double = 150, for signature: ProcessSignature) -> FamilyBaseline {
        FamilyBaseline(
            signature: signature, sampleCount: 2_000, meanMemoryBytes: megabytes * mib,
            peakMemoryBytes: UInt64(megabytes * 1.2 * mib), meanCPUPercent: 3, peakCPUPercent: 40,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: Fixture.now.addingTimeInterval(-86_400), lastSeenAt: Fixture.now.addingTimeInterval(-5),
            memoryVariance: (spread * mib) * (spread * mib), cpuVariance: 25, observedSeconds: 36_000, sessionCount: 4)
    }

    private func chat(megabytes: Double, date: Date = Fixture.now) -> ProcessMetrics {
        Fixture.process(pid: 11_850, name: "Claude", path: app, command: app, megabytes: megabytes, cpu: 3, date: date)
    }

    /// A steady climb of `rate` MB/min over 17 scans ten seconds apart, ending at the fixture clock.
    private func climb(from start: Double, rate: Double) -> [Double] {
        (0..<17).map { start + Double($0) * rate * 10 / 60 }
    }

    private func forecast(from start: Double, rate: Double, usualMegabytes: Double?, settings: ThresholdSettings = .smart) -> RiskForecast {
        let memory = climb(from: start, rate: rate)
        let root = chat(megabytes: memory.last ?? start)
        var family = Fixture.family(root, trend: Fixture.trend(megabytes: memory, cadence: 10), level: .watch)
        if let usualMegabytes {
            family = family.enriched(baseline: usual(usualMegabytes, for: ProcessSignature.from(root: root)))
        }
        return forecaster.forecast(family: family, settings: settings, now: Fixture.now)
    }

    /// The pipeline, tick by tick, with a learned usual size for the family.
    private func scored(from start: Double, rate: Double, usualMegabytes: Double?,
                        pressure: SystemMemoryPressure = .unknown) throws -> ProcessFamily {
        var probeWindow = TrendWindow()
        let signature = try XCTUnwrap(Fixture.scored([chat(megabytes: start)], window: &probeWindow).first).signature
        var baselines: [String: FamilyBaseline] = [:]
        if let usualMegabytes { baselines[signature.id] = usual(usualMegabytes, for: signature) }
        let context = RadarContext(baselines: baselines, recentIncidentCounts: [:], rules: [], systemPressure: pressure)
        var window = TrendWindow()
        var family: ProcessFamily?
        for (index, megabytes) in climb(from: start, rate: rate).enumerated() {
            let date = Fixture.now.addingTimeInterval(Double(index - 16) * 10)
            family = Fixture.scored([chat(megabytes: megabytes, date: date)], context: context, processorCount: 2,
                                    window: &window, at: date).first
        }
        return try XCTUnwrap(family)
    }

    // MARK: The usual range

    func testTheUsualCeilingIsWhereUsualSizeStopsCallingItUsual() {
        let baseline = usual(2_450, for: ProcessSignature.from(root: chat(megabytes: 100)))
        XCTAssertEqual(baseline.usualMemoryCeilingBytes / mib, 2_750, accuracy: 0.01, "two spreads above the mean")
        let wide = usual(2_450, spread: 600, for: ProcessSignature.from(root: chat(megabytes: 100)))
        XCTAssertEqual(wide.usualMemoryCeilingBytes / mib, 2_450 * 1.3, accuracy: 0.01, "never past 1.3x, however wide the spread")
        for (candidate, expected) in [(2_749.0, true), (2_751.0, false)] {
            let footprint = UInt64(candidate * mib)
            XCTAssertEqual(baseline.memoryZScore(for: footprint) < 2 && baseline.memoryMultiple(for: footprint) < 1.3, expected, "\(candidate)")
        }
    }

    func testStayingWithinTheUsualSizeNeedsATrustedBaselineAndARoomyClimb() {
        let signature = ProcessSignature.from(root: chat(megabytes: 100))
        let baseline = usual(2_450, for: signature)
        func stays(_ megabytes: Double, growth: Double, of baseline: FamilyBaseline) -> Bool {
            baseline.staysWithinUsualSize(footprint: UInt64(megabytes * mib), growthMegabytesPerMinute: growth)
        }
        XCTAssertTrue(stays(1_700, growth: 40, of: baseline), "1.7 GB + 10 min of 40 MB/min is 2.1 GB")
        XCTAssertTrue(stays(1_700, growth: -300, of: baseline), "release is not growth")
        XCTAssertFalse(stays(1_700, growth: 120, of: baseline), "2.9 GB in ten minutes is past its usual size")
        XCTAssertFalse(stays(1_700, growth: 400, of: baseline))
        XCTAssertFalse(stays(2_800, growth: 0, of: baseline), "already past its usual size")
        XCTAssertFalse(stays(1_200, growth: 1, of: baseline), "below half its usual size there is no refill")
        XCTAssertTrue(stays(1_225, growth: 1, of: baseline))

        var untrusted = baseline
        untrusted.observedSeconds = 600
        XCTAssertFalse(stays(1_700, growth: 40, of: untrusted))
    }

    // MARK: The forecast

    func testAnAppRefillingTowardItsUsualSizeIsWarmingNotLeaking() {
        let refilling = forecast(from: 1_500, rate: 40, usualMegabytes: 2_450)
        XCTAssertEqual(refilling.state, .warming)
        XCTAssertEqual(refilling.horizon, .breached, "still above its memory limit; that is not what changed")
        XCTAssertTrue(refilling.whyNow.contains("back toward its usual size"), refilling.whyNow)
    }

    /// About to cross its limit (800 MB climbing to 907 MB, three minutes
    /// from 1 GB), a climb that is not a refill is a leak.
    func testAClimbThatIsNotARefillIsStillALeak() {
        XCTAssertEqual(forecast(from: 800, rate: 40, usualMegabytes: nil).horizon, .imminent)
        XCTAssertEqual(forecast(from: 800, rate: 40, usualMegabytes: nil).state, .leaking, "no learned usual size")
        XCTAssertEqual(forecast(from: 800, rate: 40, usualMegabytes: 500).state, .leaking, "already past its usual size")
        XCTAssertEqual(forecast(from: 800, rate: 40, usualMegabytes: 2_450).state, .leaking, "far below its usual size, so not a refill")
        XCTAssertEqual(forecast(from: 800, rate: 40, usualMegabytes: 1_500).state, .warming, "climbing back toward its usual size")
        XCTAssertEqual(forecast(from: 1_500, rate: 400, usualMegabytes: 2_450).state, .leaking, "would leave the usual range within minutes")
    }

    /// Claude at 4.1 GB, four times its 1 GB limit, climbing 44 MB/min while
    /// in use was "Leaking" a minute in, and so was every big app while the
    /// 2.2 baselines relearned. Past its limit, a big app's ordinary use
    /// climbs that fast: slow growth there is warming until it is fast
    /// (the leak limit) or proven over twenty minutes.
    func testSlowGrowthPastTheLimitIsWarmingUntilItIsFastOrProven() {
        for usual in [nil, 1_200.0, 2_450] as [Double?] {
            let slow = forecast(from: 1_500, rate: 40, usualMegabytes: usual)
            XCTAssertEqual(slow.horizon, .breached)
            XCTAssertEqual(slow.state, .warming, "usual \(String(describing: usual))")
            XCTAssertTrue(slow.whyNow.contains("above its memory limit"), slow.whyNow)
        }
        XCTAssertEqual(forecast(from: 1_500, rate: 400, usualMegabytes: nil).state, .leaking)
    }

    /// A custom limit is the user's exact word, and growth past the leak
    /// limit needs no nearness to a memory limit to be a leak.
    func testCustomLimitsAndFastGrowthAreNotExempt() {
        XCTAssertEqual(forecast(from: 800, rate: 40, usualMegabytes: 1_500, settings: .aggressive).state, .leaking)
        var strict = ThresholdSettings.smart
        strict.leakVelocityMegabytesPerMinute = 30
        XCTAssertEqual(forecast(from: 1_500, rate: 40, usualMegabytes: 2_450, settings: strict).state, .leaking)
    }

    /// Twenty minutes of proven creep stays a leak, refilling or not: the
    /// exception is for the near-limit shortcut, not for the proven rule.
    func testAProvenSlowLeakIsNotExcusedAsARefill() {
        let memory = climb(from: 1_500, rate: 40)
        let root = chat(megabytes: memory.last ?? 1_500)
        let creep = LongTermTrend(slopeMegabytesPerMinute: 20, floorSlopeMegabytesPerMinute: 20, rSquared: 0.9,
                                  spanMinutes: 30, persistentSlopeMegabytesPerMinute: 20)
        let trend = Fixture.trend(megabytes: memory, cadence: 10)
        let proven = Fixture.family(root, trend: trend, level: .watch, longTerm: creep)
        let baseline = usual(2_450, for: ProcessSignature.from(root: root))
        XCTAssertEqual(forecaster.forecast(family: proven.enriched(baseline: baseline), settings: .smart, now: Fixture.now).state, .leaking)
        let young = Fixture.family(root, trend: trend, level: .watch)
        XCTAssertEqual(forecaster.forecast(family: young.enriched(baseline: baseline), settings: .smart, now: Fixture.now).state, .warming,
                       "the same climb without twenty minutes behind it is a refill")
    }

    // MARK: The level

    func testARefillingAppAtItsUsualSizeIsWatchedNotHot() throws {
        let refilling = try scored(from: 1_500, rate: 40, usualMegabytes: 2_450)
        XCTAssertEqual(refilling.forecast.state, .warming)
        XCTAssertEqual(refilling.score.level, .watch)
        XCTAssertTrue(refilling.hasOnlySizeAgainstIt, "learned, and not recorded as an incident")
        XCTAssertTrue(refilling.score.heat.evidence.contains { $0.hasPrefix("Large, but normal for it") }, "\(refilling.score.heat.evidence)")
        XCTAssertFalse(refilling.score.heat.shouldRaiseLiveAlert)
    }

    func testARefillThatIsNotOneStaysHot() throws {
        XCTAssertGreaterThanOrEqual(try scored(from: 1_500, rate: 40, usualMegabytes: nil).score.level, .hot, "no usual size")
        XCTAssertGreaterThanOrEqual(try scored(from: 1_500, rate: 40, usualMegabytes: 1_200).score.level, .hot, "past its usual size")
        XCTAssertGreaterThanOrEqual(try scored(from: 1_500, rate: 400, usualMegabytes: 2_450).score.level, .hot, "a fast climb")
        let squeezed = SystemMemoryPressure(level: .warning, usedFraction: 0.92, totalBytes: 16 << 30,
                                            availableBytes: 1 << 30, compressedBytes: 4 << 30)
        let underPressure = try scored(from: 1_500, rate: 40, usualMegabytes: 2_450, pressure: squeezed)
        XCTAssertGreaterThanOrEqual(underPressure.score.level, .hot, "pressure on the Mac still counts")
    }

    /// The 90-minute drift of a multi-helper app is not growth that matters
    /// either while it stays inside the usual range.
    func testSlowDriftInsideTheUsualRangeIsNotGrowth() {
        func size(drift: Double, usualMegabytes: Double) -> Double? {
            let root = chat(megabytes: 1_900)
            let signature = ProcessSignature.from(root: root)
            let creep = LongTermTrend(slopeMegabytesPerMinute: drift, floorSlopeMegabytesPerMinute: drift, rSquared: 0.4,
                                      spanMinutes: 60, persistentSlopeMegabytesPerMinute: drift)
            let big = GhostScoreComponent(kind: .memory, title: "memory above threshold", detail: "", impact: 38, level: .critical)
            let heat = GhostHeat(value: 100, level: .hot, confidence: 0.6, evidence: [], sustainedSignalCount: 0)
            let family = ProcessFamily(
                root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                totalPhysicalFootprintBytes: root.memoryForScoringBytes, totalCPUPercent: 3, devConfidence: 0.9,
                commandHints: [], trend: .empty,
                score: GhostScore(value: 90, level: .hot, reasons: [], components: [big], heat: heat),
                ownedIdentities: [root.identity], protectedPIDs: [], lastScoredAt: Fixture.now, longTermTrend: creep)
            return GhostHeatModel.usualSize(family: family, baseline: usual(usualMegabytes, for: signature), pressure: .unknown,
                                            forecast: .quiet, sustained: 0, contextVotes: 0)
        }
        XCTAssertEqual(try XCTUnwrap(size(drift: 3, usualMegabytes: 2_450)) / mib, 2_450, accuracy: 0.01)
        XCTAssertNil(size(drift: 3, usualMegabytes: 1_500), "past its usual size")
        XCTAssertNil(size(drift: 100, usualMegabytes: 2_450), "a thousand MB in ten minutes leaves the usual range")
    }
}
