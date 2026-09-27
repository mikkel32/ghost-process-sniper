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

    func testQuietOrExitedFindingsNeverAlert() {
        var gate = SentinelAlertGate()
        let report = SentinelReport(findings: [finding(pid: 40, severity: .notable), finding(pid: 41, running: false)])
        XCTAssertTrue(gate.alerts(for: report, now: now).findings.isEmpty)
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
}
