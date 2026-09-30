import XCTest
@testable import GhostProcessSniperCore

/// Twenty seconds of clean climb on an app that had been running for half an
/// hour (the Simulator, booting a device) was called Urgent "Sustained memory
/// growth" before Ghost had watched it for half a minute. A slope that short
/// is worth drawing and watching; a leak is one that keeps climbing past a minute.
final class SustainedGrowthTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    /// Scans four seconds apart on one window, climbing 400 MB/min from `base`,
    /// on a process started half an hour ago; returns the family after each scan.
    private func climb(scans: Int, base: Double = 300) -> [ProcessFamily] {
        var window = TrendWindow()
        let started = Fixture.now.addingTimeInterval(-1_800)
        return (0..<scans).compactMap { step in
            let date = Fixture.now.addingTimeInterval(Double(step - scans + 1) * 4)
            let process = Fixture.process(megabytes: base + Double(step) * 400 * 4 / 60, started: started, date: date)
            return Fixture.scored([process], window: &window, at: date).first
        }
    }

    func testTwentySecondsOfClimbIsWatchedNotCalledALeak() throws {
        let family = try XCTUnwrap(climb(scans: 6).last)
        XCTAssertEqual(family.trend.observedSeconds, 20, accuracy: 0.5)
        XCTAssertEqual(family.trend.credibleMemoryVelocity, 400, accuracy: 10, "the slope is real and still drawn")
        XCTAssertEqual(family.score.level, .watch)
        XCTAssertEqual(family.score.heat.sustainedSignalCount, 0)
        XCTAssertFalse(family.score.heat.shouldNotify)
        XCTAssertFalse(family.score.heat.shouldRaiseLiveAlert)
        XCTAssertLessThan(family.forecast.state, .leaking)
        XCTAssertFalse(family.hasCredibleLeak)
        XCTAssertNotEqual(ProcessAssessment(family: family).cause, "Sustained memory growth")
        XCTAssertTrue(family.score.heat.evidence.contains("Memory is rising, but the trend still needs confirmation"),
                      "\(family.score.heat.evidence)")
    }

    /// The same climb, kept up, escalates on the same window once a minute of it is seen.
    func testTheClimbEscalatesOnceItHasLastedAMinute() throws {
        let scans = climb(scans: 16)
        let firstLeak = try XCTUnwrap(scans.firstIndex { $0.hasCredibleLeak }, "a minute of 400 MB/min is a leak")
        XCTAssertGreaterThanOrEqual(scans[firstLeak].trend.observedSeconds, TrendMetrics.sustainedGrowthSeconds)
        let last = try XCTUnwrap(scans.last)
        XCTAssertEqual(last.score.level, .critical)
        XCTAssertGreaterThanOrEqual(last.forecast.state, .leaking)
        XCTAssertEqual(ProcessAssessment(family: last).cause, "Sustained memory growth")
    }

    /// A big app over its limit is Hot for its size at once; the growth claims still wait.
    func testABigAppIsHotForItsSizeButNotALeakYet() throws {
        let family = try XCTUnwrap(climb(scans: 6, base: 1_600).last)
        XCTAssertGreaterThanOrEqual(family.score.level, .hot)
        let leak = try XCTUnwrap(family.score.components.first { $0.kind == .leak && $0.slot == "leak" })
        XCTAssertLessThanOrEqual(leak.level, .watch)
        XCTAssertFalse(family.hasCredibleLeak)
        XCTAssertNotEqual(ProcessAssessment(family: family).cause, "Sustained memory growth")
    }

    /// Same slope and fit, twenty seconds against a minute: only the span differs.
    func testTheHeatModelNeedsAMinuteForASustainedLeak() {
        func heat(samples: Int) -> GhostHeat {
            let trend = Fixture.trend(megabytes: (0..<samples).map { 300 + Double($0) * 400 * 4 / 60 }, cadence: 4)
            return GhostHeatModel.initial(memoryRatio: 0.4, cpuRatio: 0, cpuThreshold: 90, gpuRatio: 0, leakRatio: 3,
                                          trend: trend, hardwareLevel: .quiet)
        }
        let short = heat(samples: 6)
        XCTAssertEqual(short.sustainedSignalCount, 0)
        XCTAssertLessThan(short.level, .critical)
        let long = heat(samples: 16)
        XCTAssertEqual(long.sustainedSignalCount, 1)
        XCTAssertEqual(long.level, .critical)
    }

    func testTheGateIsAMinuteOfDatedHistory() {
        XCTAssertFalse(Fixture.trend(megabytes: Array(repeating: 300, count: 12), cadence: 5).growthIsSustained, "55 s")
        XCTAssertTrue(Fixture.trend(megabytes: Array(repeating: 300, count: 13), cadence: 5).growthIsSustained, "60 s")
        XCTAssertFalse(Fixture.trend(megabytes: [300, 310, 320], cadence: 60).growthIsSustained, "too few samples")
        let handBuilt = TrendMetrics(memoryVelocityMegabytesPerMinute: 400, cpuSlopePerMinute: 0, memoryPoints: [1, 2, 3, 4])
        XCTAssertTrue(handBuilt.growthIsSustained, "undated metrics are trusted, as hasSustainedHistory trusts them")
    }
}

