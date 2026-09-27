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

    func testDrainEmptiesTheBuffer() {
        let watcher = SpawnWatcher()
        _ = watcher.drain()
        XCTAssertTrue(watcher.drain().isEmpty)
    }
}
