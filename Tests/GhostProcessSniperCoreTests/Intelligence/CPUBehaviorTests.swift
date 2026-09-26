import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Minutes of CPU through the real pipeline and activity ledger, on a Mac
/// with a fixed core count.
final class CPUBehaviorTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private static let cadence: TimeInterval = 3

    /// One running process whose CPU clock advances with `cpu`.
    private final class Clock {
        var seconds: [Int32: TimeInterval] = [:]

        func advance(_ pid: Int32, cpu: Double) -> TimeInterval {
            seconds[pid, default: 0] += cpu / 100 * CPUBehaviorTests.cadence
            return seconds[pid, default: 0]
        }
    }

    private func process(_ pid: Int32, parent: Int32 = 1, name: String, path: String, command: String, cpu: Double,
                         clock: Clock, at date: Date) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 40_000, startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "dev", name: name, executablePath: path, commandLine: command,
            residentMemoryBytes: 200 * Fixture.mib, physicalFootprintBytes: 200 * Fixture.mib, virtualMemoryBytes: 400 * Fixture.mib,
            cpuPercent: cpu, totalProcessorSeconds: clock.advance(pid, cpu: cpu), threadCount: 8, isSystemProcess: false,
            sampledAt: date
        )
    }

    private func run(
        minutes: Double,
        cores: Int = 8,
        context: RadarContext = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: []),
        world: (Int, Date, Clock) -> [ProcessMetrics]
    ) -> [ProcessFamily] {
        var pipeline = RadarPipeline(
            builder: ProcessFamilyBuilder(currentUserID: 501, processorCount: cores),
            intelligence: RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: cores))
        )
        let clock = Clock()
        let ticks = Int(minutes * 60 / Self.cadence)
        let start = Fixture.now.addingTimeInterval(-Double(ticks) * Self.cadence)
        var families: [ProcessFamily] = []
        for tick in 0...ticks {
            let date = start.addingTimeInterval(Double(tick) * Self.cadence)
            families = pipeline.run(processes: world(tick, date, clock), settings: .smart, context: context, now: date).families
        }
        return families
    }

    func testChurningBuildAt700PercentIsNotRunaway() throws {
        let toolchain = "/Applications/Xcode.app/Contents/Developer/usr/bin"
        let families = run(minutes: 3) { tick, date, clock in
            let build = self.process(100, name: "xcodebuild", path: "\(toolchain)/xcodebuild", command: "xcodebuild -scheme App build",
                                     cpu: 40, clock: clock, at: date)
            // Compiler jobs come and go every few seconds.
            let jobs = (0..<6).map { index in
                self.process(Int32(1_000 + tick * 6 + index), parent: 100, name: "clang", path: "/usr/bin/clang",
                             command: "clang -c File\(tick * 6 + index).c", cpu: 110, clock: clock, at: date)
            }
            return [build] + jobs
        }
        let build = try XCTUnwrap(families.first { $0.root.pid == 100 })
        XCTAssertGreaterThan(build.totalCPUPercent, 600)
        XCTAssertNotEqual(build.forecast.state, .runaway)
        XCTAssertLessThan(build.score.level, .critical)
        XCTAssertEqual(build.forecast.cpuBehavior?.kind, .expectedBurst)
        XCTAssertEqual(build.forecast.recommendedAction.title, "Let it finish")
    }

    func testSingleCoreBusyLoopIsRunaway() throws {
        var jitter = Fixture.Jitter(seed: 3)
        let families = run(minutes: 3.5) { _, date, clock in
            [self.process(200, name: "node", path: "/usr/local/bin/node", command: "node /Users/dev/scripts/poll.js",
                          cpu: 99 + jitter.next(amplitude: 1), clock: clock, at: date)]
        }
        let spinner = try XCTUnwrap(families.first)
        XCTAssertEqual(spinner.forecast.cpuBehavior?.kind, .spin)
        XCTAssertEqual(spinner.forecast.state, .runaway)
        XCTAssertTrue(spinner.forecast.whyNow.contains("busy-looping on one core"), spinner.forecast.whyNow)
    }

    func testIdleLanguageServerBurningCPUIsFlagged() throws {
        let path = "/Users/dev/.vscode/extensions/rust-lang.rust-analyzer/server/rust-analyzer"
        let probe = process(300, name: "rust-analyzer", path: path, command: path, cpu: 0, clock: Clock(), at: Fixture.now)
        let signature = ProcessSignature.from(root: probe)
        let baseline = FamilyBaseline(signature: signature, sampleCount: 400, meanMemoryBytes: Double(200 * Fixture.mib),
                                      peakMemoryBytes: 220 * Fixture.mib, meanCPUPercent: 0.5, peakCPUPercent: 4,
                                      meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0, firstSeenAt: Fixture.now.addingTimeInterval(-86_400),
                                      lastSeenAt: Fixture.now, cpuVariance: 1, observedSeconds: 7_200)
        let context = RadarContext(baselines: [signature.id: baseline], recentIncidentCounts: [:], rules: [])
        var jitter = Fixture.Jitter(seed: 5)
        let families = run(minutes: 7, context: context) { _, date, clock in
            [self.process(300, name: "rust-analyzer", path: path, command: path, cpu: 40 + jitter.next(amplitude: 8), clock: clock, at: date)]
        }
        let server = try XCTUnwrap(families.first)
        XCTAssertEqual(server.forecast.cpuBehavior?.kind, .idleServiceBurning)
        XCTAssertNotEqual(server.forecast.state, .runaway)
        XCTAssertGreaterThan(server.score.heat.sustainedSignalCount, 0)
        XCTAssertTrue(server.score.heat.evidence.contains { $0.hasPrefix("Burning") }, "\(server.score.heat.evidence)")
    }

    func testSaturatingEveryCoreIsAtLeastHot() throws {
        let families = run(minutes: 4, cores: 12) { _, date, clock in
            let root = self.process(400, name: "python3", path: "/opt/homebrew/bin/python3", command: "python3 -m pipeline.main",
                                    cpu: 1, clock: clock, at: date)
            let workers = (0..<12).map { index in
                self.process(Int32(401 + index), parent: 400, name: "python3", path: "/opt/homebrew/bin/python3",
                             command: "python3 -m pipeline.worker", cpu: 70, clock: clock, at: date)
            }
            return [root] + workers
        }
        let pool = try XCTUnwrap(families.first { $0.root.pid == 400 })
        XCTAssertEqual(pool.forecast.cpuBehavior?.kind, .machineSaturation)
        XCTAssertGreaterThanOrEqual(pool.score.level, .hot)
        XCTAssertEqual(pool.forecast.cpuBehavior?.machineShare ?? 0, 0.7, accuracy: 0.05)
    }

    func testLedgerBucketsCPUByMinuteWhateverTheCadence() {
        var ledger = ActivityLedger()
        let clock = Clock()
        var activity = FamilyCPUActivity.empty
        let start = Date(timeIntervalSince1970: 60_000)
        for tick in 0..<60 {
            let date = start.addingTimeInterval(Double(tick) * Self.cadence)
            let worker = process(500, name: "tool", path: "/usr/local/bin/tool", command: "tool", cpu: 50, clock: clock, at: date)
            ledger.recordProcesses([worker], now: date)
            activity = ledger.recordFamily(key: "tool", members: [worker], now: date)
        }
        let finished = activity.recentMinutes
        XCTAssertEqual(finished.count, 2)
        for minute in finished {
            XCTAssertEqual(minute.cores, 0.5, accuracy: 0.05)
        }
        XCTAssertEqual(activity.lastActiveAt, start.addingTimeInterval(59 * Self.cadence))
    }

    /// A member outside the rich-read budget, read fresh every three minutes,
    /// must not pile three minutes of CPU into the minute of its read.
    func testSparseReadsSpreadOverTheMinutesTheyCover() throws {
        var ledger = ActivityLedger()
        let clock = Clock()
        var activity = FamilyCPUActivity.empty
        let start = Date(timeIntervalSince1970: 60_000)
        var lastRead = start
        for tick in 0..<200 {
            let date = start.addingTimeInterval(Double(tick) * Self.cadence)
            let read = process(510, name: "tool", path: "/usr/local/bin/tool", command: "tool", cpu: 100, clock: clock, at: date)
            let fresh = tick % 60 == 0
            if fresh { lastRead = date }
            let worker = ProcessMetrics(
                identity: read.identity, parentPID: read.parentPID, userID: read.userID, ownerName: read.ownerName, name: read.name,
                executablePath: read.executablePath, commandLine: read.commandLine, residentMemoryBytes: read.residentMemoryBytes,
                physicalFootprintBytes: read.physicalFootprintBytes, virtualMemoryBytes: read.virtualMemoryBytes, cpuPercent: 100,
                totalProcessorSeconds: read.totalProcessorSeconds, threadCount: read.threadCount, isSystemProcess: false,
                sampledAt: date, cpuMeasurementStatus: fresh ? .fresh : .cached(lastRead)
            )
            ledger.recordProcesses([worker], now: date)
            activity = ledger.recordFamily(key: "tool", members: [worker], now: date)
        }
        let finished = activity.recentMinutes
        XCTAssertGreaterThanOrEqual(finished.count, 8)
        XCTAssertLessThanOrEqual(try XCTUnwrap(finished.map(\.cores).max()), 1.1)
        // Minutes a read covered hold one busy core; nothing was lost.
        XCTAssertEqual(finished.dropFirst(3).first?.cores ?? 0, 1, accuracy: 0.05)
    }

    /// After the Mac sleeps, the first read spans the whole nap; only the
    /// part inside the minute being observed lands in it.
    func testReadAfterSleepDoesNotPileIntoOneMinute() {
        var ledger = ActivityLedger()
        let start = Date(timeIntervalSince1970: 60_000)
        let asleep = start.addingTimeInterval(20 * 60)
        var activity = FamilyCPUActivity.empty
        for (date, seconds) in [(start, 0.0), (asleep, 600.0)] + (1..<20).map({ (asleep.addingTimeInterval(Double($0) * 3), 600 + Double($0) * 1.5) }) {
            let worker = ProcessMetrics(
                identity: ProcessIdentity(pid: 520, startTimeSeconds: 40_000, startTimeMicroseconds: 0), parentPID: 1, userID: 501,
                ownerName: "dev", name: "tool", executablePath: "/usr/local/bin/tool", commandLine: "tool",
                residentMemoryBytes: 0, physicalFootprintBytes: 0, virtualMemoryBytes: 0, cpuPercent: 50,
                totalProcessorSeconds: seconds, threadCount: 1, isSystemProcess: false, sampledAt: date
            )
            ledger.recordProcesses([worker], now: date)
            activity = ledger.recordFamily(key: "tool", members: [worker], now: date)
        }
        let current = activity.buckets.last
        XCTAssertLessThanOrEqual(current?.cores ?? 0, 0.6)
    }
}
