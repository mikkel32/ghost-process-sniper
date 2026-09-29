import XCTest
@testable import GhostProcessSniperCore

/// A one-shot dangerous command is over by the time anyone looks. Everywhere
/// the report answers "am I OK?" it must not read as all-clear.
final class SentinelReportDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func finding(pid: Int32, severity: SentinelSeverity, running: Bool) -> SentinelFinding {
        SentinelFinding(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: UInt64(pid)),
            name: "sh", executablePath: "/bin/sh", commandLine: "sh -c payload", lineage: [],
            signals: [SentinelSignal(.downloadAndExecute, severity, "evidence")], headline: "headline \(pid)", recommendation: "",
            firstSeen: now, lastSeen: now, isRunning: running, signing: nil, downloadedFrom: [])
    }

    func testAnExitedDangerousCommandIsNotAllClear() {
        let report = SentinelReport(findings: [finding(pid: 1, severity: .dangerous, running: false)])
        XCTAssertNil(report.highestSeverity, "the live level stays running-only")
        XCTAssertEqual(report.displaySeverity, .dangerous)
        XCTAssertEqual(report.attentionLine, "A dangerous command ran")
        XCTAssertEqual(report.latestExitedDangerous?.headline, "headline 1")
    }

    func testARunningFindingKeepsItsOwnLevelUnlessTheExitedOneWasWorse() {
        let running = finding(pid: 2, severity: .suspicious, running: true)
        let gone = finding(pid: 3, severity: .dangerous, running: false)
        XCTAssertEqual(SentinelReport(findings: [running]).displaySeverity, .suspicious)
        XCTAssertEqual(SentinelReport(findings: [running, gone]).displaySeverity, .dangerous)
        // What is running is still what needs a look now; the line says both.
        XCTAssertEqual(SentinelReport(findings: [running, gone]).attentionLine, "1 process needs a look")
    }

    func testNothingFlaggedStaysAllClear() {
        let quiet = SentinelReport(findings: [finding(pid: 4, severity: .notable, running: true),
                                              finding(pid: 5, severity: .suspicious, running: false)])
        XCTAssertNil(SentinelReport.empty.displaySeverity)
        XCTAssertNil(SentinelReport.empty.attentionLine)
        XCTAssertEqual(quiet.displaySeverity, .notable, "an exited suspicious one is only a card")
        XCTAssertNil(quiet.attentionLine)
        XCTAssertNil(quiet.latestExitedDangerous)
    }

    func testSeveralExitedCommandsAreCounted() {
        let report = SentinelReport(findings: [finding(pid: 6, severity: .dangerous, running: false),
                                               finding(pid: 7, severity: .dangerous, running: false)])
        XCTAssertEqual(report.attentionLine, "2 dangerous commands ran")
    }
}
