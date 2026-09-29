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

    /// The Mac is short of memory: about 1 GB free of 16.
    private let squeezed = SystemMemoryPressure(level: .warning, usedFraction: 0.92, totalBytes: 16 << 30,
                                                availableBytes: 1 << 30, compressedBytes: 4 << 30)
    private let starved = SystemMemoryPressure(level: .critical, usedFraction: 0.97, totalBytes: 16 << 30,
                                               availableBytes: 500 << 20, compressedBytes: 6 << 30)

    private func baseline(_ signature: ProcessSignature, usual megabytes: Double, spread: Double = 150) -> FamilyBaseline {
        let mib = Double(Fixture.mib)
        return FamilyBaseline(
            signature: signature, sampleCount: 2_000, meanMemoryBytes: megabytes * mib,
            peakMemoryBytes: UInt64(megabytes * 1.2 * mib), meanCPUPercent: 3, peakCPUPercent: 40,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: Fixture.now.addingTimeInterval(-86_400), lastSeenAt: Fixture.now.addingTimeInterval(-5),
            memoryVariance: (spread * mib) * (spread * mib), cpuVariance: 25, observedSeconds: 36_000, sessionCount: 4)
    }

    private func score(_ process: ProcessMetrics, usual megabytes: Double?, pressure: SystemMemoryPressure = .unknown,
                       incidents: Int = 0, spread: Double = 150, cores: Int? = nil) -> ProcessFamily? {
        var window = TrendWindow()
        let probe = Fixture.scored([process], window: &window)
        guard let signature = probe.first?.signature else { return nil }
        var baselines: [String: FamilyBaseline] = [:]
        if let megabytes {
            baselines[signature.id] = baseline(signature, usual: megabytes, spread: spread)
        }
        let context = RadarContext(baselines: baselines, recentIncidentCounts: incidents > 0 ? [signature.id: incidents] : [:],
                                   rules: [], systemPressure: pressure)
        var fresh = TrendWindow()
        return Fixture.scored([process], context: context, processorCount: cores, window: &fresh).first
    }

    /// The app at 2,560 MB against a usual 2,450, still climbing `rate` MB/min
    /// in a steady line over the last 160 s: a refill, or the start of a leak.
    private func climbing(rate: Double, pressure: SystemMemoryPressure) -> ProcessFamily? {
        var window = TrendWindow()
        var probeWindow = TrendWindow()
        guard let signature = Fixture.scored([chat()], window: &probeWindow).first?.signature else { return nil }
        let context = RadarContext(baselines: [signature.id: baseline(signature, usual: 2_450)], recentIncidentCounts: [:],
                                   rules: [], systemPressure: pressure)
        var last: ProcessFamily?
        for step in 0..<17 {
            let behind = Double(16 - step) * 10
            let date = Fixture.now.addingTimeInterval(-behind)
            let process = Fixture.process(pid: 11_850, name: "Claude", path: app, command: app,
                                          megabytes: 2_560 - behind * rate / 60, cpu: 3, date: date)
            last = Fixture.scored([process], context: context, window: &window, at: date).first
        }
        return last
    }

    func testABigAppAtItsUsualSizeIsWatchedNotHot() throws {
        XCTAssertEqual(try XCTUnwrap(score(chat(), usual: nil)).score.level, .hot, "unknown size: Hot, as before")
        let usual = try XCTUnwrap(score(chat(), usual: 2_450))
        XCTAssertEqual(usual.score.level, .watch)
        XCTAssertTrue(usual.score.heat.evidence.contains { $0.hasPrefix("Large, but normal for it") }, "\(usual.score.heat.evidence)")
    }

    /// Incidents recorded while its size was all it had kept it Hot, which
    /// recorded another incident: past incidents are context, not evidence.
    func testPastIncidentsDoNotKeepAUsualSizeHot() throws {
        let repeated = try XCTUnwrap(score(chat(), usual: 2_450, incidents: 4))
        XCTAssertTrue(repeated.score.components.contains { $0.kind == .recurrence && $0.level == .hot })
        XCTAssertEqual(repeated.score.level, .watch)
        XCTAssertTrue(repeated.hasOnlySizeAgainstIt, "learned, and not recorded as yet another incident")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score(chat(cpu: 900), usual: 2_450, incidents: 4)).score.level, .hot)
    }

    /// A family that swings widely is not far out by its spread, but is
    /// still well over its usual size: the evidence says so.
    func testBiggerThanUsualSaysByHowMuch() throws {
        let grown = try XCTUnwrap(score(chat(), usual: 1_500, spread: 600))
        XCTAssertEqual(grown.score.level, .hot)
        XCTAssertTrue(grown.score.heat.evidence.contains { $0.hasPrefix("Bigger than usual for it: 1.7x") },
                      "\(grown.score.heat.evidence)")
        let usual = try XCTUnwrap(score(chat(), usual: 2_450, spread: 600))
        XCTAssertFalse(usual.score.heat.evidence.contains { $0.hasPrefix("Bigger than usual") })
    }

    /// "Largest CPU on this Mac" only lends visibility: an app in use at
    /// half a core flipped between Watch and Hot with it. Its own CPU
    /// component, or the host signal at Hot, still counts.
    func testAHostWideCPUHintDoesNotMakeAUsualSizeHot() {
        func component(_ slot: String, _ kind: GhostScoreComponentKind, _ level: GhostLevel) -> GhostScoreComponent {
            GhostScoreComponent(slot: slot, kind: kind, title: slot, detail: "", impact: 10, level: level)
        }
        let big = [component("memory", .memory, .critical), component("hardware.memoryPressure.0", .memory, .critical)]
        XCTAssertTrue(ProcessFamily.componentsShowOnlySize(big + [component("hardware.cpuPressure.0", .cpu, .watch)]))
        XCTAssertFalse(ProcessFamily.componentsShowOnlySize(big + [component("hardware.cpuPressure.0", .cpu, .hot)]))
        XCTAssertFalse(ProcessFamily.componentsShowOnlySize(big + [component("cpu", .cpu, .watch)]))
        XCTAssertFalse(ProcessFamily.componentsShowOnlySize(big + [component("hardware.gpuPressure.0", .gpu, .hot)]))
    }

    /// 61% of one core is twenty times a chat app's usual 3%, but on a ten-core
    /// Mac it is a seventh of the CPU limit. Its Hot "baseline.cpu" component
    /// stopped a big app at its usual size from being read as normal, and made
    /// the sample an incident that was never learned.
    func testABurstOnABigMacDoesNotMakeAUsualSizeHot() throws {
        let burst = try XCTUnwrap(score(chat(cpu: 61), usual: 2_450, cores: 10))
        let anomaly = try XCTUnwrap(burst.score.components.first { $0.slot == "baseline.cpu" })
        XCTAssertEqual(anomaly.level, .watch, "still shown, at Watch")
        XCTAssertEqual(anomaly.title, "61% CPU vs about 3.0% normally", "and still honest about it")
        XCTAssertEqual(burst.score.level, .watch)
        XCTAssertTrue(burst.hasOnlySizeAgainstIt, "learned, and not recorded as an incident")
        XCTAssertTrue(burst.score.heat.evidence.contains { $0.hasPrefix("Large, but normal for it") }, "\(burst.score.heat.evidence)")
    }

    /// Half the core-aware family limit is where a baseline CPU burst counts as Hot.
    func testABaselineCPUBurstIsHotOnlyFromHalfTheFamilyLimit() throws {
        let twoCores = try XCTUnwrap(score(chat(cpu: 61), usual: 2_450, cores: 2))
        XCTAssertEqual(twoCores.score.components.first { $0.slot == "baseline.cpu" }?.level, .hot, "61 of a 90% limit")
        XCTAssertGreaterThanOrEqual(twoCores.score.level, .hot)

        let tenCores = try XCTUnwrap(score(chat(cpu: 300), usual: 2_450, cores: 10))
        XCTAssertEqual(tenCores.score.components.first { $0.slot == "baseline.cpu" }?.level, .hot, "300 of a 450% limit")
        XCTAssertGreaterThanOrEqual(tenCores.score.level, .hot)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score(chat(cpu: 900), usual: 2_450, cores: 10)).score.level, .hot)
    }

    func testTwiceItsUsualSizeOrBusyStaysHotWhateverTheMacIsShortOf() throws {
        XCTAssertEqual(try XCTUnwrap(score(chat(), usual: 1_200)).score.level, .hot)
        let busy = try XCTUnwrap(score(chat(cpu: 900), usual: 2_450))
        XCTAssertGreaterThanOrEqual(busy.score.level, .hot)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score(chat(), usual: 1_200, pressure: squeezed)).score.level, .hot,
                                    "twice its usual size is its own doing, whatever the Mac is short of")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score(chat(cpu: 900), usual: 2_450, pressure: squeezed)).score.level, .hot)
    }

    /// The Mac being short of memory is a fact about the Mac: a big app at
    /// its usual size is not the problem for being big, and is not an
    /// incident, unlearnable or a reason to scan faster.
    func testAUsualSizeIsWatchedWhileTheMacIsShortOfMemory() throws {
        let family = try XCTUnwrap(score(chat(), usual: 2_450, pressure: squeezed))
        XCTAssertEqual(family.score.level, .watch)
        XCTAssertTrue(family.hasOnlySizeAgainstIt, "learned, and not recorded as an incident")
        XCTAssertEqual(RadarScheduler.schedulingLevel([family]), .quiet, "and no reason to scan faster")
        XCTAssertTrue(family.isWatchedForSizeOnly)

        let evidence = family.score.heat.evidence
        XCTAssertTrue(evidence.contains { $0.hasPrefix("Large, but normal for it") && $0.contains("the Mac is short of memory") }, "\(evidence)")
        XCTAssertTrue(evidence.contains { $0.hasPrefix("Host memory pressure is warning") }, "the pressure is still said: \(evidence)")
        XCTAssertTrue(family.score.components.contains { $0.slot == "pressure" }, "and still shown")

        let calm = try XCTUnwrap(score(chat(), usual: 2_450))
        XCTAssertFalse(calm.score.heat.evidence.contains { $0.contains("short of memory") }, "no note when the Mac is fine")
    }

    /// Only at or near its usual size: a family 1.16x its usual is within its
    /// spread, and Watch on a Mac with memory to spare, but under Warning the
    /// extra is its own and it stays Hot, an incident and worth scanning for.
    func testUnderWarningOnlyAtOrNearItsUsualSizeIsWatched() throws {
        let nearUsual = try XCTUnwrap(score(chat(), usual: 2_330, pressure: squeezed, spread: 600))
        XCTAssertEqual(nearUsual.score.level, .watch, "1.10x its usual")

        let bigger = try XCTUnwrap(score(chat(), usual: 2_200, pressure: squeezed, spread: 600))
        XCTAssertGreaterThanOrEqual(bigger.score.level, .hot, "1.16x its usual")
        XCTAssertFalse(bigger.hasOnlySizeAgainstIt, "the Mac's memory still counts against it")
        XCTAssertFalse(bigger.score.heat.evidence.contains { $0.hasPrefix("Large, but normal for it") }, "\(bigger.score.heat.evidence)")
        XCTAssertGreaterThanOrEqual(RadarScheduler.schedulingLevel([bigger]), .hot)
        XCTAssertEqual(try XCTUnwrap(score(chat(), usual: 2_200, spread: 600)).score.level, .watch, "Watch when the Mac has memory to spare")

        let smaller = try XCTUnwrap(score(chat(), usual: 3_100, pressure: squeezed, spread: 600))
        XCTAssertEqual(smaller.score.level, .watch, "smaller than usual, as Claude at 1.7 GB against 2.5 GB")
    }

    /// Critical pressure keeps a big family Hot, an incident and worth
    /// scanning for, however usual its size.
    func testCriticalPressureStillKeepsAUsualSizeHot() throws {
        let family = try XCTUnwrap(score(chat(), usual: 2_450, pressure: starved))
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        XCTAssertFalse(family.hasOnlySizeAgainstIt, "the critical pressure counts against it, so it is an incident")
        XCTAssertGreaterThanOrEqual(RadarScheduler.schedulingLevel([family]), .hot)
        XCTAssertFalse(family.score.heat.evidence.contains { $0.hasPrefix("Large, but normal for it") }, "\(family.score.heat.evidence)")
    }

    /// A slow refill is not the family driving the pressure; real growth is,
    /// and stays Hot.
    func testUnderWarningASlowRefillIsWatchedAndRealGrowthIsNot() throws {
        let refill = try XCTUnwrap(climbing(rate: 12, pressure: squeezed))
        XCTAssertGreaterThan(refill.trend.credibleMemoryVelocity, 5, "a trusted climb")
        XCTAssertEqual(refill.score.level, .watch)
        XCTAssertEqual(refill.score.heat.corroborationCount, 0, "a trickle does not vote")

        let leak = try XCTUnwrap(climbing(rate: 60, pressure: squeezed))
        XCTAssertGreaterThanOrEqual(leak.score.level, .hot)
        XCTAssertFalse(leak.hasOnlySizeAgainstIt)
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

    func testBeingBigDoesNotSpeedUpScanning() {
        XCTAssertEqual(RadarScheduler.schedulingLevel([bigOnly(at: 0)]), .quiet)
        XCTAssertEqual(RadarScheduler.schedulingLevel([bigOnly(at: 0), bigOnly(leaking: true, at: 0)]), .hot)
    }
}
