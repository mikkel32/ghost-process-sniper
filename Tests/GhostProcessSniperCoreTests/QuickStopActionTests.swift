import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class QuickStopActionTests: XCTestCase {
    private let assessor = KillRiskAssessor()

    func testAppMainBinaryIsQuitByItsBundleName() {
        let textEdit = metrics(10, "TextEdit", path: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        let family = makeFamily(textEdit, level: .hot)
        let action = QuickStopAction.actions(for: [candidate(family, .hot)], families: [family], processes: [textEdit])[family.familyKey]
        XCTAssertEqual(action?.title, "Quit TextEdit…")
        XCTAssertEqual(action?.shortTitle, "Quit…")
        XCTAssertEqual(action?.systemImage, "xmark.app")
        XCTAssertEqual(action?.targetFamilyKey, family.familyKey)
        XCTAssertEqual(action?.emphasis, .available, "an editor may hold unsaved work, so quitting it is never pushed")
    }

    func testDevServerNamesThePortsItFrees() {
        let risk = assess(metrics(20, "node", command: "node /app/node_modules/.bin/next dev", ports: [3000]))
        let action = make(risk: risk, level: .hot, heatConfirmed: true)
        XCTAssertEqual(action.title, "Stop Server…")
        XCTAssertEqual(action.detail, "Frees :3000")
        XCTAssertEqual(action.emphasis, .recommended)
    }

    func testChildOfNodemonRedirectsToTheSupervisorFamily() {
        let nodemon = metrics(30, "node", command: "node /usr/local/lib/node_modules/nodemon/bin/nodemon.js server.js")
        let server = metrics(31, "node", command: "node server.js", parent: 30)
        let supervisorFamily = makeFamily(nodemon, members: [nodemon])
        let serverFamily = makeFamily(server, level: .critical)
        let actions = QuickStopAction.actions(
            for: [candidate(serverFamily, .critical)],
            families: [supervisorFamily, serverFamily],
            processes: [nodemon, server]
        )
        let action = actions[serverFamily.familyKey]
        XCTAssertEqual(action?.title, "Stop nodemon…")
        XCTAssertEqual(action?.targetFamilyKey, supervisorFamily.familyKey)
        XCTAssertEqual(action?.redirectedFromName, "node")
        XCTAssertEqual(action?.detail, "node is restarted by nodemon")
    }

    func testSupervisorThatIsNotAStoppableFamilyKeepsTheTarget() {
        let nodemon = metrics(40, "node", command: "node /usr/local/lib/node_modules/nodemon/bin/nodemon.js server.js")
        let server = metrics(41, "node", command: "node server.js", parent: 40)
        let serverFamily = makeFamily(server)
        let action = QuickStopAction.actions(
            for: [candidate(serverFamily, .hot)], families: [serverFamily], processes: [nodemon, server]
        )[serverFamily.familyKey]
        XCTAssertEqual(action?.targetFamilyKey, serverFamily.familyKey)
        XCTAssertNil(action?.redirectedFromName)
        XCTAssertEqual(action?.title, "Stop node…")
        XCTAssertEqual(action?.detail, "nodemon may restart it")
    }

    func testDatabaseIsShutDownAndNeverRecommended() {
        let risk = assess(metrics(50, "postgres", command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /var/pg"))
        let action = make(name: "postgres", risk: risk, level: .critical, heatConfirmed: true)
        XCTAssertEqual(action.title, "Shut Down postgres…")
        XCTAssertEqual(action.detail, "Gives it time to save data")
        XCTAssertEqual(action.emphasis, .available)
    }

    func testFamilyWithoutOwnedTargetsIsUnavailable() {
        let action = QuickStopAction.make(familyKey: "k", displayName: "WindowServer", level: .critical,
                                          heatConfirmed: true, hasOwnedTargets: false, risk: .none)
        XCTAssertEqual(action.emphasis, .unavailable)
        XCTAssertFalse(action.isAvailable)
    }

    func testQuietOrUnconfirmedFamiliesAreNeverRecommended() {
        XCTAssertEqual(make(risk: .none, level: .quiet, heatConfirmed: true).emphasis, .available)
        XCTAssertEqual(make(risk: .none, level: .watch, heatConfirmed: true).emphasis, .available)
        XCTAssertEqual(make(risk: .none, level: .hot, heatConfirmed: false).emphasis, .available)
        XCTAssertEqual(make(risk: .none, level: .hot, heatConfirmed: true).emphasis, .recommended)
        XCTAssertEqual(make(risk: .none, level: .hot, heatConfirmed: true).title, "Stop node…")
    }

    func testInstallsAndBuildsAreNamedForTheirWork() {
        XCTAssertEqual(make(risk: assess(metrics(60, "npm", command: "npm install")), level: .hot, heatConfirmed: true).title, "Stop Install…")
        XCTAssertEqual(make(risk: assess(metrics(61, "xcodebuild")), level: .hot, heatConfirmed: true).title, "Stop Build…")
    }

    func testUnknownFamiliesGetNoAction() {
        XCTAssertTrue(QuickStopAction.actions(for: [QuickStopAction.Candidate(familyKey: "gone", level: .hot)],
                                              families: [], processes: []).isEmpty)
    }

    func testCleanStopToastNamesTheMemoryFreed() {
        let clean = KillReport(displayName: "node", rootPID: 1, gracefulPIDs: [1], realizedMemoryReclaimBytes: 512 * 1_048_576)
        XCTAssertEqual(clean.cleanStopToastText, "Stopped node — freed 512 MB")
        let nothingMeasured = KillReport(displayName: "node", rootPID: 1, forcedPIDs: [1])
        XCTAssertEqual(nothingMeasured.cleanStopToastText, "Stopped node")
        let survivors = KillReport(displayName: "node", rootPID: 1, gracefulPIDs: [1], survivorPIDs: [2])
        XCTAssertNil(survivors.cleanStopToastText, "the user stays on the result when something survived")
        var respawned = KillReport(displayName: "node", rootPID: 1, gracefulPIDs: [1])
        respawned.respawnedPIDs = [3]
        XCTAssertNil(respawned.cleanStopToastText)
        XCTAssertNil(KillReport(displayName: "node", rootPID: 1, stalePIDs: [1]).cleanStopToastText)
    }

    /// The page only moves on when the stop did everything it promised.
    func testCleanStopToastWaitsOutEveryUnfinishedOutcome() {
        func stopped(_ change: (inout KillReport) -> Void) -> KillReport {
            var report = KillReport(displayName: "node", rootPID: 1, gracefulPIDs: [1])
            change(&report)
            return report
        }
        XCTAssertNotNil(stopped { $0.portOutcomes = [.freed(3000)] }.cleanStopToastText)
        XCTAssertNil(stopped { $0.portOutcomes = [.heldBy(port: 3000, pid: 9, name: "node", startedDuringStop: true)] }
            .cleanStopToastText, "a port is still held")
        XCTAssertNil(stopped { $0.signalDeniedPIDs = [2] }.cleanStopToastText, "macOS refused a process")
        XCTAssertNil(KillReport(displayName: "node", rootPID: 1, gracefulPIDs: [1], deniedPIDs: [2]).cleanStopToastText)
        let job = LaunchdJob(label: "homebrew.mxcl.postgresql@16", pid: 1, domain: "gui/501", plistPath: nil, keepAlive: true)
        XCTAssertNil(stopped {
            $0.launchdBootout = LaunchdBootout(job: job, keepOff: false, accepted: false, disabled: false, status: 5)
        }.cleanStopToastText, "the bootout failed")
        XCTAssertNotNil(stopped {
            $0.launchdBootout = LaunchdBootout(job: job, keepOff: false, accepted: true, disabled: false, status: 0)
        }.cleanStopToastText)
        let late = KillTarget(identity: ProcessIdentity(pid: 7, startTimeSeconds: 1, startTimeMicroseconds: 0), parentPID: 1,
                              name: "node", ownerName: "me", depth: 1, memoryBytes: 0, cpuPercent: 0,
                              state: .locked, reason: "started during the stop", isRoot: false)
        XCTAssertNil(stopped { $0.lateTargets = [late] }.cleanStopToastText, "a late process was only reported")
    }

    // MARK: - Fixtures

    private func make(name: String = "node", risk: KillRiskAssessment, level: GhostLevel, heatConfirmed: Bool) -> QuickStopAction {
        QuickStopAction.make(familyKey: "key", displayName: name, level: level, heatConfirmed: heatConfirmed,
                             hasOwnedTargets: true, risk: risk)
    }

    private func assess(_ root: ProcessMetrics) -> KillRiskAssessment {
        assessor.assess(KillWorkloadProfile(family: makeFamily(root), sample: []))
    }

    private func candidate(_ family: ProcessFamily, _ level: GhostLevel) -> QuickStopAction.Candidate {
        QuickStopAction.Candidate(familyKey: family.familyKey, level: level)
    }

    private func makeFamily(_ root: ProcessMetrics, members: [ProcessMetrics]? = nil, level: GhostLevel = .quiet) -> ProcessFamily {
        let members = members ?? [root]
        return ProcessFamily(
            root: root,
            members: members,
            totalResidentMemoryBytes: 64_000_000,
            totalPhysicalFootprintBytes: 64_000_000,
            totalCPUPercent: 1,
            devConfidence: 0.9,
            commandHints: [root.commandLine],
            trend: TrendMetrics(memoryVelocityMegabytesPerMinute: 0, cpuSlopePerMinute: 0, memoryPoints: []),
            score: GhostScore(value: 10, level: level, reasons: []),
            ownedIdentities: members.map(\.identity),
            protectedPIDs: []
        )
    }

    private func metrics(_ pid: Int32, _ name: String, path: String = "", command: String? = nil,
                         parent: Int32 = 1, ports: [Int] = []) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
            parentPID: parent,
            userID: 501,
            ownerName: "me",
            name: name,
            executablePath: path,
            commandLine: command ?? (path.isEmpty ? name : path),
            residentMemoryBytes: 32_000_000,
            physicalFootprintBytes: 32_000_000,
            virtualMemoryBytes: 64_000_000,
            cpuPercent: 0,
            totalProcessorSeconds: 1,
            threadCount: 2,
            isSystemProcess: false,
            sampledAt: Date(timeIntervalSince1970: 10_000),
            forensics: ProcessForensics(currentDirectory: nil, rootDirectory: nil, openFileCount: nil, socketCount: nil,
                                        listeningPorts: ports, isPartial: false, notes: [])
        )
    }
}
