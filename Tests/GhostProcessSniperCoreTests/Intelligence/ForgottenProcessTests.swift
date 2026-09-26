import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ForgottenProcessTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private func process(
        pid: Int32,
        parent: Int32 = 1,
        name: String = "node",
        path: String = "/usr/local/bin/node",
        command: String? = nil,
        cpu: Double = 0,
        startedAgo: TimeInterval = 3_600,
        session: ProcessSessionInfo,
        ports: [Int] = [],
        directory: String? = nil,
        cpuSeconds: TimeInterval = 10,
        at date: Date = IntelligenceFixture.now
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: UInt64(Fixture.now.addingTimeInterval(-startedAgo).timeIntervalSince1970), startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "dev", name: name, executablePath: path,
            commandLine: command ?? "\(name) server.js", residentMemoryBytes: 300 * Fixture.mib,
            physicalFootprintBytes: 300 * Fixture.mib, virtualMemoryBytes: 600 * Fixture.mib, cpuPercent: cpu,
            totalProcessorSeconds: cpuSeconds, threadCount: 4, isSystemProcess: false, sampledAt: date,
            forensics: ProcessForensics(currentDirectory: directory, rootDirectory: "/", openFileCount: 10,
                                        socketCount: ports.count, listeningPorts: ports, isPartial: directory == nil, notes: []),
            session: session
        )
    }

    private func session(pid: Int32, group: Int32? = nil, sid: Int32? = nil, tty: UInt32? = nil, foreground: Int32? = nil,
                         state: ProcessRunState = .sleeping) -> ProcessSessionInfo {
        ProcessSessionInfo(processGroupID: group ?? pid, sessionID: sid, controllingTerminal: tty,
                           terminalForegroundGroupID: foreground, runState: state)
    }

    func testLaunchContextTable() {
        let code = process(pid: 10, name: "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                           command: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", session: session(pid: 10, sid: 10))
        XCTAssertEqual(LaunchContextResolver.resolve(root: code, livePIDs: [10]), .appBundle)

        let postgres = process(pid: 20, name: "postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres",
                               session: session(pid: 20, sid: 20))
        XCTAssertEqual(LaunchContextResolver.resolve(root: postgres, livePIDs: [20]), .launchdJob)

        let agent = process(pid: 25, name: "syncd", path: "/Users/dev/bin/syncd", session: session(pid: 25, sid: 25))
        XCTAssertEqual(LaunchContextResolver.resolve(root: agent, livePIDs: [25]), .launchdJob)

        // Job control made it a group leader, but the login shell's session is gone.
        let leftBehind = process(pid: 30, session: session(pid: 30, sid: 900))
        XCTAssertEqual(LaunchContextResolver.resolve(root: leftBehind, livePIDs: [30]), .abandonedTerminalJob)

        let orphan = process(pid: 35, session: session(pid: 35, group: 34))
        XCTAssertEqual(LaunchContextResolver.resolve(root: orphan, livePIDs: [35]), .reparentedOrphan)

        let foreground = process(pid: 40, parent: 39, name: "npm", command: "npm run dev",
                                 session: session(pid: 40, sid: 39, tty: 0x1000003, foreground: 40))
        XCTAssertEqual(LaunchContextResolver.resolve(root: foreground, livePIDs: [39, 40]), .terminalForeground)

        let background = process(pid: 45, parent: 39, session: session(pid: 45, sid: 39, tty: 0x1000003, foreground: 40))
        XCTAssertEqual(LaunchContextResolver.resolve(root: background, livePIDs: [39, 45]), .terminalBackground)
    }

    func testActiveEditorStaysBelowForgotten() {
        let code = process(pid: 10, name: "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                           command: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", cpu: 12,
                           startedAgo: 4 * 3_600, session: session(pid: 10, sid: 10))
        let active = FamilyCPUActivity(buckets: [], lastActiveAt: Fixture.now.addingTimeInterval(-5), firstSeen: Fixture.now.addingTimeInterval(-4 * 3_600))
        let assessment = ForgottenProcessAssessor.assess(root: code, context: .appBundle, activity: active,
                                                         forensics: code.forensics, workingDirectoryMissing: false, now: Fixture.now)
        XCTAssertLessThan(assessment.likelihood, 0.3)
    }

    func testIdleServerLeftByAClosedTerminalIsForgotten() {
        let vite = process(pid: 30, command: "node /Users/dev/web/node_modules/.bin/vite", session: session(pid: 30, sid: 900),
                           ports: [5173], directory: "/Users/dev/web")
        let idle = FamilyCPUActivity(buckets: [], lastActiveAt: Fixture.now.addingTimeInterval(-40 * 60),
                                     firstSeen: Fixture.now.addingTimeInterval(-3_000))
        let assessment = ForgottenProcessAssessor.assess(root: vite, context: .abandonedTerminalJob, activity: idle,
                                                         forensics: vite.forensics, workingDirectoryMissing: false, now: Fixture.now)
        XCTAssertGreaterThanOrEqual(assessment.likelihood, 0.8)
        XCTAssertEqual(assessment.facts, [
            "started from a terminal that has since closed",
            "no CPU use for 40 min",
            "still listening on port 5173",
        ])
    }

    func testDeletedWorkingDirectoryIsEvidenceEvenForLaunchdJobs() {
        let agent = process(pid: 25, name: "syncd", path: "/Users/dev/bin/syncd", session: session(pid: 25, sid: 25),
                            directory: "/Users/dev/old-project")
        let watched = FamilyCPUActivity(buckets: [], lastActiveAt: nil, firstSeen: Fixture.now.addingTimeInterval(-600))
        let kept = ForgottenProcessAssessor.assess(root: agent, context: .launchdJob, activity: watched, forensics: agent.forensics,
                                                   workingDirectoryMissing: false, now: Fixture.now)
        XCTAssertEqual(kept.likelihood, 0)
        let missing = ForgottenProcessAssessor.assess(root: agent, context: .launchdJob, activity: watched, forensics: agent.forensics,
                                                      workingDirectoryMissing: true, now: Fixture.now)
        XCTAssertEqual(missing.likelihood, 0.2, accuracy: 0.001)
        XCTAssertEqual(missing.facts, ["its working directory /Users/dev/old-project was deleted"])
    }

    /// The whole path: builder, ledger, session liveness and a directory check.
    func testBuilderJudgesAFamilyFromItsHistory() throws {
        let builder = ProcessFamilyBuilder(currentUserID: 501, directoryExists: { $0 != "/Users/dev/gone" })
        var window = TrendWindow()
        var history = RadarHistory()
        var family: ProcessFamily?
        // Forty minutes of samples with the CPU clock standing still.
        for minute in stride(from: 0, through: 40, by: 2) {
            let date = Fixture.now.addingTimeInterval(Double(minute - 40) * 60)
            let server = process(pid: 30, command: "node /Users/dev/gone/node_modules/.bin/vite", startedAgo: 7_200,
                                 session: session(pid: 30, sid: 900), ports: [5173], directory: "/Users/dev/gone", at: date)
            family = builder.buildFamiliesWithDuplicates(from: [server], settings: .smart, trendWindow: &window,
                                                         history: &history, now: date).families.first
        }
        let forgotten = try XCTUnwrap(family?.forgotten)
        XCTAssertEqual(forgotten.launchContext, .abandonedTerminalJob)
        XCTAssertGreaterThanOrEqual(forgotten.likelihood, 0.9)
        XCTAssertTrue(forgotten.facts.contains("its working directory /Users/dev/gone was deleted"))
        XCTAssertTrue(family?.score.components.contains { $0.slot == "forgotten" } ?? false)
    }

    func testOnlyAMissingPathReadsAsDeleted() {
        let home = "/Users/dev"
        XCTAssertFalse(WorkingDirectoryProbe.exists("/Users/dev/gone", home: home, statError: { _ in ENOENT }))
        XCTAssertFalse(WorkingDirectoryProbe.exists("/Users/dev/file.txt/sub", home: home, statError: { _ in ENOTDIR }))
        for error in [0, EPERM, EACCES, EIO] {
            XCTAssertTrue(WorkingDirectoryProbe.exists("/Users/dev/web", home: home, statError: { _ in error }))
        }
        // Privacy-guarded folders are never looked at, so no consent prompt.
        for path in ["/Users/dev/Documents/web", "/Users/dev/Desktop", "/Users/dev/Downloads/api",
                     "/Users/dev/Library/Mobile Documents/com~apple~CloudDocs/app", "/Users/dev/Library/CloudStorage/Dropbox/x",
                     "/Volumes/External/site"] {
            XCTAssertTrue(WorkingDirectoryProbe.exists(path, home: home, statError: { _ in
                XCTFail("stat on \(path)")
                return ENOENT
            }))
        }
        XCTAssertFalse(WorkingDirectoryProbe.exists("/Users/dev/Documentsold", home: home, statError: { _ in ENOENT }))
    }

    /// Without Full Disk Access a live project folder fails with EPERM; that
    /// is no evidence that it was deleted.
    func testAnUnreadableWorkingDirectoryIsNotDeleted() throws {
        let builder = ProcessFamilyBuilder(currentUserID: 501, directoryExists: {
            WorkingDirectoryProbe.exists($0, home: "/Users/dev", statError: { _ in EPERM })
        })
        var window = TrendWindow()
        var history = RadarHistory()
        var family: ProcessFamily?
        for minute in stride(from: 0, through: 40, by: 2) {
            let date = Fixture.now.addingTimeInterval(Double(minute - 40) * 60)
            let server = process(pid: 30, command: "node /Users/dev/web/node_modules/.bin/vite", startedAgo: 7_200,
                                 session: session(pid: 30, sid: 900), ports: [5173], directory: "/Users/dev/web", at: date)
            family = builder.buildFamiliesWithDuplicates(from: [server], settings: .smart, trendWindow: &window,
                                                         history: &history, now: date).families.first
        }
        let forgotten = try XCTUnwrap(family?.forgotten)
        XCTAssertEqual(forgotten.launchContext, .abandonedTerminalJob)
        XCTAssertFalse(forgotten.facts.contains { $0.contains("was deleted") })
        XCTAssertEqual(forgotten.likelihood, 0.8, accuracy: 0.001)
    }

    func testZombieChildrenAreFlaggedWithoutBlankingTheFamily() throws {
        let parent = process(pid: 50, name: "node", command: "node /Users/dev/api/server.js", cpu: 3, session: session(pid: 50, sid: 50))
        let zombies = (0..<4).map { index in
            ProcessMetrics(
                identity: ProcessIdentity(pid: 51 + Int32(index), startTimeSeconds: 49_000, startTimeMicroseconds: 0),
                parentPID: 50, userID: 501, ownerName: "dev", name: "node", executablePath: "/usr/local/bin/node",
                commandLine: "node worker.js", residentMemoryBytes: 200 * Fixture.mib, physicalFootprintBytes: 200 * Fixture.mib,
                virtualMemoryBytes: 0, cpuPercent: 0, totalProcessorSeconds: 0, threadCount: 0, isSystemProcess: false,
                sampledAt: Fixture.now, measurementStatus: .unavailable,
                session: session(pid: 51 + Int32(index), group: 50, state: .zombie)
            )
        }
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([parent] + zombies, window: &window).first)
        XCTAssertEqual(family.zombieChildCount, 4)
        XCTAssertTrue(family.coverage.isScorable)
        XCTAssertEqual(family.totalPhysicalFootprintBytes, 300 * Fixture.mib)
        XCTAssertTrue(family.score.components.contains { $0.slot == "zombies" })
        XCTAssertTrue(family.suggestions.contains { $0.title.hasPrefix("Restart node to clear 4 zombies") })
    }
}
