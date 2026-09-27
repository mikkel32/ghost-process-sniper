import XCTest
@testable import GhostProcessSniperCore

/// Idleness is measured in time the radar observed: a night's sleep is not
/// a night of doing nothing.
final class SleepIdlenessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 500_000)

    private func worker(cpuSeconds: Double, at date: Date) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: 700, startTimeSeconds: 400_000, startTimeMicroseconds: 0), parentPID: 1,
            userID: 501, ownerName: "dev", name: "vite", executablePath: "/usr/local/bin/node",
            commandLine: "node vite", residentMemoryBytes: 0, physicalFootprintBytes: 0, virtualMemoryBytes: 0,
            cpuPercent: 0, totalProcessorSeconds: cpuSeconds, threadCount: 4, isSystemProcess: false, sampledAt: date)
    }

    /// Busy for ten minutes, quiet for `quiet` seconds, then `gap` seconds without a scan, then two quiet scans.
    private func idleness(quiet: TimeInterval, gap: TimeInterval) -> TimeInterval? {
        var ledger = ActivityLedger()
        var activity = FamilyCPUActivity.empty
        var cpu = 0.0
        var date = start
        func scan() {
            ledger.recordProcesses([worker(cpuSeconds: cpu, at: date)], now: date)
            activity = ledger.recordFamily(key: "vite", members: [worker(cpuSeconds: cpu, at: date)], now: date)
        }
        for _ in 0..<200 {
            cpu += 1.5
            scan()
            date += 3
        }
        for _ in 0..<Int(quiet / 3) {
            scan()
            date += 3
        }
        date += gap
        scan()
        date += 3
        scan()
        return activity.idleSeconds(at: date)
    }

    func testANightsSleepIsNotIdleTime() throws {
        let idle = try XCTUnwrap(idleness(quiet: 120, gap: 8 * 3_600))
        XCTAssertLessThan(idle, 5 * 60, "two quiet minutes before sleep, not eight hours")
    }

    func testAShortGapStillCounts() throws {
        let idle = try XCTUnwrap(idleness(quiet: 120, gap: 4 * 60))
        XCTAssertGreaterThan(idle, 6 * 60)
    }

    func testAJobUsedJustBeforeSleepIsNotForgottenOnWaking() {
        var ledger = ActivityLedger()
        ledger.recordProcesses([worker(cpuSeconds: 0, at: start)], now: start)
        let woke = start.addingTimeInterval(9 * 3_600)
        ledger.recordProcesses([worker(cpuSeconds: 0, at: woke)], now: woke)
        let activity = ledger.recordFamily(key: "vite", members: [worker(cpuSeconds: 0, at: woke)], now: woke)
        let assessment = ForgottenProcessAssessor.assess(
            root: worker(cpuSeconds: 0, at: woke), context: .terminalBackground, activity: activity,
            forensics: .unavailable(reason: "test"), workingDirectoryMissing: false, now: woke)
        XCTAssertFalse(assessment.facts.contains { $0.hasPrefix("no CPU use") })
    }
}

/// A leak's rate is per minute awake: memory does not move while the Mac sleeps.
final class SleepTrendTests: XCTestCase {
    private func leaking(_ megabytes: Double, at date: Date) -> ProcessMetrics {
        IntelligenceFixture.process(pid: 710, name: "node", megabytes: megabytes, started: Date(timeIntervalSince1970: 1_000),
                                    date: date)
    }

    func testALeakKeepsItsRateAcrossASleep() {
        var store = MemberTrendStore()
        var date = Date(timeIntervalSince1970: 3_000_000)
        var megabytes = 400.0
        var step = FamilyTrendStep(total: 0, historyShift: 0, newestMeasurement: nil, longTerm: .none)
        func tick() {
            step = store.advance(familyKey: "node", members: [leaking(megabytes, at: date)], now: date)
            date += 20
            megabytes += 8.0 / 3
        }
        for _ in 0..<(70 * 3) { tick() }
        XCTAssertTrue(step.longTerm.isSlowLeak(physicalMemoryBytes: 16 << 30))
        date += 8 * 3_600
        var spans: [Double] = []
        for index in 0..<(45 * 3) {
            tick()
            if index % 15 == 14 {
                spans.append(step.longTerm.spanMinutes)
                XCTAssertEqual(step.longTerm.slopeMegabytesPerMinute, 8, accuracy: 1.5, "\(index / 3) min after waking")
                XCTAssertTrue(step.longTerm.isSlowLeak(physicalMemoryBytes: 16 << 30), "\(index / 3) min after waking")
            }
        }
        XCTAssertLessThanOrEqual(spans.max() ?? 0, 90, "the span counts minutes awake, not the night")
    }
}
