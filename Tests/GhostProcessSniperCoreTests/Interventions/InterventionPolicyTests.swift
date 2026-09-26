import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// How the policy engine chooses a strategy and its timing from what the
/// workload is, not from how big or hot the family looks.
final class InterventionPolicyTests: XCTestCase {
    func testRiskGraceIsAFloorForEveryStrategy() {
        let rebase = PolicyFixture.evaluate(command: "git rebase main", name: "git")
        XCTAssertEqual(rebase.recommendation.strategy, .standard)
        XCTAssertEqual(rebase.profile.verificationSchedule.graceSeconds, 5)
        XCTAssertEqual(rebase.profile.phases.first?.waitAfterSeconds, 5)

        let install = PolicyFixture.evaluate(command: "npm install", name: "npm")
        XCTAssertEqual(install.profile.verificationSchedule.graceSeconds, 4)
        XCTAssertEqual(install.profile.phases.first?.waitAfterSeconds, 4)

        let devServer = PolicyFixture.evaluate(command: "node /app/node_modules/.bin/vite", name: "node")
        XCTAssertEqual(devServer.recommendation.strategy, .gentleDevServer)
        XCTAssertEqual(devServer.profile.verificationSchedule.graceSeconds, 1.2)
    }

    func testDataLossWorkloadsAreNeverStubborn() {
        let forced = KillHistorySummary(signatureID: "x", operationCount: 12, gracefulSuccessRate: 0, forceRate: 1,
                                        survivorRate: 0, averageReclaimBytes: 0, commonDenialCount: 0)
        for (name, command) in [("npm", "npm install"), ("git", "git commit -m wip"), ("postgres", "postgres -D /var/pg")] {
            let evaluation = PolicyFixture.evaluate(command: command, name: name, history: forced, level: .critical, forecast: .runaway)
            XCTAssertNotEqual(evaluation.recommendation.strategy, .stubbornRunaway, command)
            XCTAssertGreaterThanOrEqual(evaluation.profile.verificationSchedule.graceSeconds, 4, command)
        }
    }

    func testLargeFootprintAloneDoesNotShortenGrace() {
        let evaluation = PolicyFixture.evaluate(command: "cruncher --input big.bin", name: "cruncher", memory: 3 * 1_073_741_824,
                                  cpu: 250, level: .critical, forecast: .runaway)
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
        XCTAssertEqual(evaluation.profile.verificationSchedule.graceSeconds, 2)
    }

    func testStaleFamilyIsNotStubborn() {
        let evaluation = PolicyFixture.evaluate(command: "python3 train.py", name: "python3", memory: 2 * 1_073_741_824,
                                  level: .hot, forecast: .stale)
        XCTAssertNotEqual(evaluation.recommendation.strategy, .stubbornRunaway)
        XCTAssertEqual(evaluation.profile.verificationSchedule.graceSeconds, 2)
    }

    func testDevServerLabelWithoutDevServerArgvIsNotGentle() {
        let evaluation = PolicyFixture.evaluate(command: "node scripts/migrate.js", name: "node", label: "Node server")
        XCTAssertEqual(evaluation.recommendation.strategy, .standard, "the risk assessor is the only classifier")
    }

    func testCommonDevServersAreRecognized() {
        for command in ["python3 -m http.server 8000", "streamlit run app.py", "fastapi dev main.py",
                        "python manage.py runserver", "jupyter-lab --no-browser"] {
            XCTAssertEqual(PolicyFixture.evaluate(command: command, name: "python3").recommendation.strategy, .gentleDevServer, command)
        }
    }

    func testDockLaunchedAppIsNotCalledOrphaned() {
        let slack = PolicyFixture.evaluate(command: "/Applications/Slack.app/Contents/MacOS/Slack", name: "Slack", parent: 1,
                             path: "/Applications/Slack.app/Contents/MacOS/Slack")
        let titles = slack.decisionScore.factors.map(\.title)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("orphan") || $0.contains("Background") }, "\(titles)")
        XCTAssertEqual(slack.recommendation.strategy, .quitApp)
    }

    func testEvidenceTitlesAreUnique() {
        let history = KillHistorySummary(signatureID: "sig", operationCount: 5, gracefulSuccessRate: 0.8, forceRate: 0.6,
                                         survivorRate: 0, averageReclaimBytes: 0, commonDenialCount: 0)
        let locked = KillTarget(unresolved: ProcessIdentity(pid: 801, startTimeSeconds: 1, startTimeMicroseconds: 0), state: .locked, reason: "root")
        let evaluation = PolicyFixture.evaluate(command: "node /app/node_modules/.bin/vite", name: "node", history: history, level: .critical,
                                  forecast: .runaway, label: "Swift build", parent: 1, locked: [locked])
        let titles = evaluation.decisionScore.factors.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count, "\(titles)")
        XCTAssertFalse(titles.contains("Active build caution"), "a label substring is not a build")
    }

    func testStaleFamilyIsForgottenNotHighRisk() {
        let evaluation = PolicyFixture.evaluate(command: "python3 train.py", name: "python3", level: .watch, forecast: .stale,
                                  reason: "Idle for 3 h with 2.1 GB resident")
        let radar = evaluation.decisionScore.factors.filter { $0.source == .radar }
        XCTAssertEqual(radar.map(\.title), ["Forgotten"])
        XCTAssertEqual(radar.first?.detail, "Idle for 3 h with 2.1 GB resident")
        XCTAssertEqual(radar.first?.weight, 10)
    }

    func testRadarFactorsNameWhatTheRadarSaw() {
        XCTAssertEqual(PolicyFixture.evaluate(command: "x", name: "x", forecast: .leaking).decisionScore.factors.filter { $0.source == .radar }.map(\.title), ["Leaking memory"])
        XCTAssertEqual(PolicyFixture.evaluate(command: "x", name: "x", level: .critical).decisionScore.factors.filter { $0.source == .radar }.map(\.title), ["Runaway"])
        XCTAssertTrue(PolicyFixture.evaluate(command: "x", name: "x", level: .hot).decisionScore.factors.filter { $0.source == .radar }.isEmpty)
    }

    func testRiskFactorsAreMarkedSoTheSheetCanSkipThem() {
        let evaluation = PolicyFixture.evaluate(command: "npm install", name: "npm")
        let partial = evaluation.decisionScore.factors.first { $0.title == "Half-finished install" }
        XCTAssertEqual(partial?.source, .risk)
        XCTAssertEqual(evaluation.decisionScore.factors.first { $0.title == "Identity verified" }?.source, .tree)
    }

    func testReadinessCautionOnlyForRealReasonsToWait() {
        XCTAssertEqual(PolicyFixture.evaluate(command: "cruncher", name: "cruncher").decisionScore.readiness(hasTargets: true), .ready)
        XCTAssertEqual(PolicyFixture.evaluate(command: "npm install", name: "npm").decisionScore.readiness(hasTargets: true), .caution)
        XCTAssertEqual(PolicyFixture.evaluate(command: "cruncher", name: "cruncher").decisionScore.readiness(hasTargets: false), .locked)
    }
}
