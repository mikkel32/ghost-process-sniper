import XCTest
@testable import GhostProcessSniperCore

final class KillRiskAssessorTests: XCTestCase {
    private let assessor = KillRiskAssessor()

    func testEditorAppsQuitPolitelyAndNeverForceWithoutAsking() {
        let risk = assess(root: process(10, "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode"))
        XCTAssertEqual(risk.kind, .editor)
        XCTAssertEqual(risk.appQuitPID, 10)
        XCTAssertTrue(risk.forceNeedsConfirmation)
        XCTAssertEqual(risk.highestSeverity, .danger)
        XCTAssertTrue(risk.headline?.contains("\u{2318}Q") == true)
    }

    func testRegularAppsKeepTheirNameAndQuitFirst() {
        let risk = assess(root: process(11, "iTerm2", path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"))
        XCTAssertEqual(risk.kind, .app)
        XCTAssertEqual(risk.appQuitPID, 11)
        XCTAssertTrue(risk.headline?.hasPrefix("Asks iTerm to quit") == true, risk.headline ?? "")
    }

    func testAppHelpersAreNotAppQuitTargets() {
        let helper = process(12, "Google Chrome Helper (Renderer)",
                             path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        XCTAssertNil(assess(root: helper).appQuitPID)
    }

    func testDatabasesGetLongGraceAndConfirmation() {
        let risk = assess(root: process(20, "postgres", command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16"))
        XCTAssertEqual(risk.kind, .dataStore)
        XCTAssertEqual(risk.graceSeconds, 12)
        XCTAssertTrue(risk.forceNeedsConfirmation)
        XCTAssertTrue(risk.hazards.contains { $0.kind == .dataIntegrity && $0.severity == .danger })
        XCTAssertEqual(assess(root: process(21, "java", command: "java -Xms1g org.elasticsearch.bootstrap.Elasticsearch")).kind, .dataStore)
    }

    func testContainerRuntimesWarnThatEveryContainerStops() {
        let risk = assess(root: process(30, "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"))
        XCTAssertEqual(risk.kind, .containerRuntime)
        XCTAssertTrue(risk.hazards.contains { $0.kind == .stopsContainers })
    }

    func testMutatingGitWarnsAboutLockFilesButReadsDoNot() {
        let commit = assess(root: process(40, "git", command: "git commit -m wip"))
        XCTAssertEqual(commit.kind, .versionControl)
        XCTAssertEqual(commit.hazards.first?.severity, .caution)
        XCTAssertTrue(commit.forceNeedsConfirmation)
        let status = assess(root: process(41, "git", command: "git status"))
        XCTAssertEqual(status.hazards.first?.severity, .info)
        XCTAssertFalse(status.forceNeedsConfirmation)
    }

    func testInstallsThroughScriptRunnersAreDetected() {
        XCTAssertEqual(assess(root: process(50, "npm", command: "npm install")).kind, .packageManager)
        XCTAssertEqual(assess(root: process(51, "swift", command: "swift package resolve")).kind, .packageManager)
        XCTAssertEqual(assess(root: process(52, "yarn", command: "yarn")).kind, .packageManager)
        XCTAssertNotEqual(assess(root: process(53, "npm", command: "npm run dev")).kind, .packageManager)
    }

    func testDevServersFreePortsAndOrphansAreSafeToStop() {
        let risk = assess(
            root: process(60, "node", command: "node /app/node_modules/.bin/vite --port 5173", ports: [5173, 24678]),
            parentIsLaunchd: true
        )
        XCTAssertEqual(risk.kind, .devServer)
        XCTAssertEqual(risk.freedPorts, [5173, 24678])
        XCTAssertTrue(risk.benefits.contains { $0.kind == .freesPorts })
        XCTAssertTrue(risk.benefits.contains { $0.kind == .orphaned })
        XCTAssertFalse(risk.forceNeedsConfirmation)
        XCTAssertNil(risk.highestSeverity, "benefits are not hazards")
    }

    func testSupervisorsAboveTheTargetPredictARestart() {
        let risk = assess(
            root: process(70, "node", command: "node server.js"),
            ancestors: [KillWorkloadAncestor(pid: 69, name: "node", executablePath: "/usr/local/bin/node",
                                             commandLine: "node /usr/local/lib/node_modules/nodemon/bin/nodemon.js server.js")]
        )
        XCTAssertEqual(risk.supervisor?.kind, .nodemon)
        XCTAssertEqual(risk.supervisor?.pid, 69)
        XCTAssertTrue(risk.hazards.contains { $0.kind == .respawn })
    }

    func testSupervisorInsideTheStopGoesDownWithIt() {
        let workload = KillWorkloadProfile(
            processes: [
                process(80, "node", command: "node /usr/local/bin/nodemon server.js", isRoot: true),
                process(81, "node", command: "node server.js", parent: 80)
            ],
            ancestors: [],
            parentIsLaunchd: false
        )
        XCTAssertNil(assessor.assess(workload).supervisor)
        let childOnly = assessor.assess(workload.restricted(to: 81))
        XCTAssertEqual(childOnly.supervisor?.kind, .nodemon, "stopping only the child keeps nodemon above it")
    }

    func testLaunchdAgentsRespawnButOrphanedToolsDoNot() {
        let agent = assess(root: process(90, "cloudd", path: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"),
                           parentIsLaunchd: true)
        XCTAssertEqual(agent.supervisor?.kind, .launchd)
        let orphan = assess(root: process(91, "python3", path: "/opt/homebrew/bin/python3", command: "python3 train.py"),
                            parentIsLaunchd: true)
        XCTAssertNil(orphan.supervisor)
    }

    func testLongCommandLinesAreReadFromTheirStart() {
        let padding = String(repeating: "--flag=\u{00e9}t\u{00e9} ", count: 600)
        XCTAssertEqual(assess(root: process(92, "npm", command: "npm install \(padding)")).kind, .packageManager)
        let tail = assess(root: process(93, "node", command: "node worker.js \(padding) vite"))
        XCTAssertEqual(tail.kind, .general, "only the start of argv identifies a workload")
    }

    func testAppMainBinaryIsTheLastBundleExecutable() {
        XCTAssertEqual(assess(root: process(94, "Code", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code")).appQuitPID, 94)
        XCTAssertNil(assess(root: process(95, "tool", path: "/Applications/Tool.app/Contents/MacOS/bin/tool")).appQuitPID)
        XCTAssertNil(assess(root: process(96, "Tool", path: "/Applications/Tool.app/Contents/MacOS/")).appQuitPID)
    }

    func testEmptyWorkloadIsNeutral() {
        XCTAssertEqual(assessor.assess(.empty), .none)
    }

    // MARK: - Fixtures

    private func assess(root: KillWorkloadProcess, ancestors: [KillWorkloadAncestor] = [], parentIsLaunchd: Bool = false) -> KillRiskAssessment {
        let rooted = KillWorkloadProcess(pid: root.pid, parentPID: root.parentPID, name: root.name,
                                         executablePath: root.executablePath, commandLine: root.commandLine,
                                         listeningPorts: root.listeningPorts, isRoot: true)
        return assessor.assess(KillWorkloadProfile(processes: [rooted], ancestors: ancestors, parentIsLaunchd: parentIsLaunchd))
    }

    private func process(_ pid: Int32, _ name: String, path: String = "", command: String? = nil,
                         ports: [Int] = [], parent: Int32 = 1, isRoot: Bool = false) -> KillWorkloadProcess {
        KillWorkloadProcess(pid: pid, parentPID: parent, name: name, executablePath: path,
                            commandLine: command ?? (path.isEmpty ? name : path), listeningPorts: ports, isRoot: isRoot)
    }
}
