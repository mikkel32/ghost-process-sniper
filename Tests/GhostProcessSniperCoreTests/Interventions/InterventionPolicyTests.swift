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
        forceKillDelay: TimeInterval = 2
    ) -> InterventionPolicyEvaluation {
        let identity = ProcessIdentity(pid: 800, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let lite = KillProcessLite(identity: identity, parentPID: 700, userID: 501, ownerName: "me", name: name, status: 2,
                                   flags: 0, processGroupID: 800, openFileCount: 0, physicalFootprintBytes: memory, cpuPercent: cpu)
        let target = KillTarget(process: lite, depth: 0, state: .ready, reason: "owned", rootIdentity: identity)
        let metadata = KillFamilyMetadata(signatureID: "sig", displayName: name, scoreValue: 90, scoreLevel: level,
                                          forecastState: forecast, devKindLabel: label, memoryBytes: memory,
                                          cpuPercent: cpu, childCount: 0, isBackgroundOrOrphan: false)
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 800, parentPID: 700, name: name, executablePath: "", commandLine: command, isRoot: true)],
            ancestors: [], parentIsLaunchd: false
        )
        let plan = KillPlan(rootIdentity: identity, targetIdentities: [identity], protectedPIDs: [], displayName: name,
                            familyMetadata: metadata, killHistory: history, workload: workload)
        return InterventionPolicyEngine().evaluate(
            plan: plan, targets: [target], locked: [], stale: [], recycled: [],
            reclaim: KillReclaimEstimate(memoryBytes: memory, cpuPercent: cpu, confidence: 0.8, sourceText: "test"),
            diff: .empty, nearbyCount: 0, forceKillDelay: forceKillDelay
        )
    }
}
