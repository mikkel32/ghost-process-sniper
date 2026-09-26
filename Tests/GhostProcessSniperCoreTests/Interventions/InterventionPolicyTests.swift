import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// How the policy engine chooses a strategy and its timing from what the
/// workload is, not from how big or hot the family looks.
final class InterventionPolicyTests: XCTestCase {
    func testRiskGraceIsAFloorForEveryStrategy() {
        let rebase = evaluate(command: "git rebase main", name: "git")
        XCTAssertEqual(rebase.recommendation.strategy, .standard)
        XCTAssertEqual(rebase.profile.verificationSchedule.graceSeconds, 5)
        XCTAssertEqual(rebase.profile.phases.first?.waitAfterSeconds, 5)

        let install = evaluate(command: "npm install", name: "npm")
        XCTAssertEqual(install.profile.verificationSchedule.graceSeconds, 4)
        XCTAssertEqual(install.profile.phases.first?.waitAfterSeconds, 4)

        let devServer = evaluate(command: "node /app/node_modules/.bin/vite", name: "node")
        XCTAssertEqual(devServer.recommendation.strategy, .gentleDevServer)
        XCTAssertEqual(devServer.profile.verificationSchedule.graceSeconds, 1.2)
    }

    func testDataLossWorkloadsAreNeverStubborn() {
        let forced = KillHistorySummary(signatureID: "x", operationCount: 12, gracefulSuccessRate: 0, forceRate: 1,
                                        survivorRate: 0, averageReclaimBytes: 0, commonDenialCount: 0)
        for (name, command) in [("npm", "npm install"), ("git", "git commit -m wip"), ("postgres", "postgres -D /var/pg")] {
            let evaluation = evaluate(command: command, name: name, history: forced, level: .critical, forecast: .runaway)
            XCTAssertNotEqual(evaluation.recommendation.strategy, .stubbornRunaway, command)
            XCTAssertGreaterThanOrEqual(evaluation.profile.verificationSchedule.graceSeconds, 4, command)
        }
    }

    func testLargeFootprintAloneDoesNotShortenGrace() {
        let evaluation = evaluate(command: "cruncher --input big.bin", name: "cruncher", memory: 3 * 1_073_741_824,
                                  cpu: 250, level: .critical, forecast: .runaway)
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
        XCTAssertEqual(evaluation.profile.verificationSchedule.graceSeconds, 2)
    }

    func testStaleFamilyIsNotStubborn() {
        let evaluation = evaluate(command: "python3 train.py", name: "python3", memory: 2 * 1_073_741_824,
                                  level: .hot, forecast: .stale)
        XCTAssertNotEqual(evaluation.recommendation.strategy, .stubbornRunaway)
        XCTAssertEqual(evaluation.profile.verificationSchedule.graceSeconds, 2)
    }

    func testDevServerLabelWithoutDevServerArgvIsNotGentle() {
        let evaluation = evaluate(command: "node scripts/migrate.js", name: "node", label: "Node server")
        XCTAssertEqual(evaluation.recommendation.strategy, .standard, "the risk assessor is the only classifier")
    }

    func testCommonDevServersAreRecognized() {
        for command in ["python3 -m http.server 8000", "streamlit run app.py", "fastapi dev main.py",
                        "python manage.py runserver", "jupyter-lab --no-browser"] {
            XCTAssertEqual(evaluate(command: command, name: "python3").recommendation.strategy, .gentleDevServer, command)
        }
    }

