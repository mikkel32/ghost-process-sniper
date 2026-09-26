import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The risk is judged on what the stop will actually hit, and the stop
/// never reaches through a process that belongs to someone else.
final class KillStopSetTests: XCTestCase {
    func testNestedDatabaseInTreeTriggersCarefulShutdown() async {
        let runner = Self.metrics(1500, "node", command: "node /usr/local/bin/foreman start")
        let web = Self.metrics(1501, "node", command: "node server.js", parent: 1500)
        let postgres = Self.metrics(1502, "postgres", command: KillFixture.postgresCommand, parent: 1500)
        let backend = Self.metrics(1503, "postgres", command: "postgres: checkpointer", parent: 1502)
        let sample = [runner, web, postgres, backend]
        // The radar gave postgres a family of its own.
        let family = Self.family(runner, members: [runner, web])

        let workload = KillWorkloadProfile(root: runner, sampleIndex: Dictionary(grouping: sample, by: \.parentPID), family: family)
        let table = FakeProcessTable()
        sample.forEach { table.add(KillProcessLite(process: $0, status: 2, processGroupID: $0.pid)) }
        let preview = await table.killer().preview(plan: family.killPlan(workload: workload), forceKillDelay: 2)

        XCTAssertEqual(Set(workload.processes.map(\.pid)), [1500, 1501, 1502, 1503])
        XCTAssertEqual(workload.root?.pid, 1500)
        XCTAssertEqual(preview.riskAssessment.kind, .dataStore)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .carefulShutdown)
        XCTAssertTrue(preview.riskAssessment.hazards.contains { $0.title == "Database writes" })
        XCTAssertNil(preview.riskAssessment.rootShutdownSignal, "the runner is not the database; the whole tree gets SIGTERM")
    }

    func testStopSetWorkloadCarriesIdentityAndRadarNumbers() {
        let root = Self.metrics(1510, "node", command: "node server.js", cpu: 250)
        let workload = KillWorkloadProfile(root: root, sampleIndex: [:], family: Self.family(root, members: [root]))

        XCTAssertEqual(workload.root?.identity, root.identity)
        XCTAssertEqual(workload.root?.cpuPercent, 250)
        XCTAssertEqual(workload.root?.memoryBytes, root.memoryForScoringBytes)
    }

    func testDescendantsBehindForeignOwnedParentAreLocked() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 1520, name: "runner")
        let login = KillProcessLite.fake(pid: 1521, parent: 1520, name: "login", userID: 0)
        let shell = KillProcessLite.fake(pid: 1522, parent: 1521, name: "zsh")
        let server = KillProcessLite.fake(pid: 1523, parent: 1522, name: "node")
        let helper = KillProcessLite.fake(pid: 1524, parent: 1520, name: "helper")
        [app, login, shell, server, helper].forEach { table.add($0) }

        let preview = await table.killer().preview(plan: .fixture(app), forceKillDelay: 2)

        XCTAssertEqual(Set(preview.targetPIDs), [1520, 1524])
        let locked = Dictionary(preview.lockedTargets.map { ($0.pid, $0.reason) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(locked[1521], "Owned by root")
        XCTAssertEqual(locked[1522], "Runs under root-owned login (PID 1521)")
        XCTAssertEqual(locked[1523], "Runs under root-owned login (PID 1521)")
    }

    // MARK: - Fixtures

    private static func metrics(_ pid: Int32, _ name: String, command: String, parent: Int32 = 1, cpu: Double = 5) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "me", name: name, executablePath: "", commandLine: command,
            residentMemoryBytes: 100_000_000, physicalFootprintBytes: 80_000_000, virtualMemoryBytes: 400_000_000,
            cpuPercent: cpu, totalProcessorSeconds: 10, threadCount: 4, isSystemProcess: false, sampledAt: Date()
        )
    }

    private static func family(_ root: ProcessMetrics, members: [ProcessMetrics]) -> ProcessFamily {
        ProcessFamily(root: root, members: members, totalResidentMemoryBytes: members.reduce(0) { $0 + $1.residentMemoryBytes },
                      totalPhysicalFootprintBytes: members.reduce(0) { $0 + $1.physicalFootprintBytes },
                      totalCPUPercent: members.reduce(0) { $0 + $1.cpuPercent }, devConfidence: 0.9,
                      commandHints: [root.commandLine], trend: .empty, score: GhostScore(value: 0, level: .quiet, reasons: []),
                      ownedIdentities: members.map(\.identity), protectedPIDs: [], lastScoredAt: root.sampledAt)
    }
}
