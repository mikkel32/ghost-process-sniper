import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class DuplicateScoringTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private func node(_ pid: Int32, parent: Int32 = 1, _ script: String, startedAgo: TimeInterval = 3_600, ports: [Int] = []) -> ProcessMetrics {
        let base = Fixture.process(pid: pid, parent: parent, name: "node", path: "/usr/local/bin/node",
                                   command: "node \(script)", megabytes: 200, cpu: 1,
                                   started: Fixture.now.addingTimeInterval(-startedAgo))
        guard !ports.isEmpty else { return base }
        return ProcessMetrics(
            identity: base.identity, parentPID: base.parentPID, userID: base.userID, ownerName: base.ownerName,
            name: base.name, executablePath: base.executablePath, commandLine: base.commandLine,
            residentMemoryBytes: base.residentMemoryBytes, physicalFootprintBytes: base.physicalFootprintBytes,
            virtualMemoryBytes: base.virtualMemoryBytes, cpuPercent: base.cpuPercent, totalProcessorSeconds: 0,
            threadCount: base.threadCount, isSystemProcess: false, sampledAt: base.sampledAt,
            forensics: ProcessForensics(currentDirectory: "/Users/dev/web", rootDirectory: "/", openFileCount: 20,
                                        socketCount: 2, listeningPorts: ports, isPartial: false, notes: [])
        )
    }

    private func build(_ processes: [ProcessMetrics]) -> ProcessFamilyBuildResult {
        var window = TrendWindow()
        return ProcessFamilyBuilder(currentUserID: 501).buildFamiliesWithDuplicates(
            from: processes, settings: .smart, trendWindow: &window, now: Fixture.now)
    }

    func testWorkerPoolIsNotADuplicate() throws {
        let jest = node(800, "/Users/dev/web/node_modules/.bin/jest --watch")
        let workers = (0..<6).map { node(801 + Int32($0), parent: 800, "/Users/dev/web/node_modules/jest-worker/build/workers/processChild.js") }
        let result = build([jest] + workers)
        XCTAssertEqual(result.families.count, 1)
        let family = try XCTUnwrap(result.families.first)
        XCTAssertFalse(family.score.components.contains { $0.slot == "duplicate" })
        XCTAssertFalse(family.score.reasons.contains { $0.contains("copies") || $0.contains("matching instances") })
        let pool = try XCTUnwrap(result.duplicateClusters.first)
        XCTAssertTrue(pool.isInternalToSingleFamily)
        XCTAssertEqual(pool.independentRootCount, 1)
        XCTAssertFalse(pool.countsAsIndependentCopies)
    }

    func testIndependentCopiesKeepTheNewestAndSuggestStoppingTheRest() throws {
        let vite = "/Users/dev/web/node_modules/.bin/vite"
        let oldest = node(900, "\(vite) --port 5173", startedAgo: 7_200, ports: [5173])
        let older = node(901, "\(vite) --port 5174", startedAgo: 3_600, ports: [5174])
        let newest = node(902, "\(vite) --port 5175", startedAgo: 60, ports: [5175])
        let result = build([oldest, older, newest])
        XCTAssertEqual(result.duplicateClusters.count, 1)
        let cluster = try XCTUnwrap(result.duplicateClusters.first)
        XCTAssertEqual(cluster.reason, "3 independent copies")
        XCTAssertEqual(cluster.keepIdentity, newest.identity)
        XCTAssertEqual(Set(cluster.redundantRootIdentities), [oldest.identity, older.identity])
        XCTAssertEqual(cluster.redundantPorts, [5173, 5174])
        XCTAssertTrue(result.families.allSatisfy { $0.score.reasons.contains("3 independent copies") })

        let kept = try XCTUnwrap(result.families.first { $0.root.identity == newest.identity })
        let enriched = RadarIntelligence().enrich(
            family: kept, context: RadarContext(baselines: [:], recentIncidentCounts: [:], rules: []),
            settings: .smart, now: Fixture.now)
        let stop = try XCTUnwrap(enriched.suggestions.first { $0.targetIdentities != nil })
        XCTAssertEqual(stop.type, .suggestKill)
        XCTAssertEqual(stop.title, "Stop 2 older copies (ports 5173, 5174)")
        XCTAssertEqual(Set(stop.targetIdentities ?? []), [oldest.identity, older.identity])

        let redundant = try XCTUnwrap(result.families.first { $0.root.identity == oldest.identity })
        let other = RadarIntelligence().enrich(
            family: redundant, context: RadarContext(baselines: [:], recentIncidentCounts: [:], rules: []),
            settings: .smart, now: Fixture.now)
        XCTAssertFalse(other.suggestions.contains { $0.targetIdentities != nil })
    }

    func testTheCopyInATerminalIsKeptOverANewerDetachedOne() {
        let script = "/Users/dev/api/server.js"
        let inTerminal = node(950, parent: 1, script, startedAgo: 7_200)
        let attached = ProcessMetrics(
            identity: inTerminal.identity, parentPID: 1, userID: 501, ownerName: "dev", name: "node",
            executablePath: "/usr/local/bin/node", commandLine: inTerminal.commandLine,
            residentMemoryBytes: inTerminal.residentMemoryBytes, physicalFootprintBytes: inTerminal.physicalFootprintBytes,
            virtualMemoryBytes: inTerminal.virtualMemoryBytes, cpuPercent: 1, totalProcessorSeconds: 0, threadCount: 4,
            isSystemProcess: false, sampledAt: Fixture.now,
            session: ProcessSessionInfo(processGroupID: 950, sessionID: 940, controllingTerminal: 0x1000002,
                                        terminalForegroundGroupID: 950, runState: .sleeping)
        )
        let newer = node(951, script, startedAgo: 60)
        let cluster = build([attached, newer]).duplicateClusters.first
        XCTAssertEqual(cluster?.keepIdentity, attached.identity)
        XCTAssertEqual(cluster?.keepReason, "the one attached to a terminal")
    }

    func testDifferentScriptsOnOneInterpreterAreNotCopies() {
        let result = build([
            node(1_000, "/Users/dev/web/node_modules/.bin/vite"),
            node(1_001, "/Users/dev/web/node_modules/typescript/lib/tsserver.js"),
            node(1_002, "/Users/dev/web/node_modules/.bin/eslint --watch"),
            node(1_003, "/Users/dev/api/server.js"),
        ])
        XCTAssertTrue(result.duplicateClusters.isEmpty)
        XCTAssertTrue(result.families.allSatisfy { family in !family.score.components.contains { $0.slot == "duplicate" } })
    }

    func testTheSameToolInTwoProjectsIsNotADuplicate() {
        let result = build([
            node(1_050, "/Users/dev/web/node_modules/.bin/vite --port 5173"),
            node(1_051, "/Users/dev/docs/node_modules/.bin/vite --port 5174"),
        ])
        XCTAssertTrue(result.duplicateClusters.isEmpty)
    }

    func testPortsAndNumbersDoNotSplitOneWorkload() {
        let result = build([
            node(1_100, "/Users/dev/api/server.js --port 3000"),
            node(1_101, "/Users/dev/api/server.js --port 3001"),
        ])
        XCTAssertEqual(result.duplicateClusters.first?.independentRootCount, 2)
    }

    func testCopiesStartedFromOneShellAreStillIndependent() {
        let shell = Fixture.process(pid: 1_200, name: "zsh", path: "/bin/zsh", command: "-zsh", megabytes: 6)
        let result = build([
            shell,
            node(1_201, parent: 1_200, "/Users/dev/api/server.js"),
            node(1_202, parent: 1_200, "/Users/dev/api/server.js"),
        ])
        XCTAssertEqual(result.duplicateClusters.first?.independentRootCount, 2)
    }

    func testAppsAreSkippedButBundledCommandLineToolsCount() {
        let app = "/Applications/Docker.app/Contents"
        let mains = (0..<2).map {
            Fixture.process(pid: 1_300 + Int32($0), name: "Docker Desktop", path: "\(app)/MacOS/Docker Desktop", command: "\(app)/MacOS/Docker Desktop")
        }
        let tools = (0..<2).map {
            Fixture.process(pid: 1_310 + Int32($0), name: "com.docker.cli", path: "\(app)/Resources/bin/com.docker.cli",
                            command: "\(app)/Resources/bin/com.docker.cli compose up")
        }
        let result = build(mains + tools)
        XCTAssertEqual(result.duplicateClusters.map(\.displayName), ["com.docker.cli"])
    }
}
