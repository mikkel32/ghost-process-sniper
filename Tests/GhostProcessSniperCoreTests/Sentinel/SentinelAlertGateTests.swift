import XCTest
@testable import GhostProcessSniperCore

/// One notification per new thing: a program that restarts or runs many
/// workers for the same reason must not alert once per process.
final class SentinelAlertGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func finding(pid: Int32, path: String = "/tmp/.x/agent", kind: SentinelSignalKind = .temporaryLocation,
                         severity: SentinelSeverity = .suspicious, running: Bool = true) -> SentinelFinding {
        SentinelFinding(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: UInt64(pid)),
            name: (path as NSString).lastPathComponent, executablePath: path, commandLine: path, lineage: [],
            signals: [SentinelSignal(kind, severity, "evidence")], headline: "headline", recommendation: "",
            firstSeen: now, lastSeen: now, isRunning: running, signing: nil, downloadedFrom: [])
    }

    private func item(_ label: String, isNew: Bool) -> LaunchItem {
        let path = "/Users/me/Library/LaunchAgents/\(label).plist"
        return LaunchItem(id: path, plistPath: path, label: label, scope: .userAgent, programPath: "/usr/bin/true",
                          arguments: ["/usr/bin/true"], runsAtLoad: true, keepsAlive: false, modified: nil, isNew: isNew,
                          signals: [], signing: nil)
    }

    func testSameProgramRestartingForTheSameReasonAlertsOncePerDay() {
        var gate = SentinelAlertGate()
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [finding(pid: 10)]), now: now).findings.count, 1)
        // The first process exits and the same program starts again, and again.
        for (offset, pid) in [11, 12, 13].enumerated() {
            let later = now.addingTimeInterval(Double(offset + 1) * 600)
            XCTAssertTrue(gate.alerts(for: SentinelReport(findings: [finding(pid: Int32(pid))]), now: later).findings.isEmpty)
        }
        let nextDay = now.addingTimeInterval(SentinelAlertGate.cooldown + 1)
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [finding(pid: 14)]), now: nextDay).findings.count, 1)
    }

    func testAGenuinelyNewThingStillAlerts() {
        var gate = SentinelAlertGate()
        _ = gate.alerts(for: SentinelReport(findings: [finding(pid: 20)]), now: now)
        let other = finding(pid: 21, path: "/Users/Shared/.u/agent", kind: .hiddenLocation)
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [other]), now: now).findings.map(\.id), [other.id])
        let differentReason = finding(pid: 22, kind: .reverseShell, severity: .dangerous)
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [differentReason]), now: now).findings.count, 1)
    }

    func testAFindingThatTurnsDangerousAlertsAgain() {
        var gate = SentinelAlertGate()
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [finding(pid: 30)]), now: now).findings.count, 1)
        XCTAssertTrue(gate.alerts(for: SentinelReport(findings: [finding(pid: 30)]), now: now).findings.isEmpty)
        let worse = finding(pid: 30, severity: .dangerous)
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [worse]), now: now).findings.count, 1)
    }

    func testQuietOrExitedSuspiciousFindingsNeverAlert() {
        var gate = SentinelAlertGate()
        let report = SentinelReport(findings: [finding(pid: 40, severity: .notable), finding(pid: 41, running: false)])
        XCTAssertTrue(gate.alerts(for: report, now: now).findings.isEmpty)
    }

    /// The spawn watcher exists for commands that finish before the next scan: a Dangerous one that already
    /// exited when the report reached the gate is the case that must not be silent.
    func testADangerousFindingThatAlreadyExitedStillAlertsOnce() {
        var gate = SentinelAlertGate()
        let exited = finding(pid: 60, kind: .reverseShell, severity: .dangerous, running: false)
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [exited]), now: now).findings.map(\.id), [exited.id])
        XCTAssertTrue(gate.alerts(for: SentinelReport(findings: [exited]), now: now).findings.isEmpty)
        let sameAgain = finding(pid: 61, kind: .reverseShell, severity: .dangerous, running: false)
        XCTAssertTrue(gate.alerts(for: SentinelReport(findings: [sameAgain]), now: now.addingTimeInterval(600)).findings.isEmpty,
                      "the same program for the same reason stays quiet for a day")
    }

    func testADangerousFindingThatExitsAfterAlertingDoesNotAlertTwice() {
        var gate = SentinelAlertGate()
        XCTAssertEqual(gate.alerts(for: SentinelReport(findings: [finding(pid: 62, severity: .dangerous)]), now: now).findings.count, 1)
        let exited = finding(pid: 62, severity: .dangerous, running: false)
        XCTAssertTrue(gate.alerts(for: SentinelReport(findings: [exited]), now: now.addingTimeInterval(1)).findings.isEmpty)
    }

    func testAReportCountsDangerousFindingsThatAlreadyExited() {
        let report = SentinelReport(findings: [
            finding(pid: 70, severity: .dangerous, running: false), finding(pid: 71, severity: .dangerous),
            finding(pid: 72, severity: .suspicious, running: false),
        ])
        XCTAssertEqual(report.exitedDangerousCount, 1)
        XCTAssertEqual(report.activeFindingCount, 1, "only the running one is live")
        let quiet = SentinelReport(findings: [finding(pid: 73, severity: .dangerous, running: false)])
        XCTAssertNil(quiet.highestSeverity, "the live level stays running-only")
        XCTAssertEqual(quiet.exitedDangerousCount, 1)
    }

    func testRememberedIDsArePrunedToTheCurrentReport() {
        var gate = SentinelAlertGate()
        for pid in 50..<250 {
            let path = "/tmp/.x/agent\(pid)"
            _ = gate.alerts(for: SentinelReport(findings: [finding(pid: Int32(pid), path: path)]), now: now)
        }
        XCTAssertEqual(gate.rememberedIDCount, 1, "only IDs still in the report are kept")
        _ = gate.alerts(for: .empty, now: now)
        XCTAssertEqual(gate.rememberedIDCount, 0)
    }

    func testNewStartupItemAlertsOnceAndKnownOnesNever() {
        var gate = SentinelAlertGate()
        let report = SentinelReport(launchItems: [item("com.example.old", isNew: false), item("com.example.new", isNew: true)])
        XCTAssertEqual(gate.alerts(for: report, now: now).startupItems.map(\.label), ["com.example.new"])
        XCTAssertTrue(gate.alerts(for: report, now: now.addingTimeInterval(60)).startupItems.isEmpty)
    }

    // MARK: Cooldowns across a relaunch

    func testACooldownSurvivesARelaunch() {
        var first = SentinelAlertGate()
        XCTAssertEqual(first.alerts(for: SentinelReport(findings: [finding(pid: 10)]), now: now).findings.count, 1)
        let saved = first.memory

        // The same process is still running after Ghost restarts, or the program restarted meanwhile.
        for pid: Int32 in [10, 99] {
            var second = SentinelAlertGate(memory: saved, now: now.addingTimeInterval(3_600))
            let report = SentinelReport(findings: [finding(pid: pid)])
            XCTAssertTrue(second.alerts(for: report, now: now.addingTimeInterval(3_600)).findings.isEmpty, "pid \(pid)")
        }
        let nextDay = now.addingTimeInterval(SentinelAlertGate.cooldown + 1)
        var later = SentinelAlertGate(memory: saved, now: nextDay)
        XCTAssertEqual(later.alerts(for: SentinelReport(findings: [finding(pid: 99)]), now: nextDay).findings.count, 1,
                       "a day later it is news again")
    }

    func testAfterARelaunchADifferentProgramOrReasonStillAlerts() {
        var first = SentinelAlertGate()
        _ = first.alerts(for: SentinelReport(findings: [finding(pid: 10)]), now: now)
        var second = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(60))
        let other = finding(pid: 11, path: "/Users/Shared/.u/agent", kind: .hiddenLocation)
        let differentReason = finding(pid: 12, kind: .reverseShell, severity: .suspicious)
        let alerts = second.alerts(for: SentinelReport(findings: [other, differentReason]), now: now.addingTimeInterval(60))
        XCTAssertEqual(alerts.findings.map(\.id), [other.id, differentReason.id])
    }

    /// The one alert that must never be swallowed: an earlier run's dangerous alert (perhaps dropped while
    /// notifications were off) does not hold back the next run's, though within a run it still waits a day.
    func testADangerousCooldownDoesNotOutliveTheRun() {
        var first = SentinelAlertGate()
        let dangerous = finding(pid: 20, kind: .reverseShell, severity: .dangerous)
        XCTAssertEqual(first.alerts(for: SentinelReport(findings: [dangerous]), now: now).findings.count, 1)
        XCTAssertTrue(first.alerts(for: SentinelReport(findings: [finding(pid: 21, kind: .reverseShell, severity: .dangerous)]),
                                   now: now.addingTimeInterval(600)).findings.isEmpty, "within a run it stays quiet for a day")

        var second = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(second.alerts(for: SentinelReport(findings: [dangerous]), now: now.addingTimeInterval(3_600)).findings.count, 1)
    }

    func testAFindingThatTurnsDangerousAlertsAfterARelaunchToo() {
        var first = SentinelAlertGate()
        _ = first.alerts(for: SentinelReport(findings: [finding(pid: 30)]), now: now)
        var second = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(60))
        let worse = finding(pid: 30, severity: .dangerous)
        XCTAssertEqual(second.alerts(for: SentinelReport(findings: [worse]), now: now.addingTimeInterval(60)).findings.count, 1)
    }

    func testAStartupItemAlertedBeforeARelaunchStaysQuiet() {
        var first = SentinelAlertGate()
        let report = SentinelReport(launchItems: [item("com.example.new", isNew: true)])
        XCTAssertEqual(first.alerts(for: report, now: now).startupItems.count, 1)
        var second = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(60))
        XCTAssertTrue(second.alerts(for: report, now: now.addingTimeInterval(60)).startupItems.isEmpty)
    }

    /// Alert keys hold executable paths, and the saved memory must not: only hashes reach the disk.
    func testTheSavedMemoryHoldsHashesNeverPaths() throws {
        var gate = SentinelAlertGate()
        let flagged = finding(pid: 40, path: "/private/tmp/bench3/agent")
        _ = gate.alerts(for: SentinelReport(findings: [flagged], launchItems: [item("com.example.bench", isNew: true)]), now: now)
        let memory = gate.memory
        XCTAssertEqual(memory.lastAlerted.count, 2)
        XCTAssertTrue(memory.lastAlerted.keys.contains(AlertMemory.hash(SentinelAlertGate.key(for: flagged))))
        for key in memory.lastAlerted.keys {
            XCTAssertEqual(key.count, 64)
            XCTAssertTrue(key.allSatisfy(\.isHexDigit), key)
        }
        let saved = try XCTUnwrap(String(data: JSONEncoder().encode(memory), encoding: .utf8))
        for leak in ["bench3", "agent", "/private", "com.example", "LaunchAgents"] {
            XCTAssertFalse(saved.contains(leak), "\(leak) reached the saved memory")
        }
    }

    func testAMemoryFromABadClockOrAnOldRunIsDropped() {
        var first = SentinelAlertGate()
        _ = first.alerts(for: SentinelReport(findings: [finding(pid: 50)]), now: now)
        // Restored before it was written (the clock was wrong): honoring it would silence the alert for years.
        let beforeItWasWritten = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(-3_600))
        XCTAssertTrue(beforeItWasWritten.memory.lastAlerted.isEmpty)
        let aWeekLater = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(7 * 24 * 3_600))
        XCTAssertTrue(aWeekLater.memory.lastAlerted.isEmpty, "older than the cooldown")
        let inside = SentinelAlertGate(memory: first.memory, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(inside.memory, first.memory)
    }
}