    func testDockLaunchedAppIsNotCalledOrphaned() {
        let slack = evaluate(command: "/Applications/Slack.app/Contents/MacOS/Slack", name: "Slack", parent: 1,
                             path: "/Applications/Slack.app/Contents/MacOS/Slack")
        let titles = slack.decisionScore.factors.map(\.title)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("orphan") || $0.contains("Background") }, "\(titles)")
        XCTAssertEqual(slack.recommendation.strategy, .quitApp)
    }

    func testEvidenceTitlesAreUnique() {
        let history = KillHistorySummary(signatureID: "sig", operationCount: 5, gracefulSuccessRate: 0.8, forceRate: 0.6,
                                         survivorRate: 0, averageReclaimBytes: 0, commonDenialCount: 0)
        let locked = KillTarget(unresolved: ProcessIdentity(pid: 801, startTimeSeconds: 1, startTimeMicroseconds: 0), state: .locked, reason: "root")
        let evaluation = evaluate(command: "node /app/node_modules/.bin/vite", name: "node", history: history, level: .critical,
                                  forecast: .runaway, label: "Swift build", parent: 1, locked: [locked])
        let titles = evaluation.decisionScore.factors.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count, "\(titles)")
        XCTAssertFalse(titles.contains("Active build caution"), "a label substring is not a build")
    }

    func testStaleFamilyIsForgottenNotHighRisk() {
        let evaluation = evaluate(command: "python3 train.py", name: "python3", level: .watch, forecast: .stale,
                                  reason: "Idle for 3 h with 2.1 GB resident")
        let radar = evaluation.decisionScore.factors.filter { $0.source == .radar }
        XCTAssertEqual(radar.map(\.title), ["Forgotten"])
        XCTAssertEqual(radar.first?.detail, "Idle for 3 h with 2.1 GB resident")
        XCTAssertEqual(radar.first?.weight, 10)
    }

    func testRadarFactorsNameWhatTheRadarSaw() {
        XCTAssertEqual(evaluate(command: "x", name: "x", forecast: .leaking).decisionScore.factors.filter { $0.source == .radar }.map(\.title), ["Leaking memory"])
        XCTAssertEqual(evaluate(command: "x", name: "x", level: .critical).decisionScore.factors.filter { $0.source == .radar }.map(\.title), ["Runaway"])
        XCTAssertTrue(evaluate(command: "x", name: "x", level: .hot).decisionScore.factors.filter { $0.source == .radar }.isEmpty)
    }

    func testRiskFactorsAreMarkedSoTheSheetCanSkipThem() {
        let evaluation = evaluate(command: "npm install", name: "npm")
        let partial = evaluation.decisionScore.factors.first { $0.title == "Half-finished install" }
        XCTAssertEqual(partial?.source, .risk)
        XCTAssertEqual(evaluation.decisionScore.factors.first { $0.title == "Identity verified" }?.source, .tree)
    }

    func testReadinessCautionOnlyForRealReasonsToWait() {
        XCTAssertEqual(evaluate(command: "cruncher", name: "cruncher").decisionScore.readiness(hasTargets: true), .ready)
        XCTAssertEqual(evaluate(command: "npm install", name: "npm").decisionScore.readiness(hasTargets: true), .caution)
        XCTAssertEqual(evaluate(command: "cruncher", name: "cruncher").decisionScore.readiness(hasTargets: false), .locked)
    }

    // MARK: - Fixtures

    func evaluate(
        command: String,
        name: String,
        memory: UInt64 = 200_000_000,
        cpu: Double = 5,
        history: KillHistorySummary? = nil,
        level: GhostLevel = .watch,
        forecast: ForecastState = .quiet,
        label: String = "Process family",
        reason: String = "",
        parent: Int32 = 700,
        path: String = "",
        locked: [KillTarget] = [],
        forceKillDelay: TimeInterval = 2
    ) -> InterventionPolicyEvaluation {
        let identity = ProcessIdentity(pid: 800, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let lite = KillProcessLite(identity: identity, parentPID: parent, userID: 501, ownerName: "me", name: name, status: 2,
                                   flags: 0, processGroupID: 800, openFileCount: 0, physicalFootprintBytes: memory, cpuPercent: cpu)
        let target = KillTarget(process: lite, depth: 0, state: .ready, reason: "owned", rootIdentity: identity)
        let metadata = KillFamilyMetadata(signatureID: "sig", displayName: name, scoreValue: 90, scoreLevel: level,
                                          forecastState: forecast, devKindLabel: label, memoryBytes: memory,
                                          cpuPercent: cpu, childCount: 0, forecastReason: reason)
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 800, parentPID: parent, name: name, executablePath: path, commandLine: command, isRoot: true)],
            ancestors: [], parentIsLaunchd: parent == 1
        )
        let plan = KillPlan(rootIdentity: identity, targetIdentities: [identity], protectedPIDs: [], displayName: name,
                            familyMetadata: metadata, killHistory: history, workload: workload)
        return InterventionPolicyEngine().evaluate(
            plan: plan, targets: [target], locked: locked, stale: [], recycled: [],
            reclaim: KillReclaimEstimate(memoryBytes: memory, cpuPercent: cpu, confidence: 0.8, sourceText: "test"),
            diff: .empty, forceKillDelay: forceKillDelay
        )
    }
}