/// Another tool's xcodebuild, one swift-frontend job climbing 535 MB/min for
/// ninety seconds, was Urgent "Sustained memory growth" with a Stop Build
/// button. A compile job gives its memory back when it exits: its climb is
/// the work. Size still counts, and a squeezed Mac still says so.
final class BuildMemoryTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    /// 23 scans four seconds apart (88 s), 535 MB/min from 2 GB, started half an hour ago.
    private func climbing(name: String, path: String, command: String? = nil, cpu: Double = 96) throws -> ProcessFamily {
        var window = TrendWindow()
        var family: ProcessFamily?
        let started = Fixture.now.addingTimeInterval(-1_800)
        for step in 0..<23 {
            let date = Fixture.now.addingTimeInterval(Double(step - 22) * 4)
            let process = Fixture.process(name: name, path: path, command: command ?? name,
                                          megabytes: 2_000 + Double(step) * 535 * 4 / 60, cpu: cpu, started: started, date: date)
            family = Fixture.scored([process], window: &window, at: date).first
        }
        return try XCTUnwrap(family)
    }

    private let xcodebuild = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

    func testABuildClimbingIsHotForItsSizeNotALeak() throws {
        let build = try climbing(name: "xcodebuild", path: xcodebuild)
        XCTAssertTrue(build.isOneShotBuild)
        XCTAssertEqual(build.trend.credibleMemoryVelocity, 535, accuracy: 15, "the climb is still measured")
        XCTAssertEqual(build.score.level, .hot, "2.7 GB is over its limit: worth a look, not urgent")
        XCTAssertEqual(build.score.heat.sustainedSignalCount, 0)
        XCTAssertFalse(build.hasCredibleLeak)
        XCTAssertLessThan(build.forecast.state, .leaking)
        XCTAssertTrue(build.score.heat.evidence.contains(GhostHeat.buildMemoryEvidence), "\(build.score.heat.evidence)")
        XCTAssertTrue(build.forecast.whyNow.contains("returns its memory when it ends"), build.forecast.whyNow)
        XCTAssertNotEqual(ProcessAssessment(family: build).cause, "Sustained memory growth")
    }

    /// The same climb in anything that stays up is a leak.
    func testTheSameClimbInAServiceIsALeak() throws {
        let server = try climbing(name: "node", path: "/usr/local/bin/node", command: "node server.js")
        XCTAssertFalse(server.isOneShotBuild)
        XCTAssertEqual(server.score.level, .critical)
        XCTAssertTrue(server.hasCredibleLeak)
        XCTAssertEqual(ProcessAssessment(family: server).cause, "Sustained memory growth")
    }

    /// A watcher rebuilds for the whole session, so it can leak like a service.
    func testABuildWatcherCanStillLeak() throws {
        let watcher = try climbing(name: "cargo-watch", path: "/Users/dev/.cargo/bin/cargo-watch", command: "cargo-watch -x build")
        XCTAssertEqual(watcher.classification?.kind, .buildWatcher)
        XCTAssertFalse(watcher.isOneShotBuild)
        XCTAssertTrue(watcher.hasCredibleLeak)
    }

    func testOnlyBuildsThatEndByThemselvesAreOneShot() {
        XCTAssertTrue(DevClassification(kind: .swiftBuild, confidence: 1, reason: "", traits: .buildOrTest).isOneShotBuild)
        XCTAssertTrue(DevClassification(kind: .testRunner, confidence: 1, reason: "", traits: .buildOrTest).isOneShotBuild)
        XCTAssertFalse(DevClassification(kind: .buildWatcher, confidence: 1, reason: "", traits: [.buildOrTest, .longLived]).isOneShotBuild)
        XCTAssertFalse(DevClassification(kind: .nodeServer, confidence: 1, reason: "", traits: [.devServer, .longLived]).isOneShotBuild)
    }
}

/// "Memory and CPU accelerating" is a leak-kind component at Hot, so it made
/// a family a credible leak on its own: twenty seconds in, or while it launched.
final class AccelerationGateTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    /// A node server with a trusted 300 MB baseline, climbing 200 MB/min with
    /// CPU rising 60 points a minute, for `samples` scans five seconds apart.
    private func accelerating(samples: Int, startedSecondsAgo: TimeInterval = 3_600) -> ProcessFamily {
        let megabytes = (0..<samples).map { 300 + Double($0) * 200 * 5 / 60 }
        let cpu = (0..<samples).map { 10 + Double($0) * 60 * 5 / 60 }
        let root = Fixture.process(megabytes: megabytes.last ?? 300, cpu: cpu.last ?? 10,
                                   started: Fixture.now.addingTimeInterval(-startedSecondsAgo))
        let family = Fixture.family(root, trend: Fixture.trend(megabytes: megabytes, cpu: cpu))
        let baseline = FamilyBaseline(
            signature: family.signature, sampleCount: 40, meanMemoryBytes: Double(300 * Fixture.mib),
            peakMemoryBytes: 320 * Fixture.mib, meanCPUPercent: 10, peakCPUPercent: 20,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: Fixture.now.addingTimeInterval(-7_200), lastSeenAt: Fixture.now,
            memoryVariance: pow(Double(20 * Fixture.mib), 2), cpuVariance: 25
        )
        let context = RadarContext(baselines: [family.signature.id: baseline], recentIncidentCounts: [:], rules: [])
        return RadarIntelligence().enrich(family: family, context: context, settings: .smart, now: Fixture.now)
    }

    func testAccelerationNeedsAMinuteOfGrowthPastALaunch() {
        func hasAcceleration(_ family: ProcessFamily) -> Bool { family.score.components.contains { $0.slot == "acceleration" } }
        XCTAssertTrue(hasAcceleration(accelerating(samples: 13)), "a minute of it, an hour after launch")
        XCTAssertFalse(hasAcceleration(accelerating(samples: 5)), "twenty seconds")
        XCTAssertFalse(hasAcceleration(accelerating(samples: 13, startedSecondsAgo: 100)), "inside startup grace")
    }
}
