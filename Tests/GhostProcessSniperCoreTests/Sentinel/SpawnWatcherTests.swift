import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The watcher reads a child the moment it starts, from kernel process
/// events. This test process plays the watched app.
final class SpawnWatcherTests: XCTestCase {
    func testShortLivedChildIsCaughtWithItsArguments() throws {
        let watcher = SpawnWatcher()
        watcher.setRoots([ProcessInfo.processInfo.processIdentifier: .terminal])
        // Let the watch install before anything starts.
        Thread.sleep(forTimeInterval: 0.2)

        let marker = "sentinel-spawn-\(UUID().uuidString.prefix(8))"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "echo \(marker) >/dev/null; sleep 0.3"]
        try child.run()
        child.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)

        let captures = watcher.drain()
        let caught = captures.first { $0.commandLine.contains(marker) }
        XCTAssertNotNil(caught, "captures: \(captures.map(\.commandLine))")
        XCTAssertEqual(caught?.executablePath, "/bin/sh")
        XCTAssertEqual(caught?.parentPID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(caught?.rootRole, .terminal)
    }

    /// Children deeper than the watcher follows are reported but never
    /// watched, so nothing about them may stay behind once they exit.
    func testNothingIsRememberedAfterADeepChainExits() throws {
        let watcher = SpawnWatcher()
        watcher.setRoots([ProcessInfo.processInfo.processIdentifier: .terminal])
        Thread.sleep(forTimeInterval: 0.2)

        // Each level starts the next shell, past maxDepth. osascript starts
        // its shell already exec'd, so from the deepest watched level that
        // child is reported but not watched.
        let script = #"d=${D:-0}; if [ "$d" -ge 2 ] && [ "$d" -le 4 ]; then /usr/bin/osascript -e 'do shell script "/usr/bin/true"' >/dev/null; fi; if [ "$d" -lt 5 ]; then D=$((d+1)) /bin/sh -c "$S"; /usr/bin/true; fi"#
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", script]
        child.environment = ["S": script, "PATH": "/usr/bin:/bin"]
        try child.run()
        child.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(watcher.drain().isEmpty)
        XCTAssertEqual(watcher.rememberedCount, 0, "an exited or unwatched process leaves nothing behind")
        XCTAssertEqual(watcher.watchedCount, 1, "only the root is still watched")
    }

    func testDrainEmptiesTheBuffer() {
        let watcher = SpawnWatcher()
        _ = watcher.drain()
        XCTAssertTrue(watcher.drain().isEmpty)
    }
}
