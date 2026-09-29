import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The advisor proposes stopping what keeps a family alive, or only the
/// helper that is the problem, and every proposal goes through a preview.
final class KillTargetAdvisorTests: XCTestCase {
    private let pm2 = KillWorkloadAncestor(pid: 499, name: "PM2 v5.3.0: God Daemon", executablePath: "/usr/local/bin/node",
                                           commandLine: "PM2 v5.3.0: God Daemon (/Users/me/.pm2)")
    private let nodemon = KillWorkloadAncestor(pid: 499, name: "node", executablePath: "/usr/local/bin/node",
                                               commandLine: "node /usr/local/lib/node_modules/nodemon/bin/nodemon.js server.js")

    func testPm2ParentBecomesRecommendedAlternative() async throws {
        let (table, server) = supervisedServer()
        let preview = await killer(table).preview(plan: serverPlan(server, supervisor: pm2), forceKillDelay: 2)
        let alternative = try XCTUnwrap(preview.alternatives.first { $0.kind == .stopSupervisor })
        XCTAssertEqual(alternative.identity.pid, 499)
        XCTAssertTrue(alternative.isRecommended)
        XCTAssertEqual(preview.recommendedAlternative, alternative)
        XCTAssertEqual(alternative.title, "Stop PM2 instead")
        XCTAssertTrue(alternative.detail.contains("stops every PM2 app"), alternative.detail)
        XCTAssertFalse(alternative.isPreselected)

        let supervisorPreview = await killer(table).preview(plan: alternative.plan, forceKillDelay: 2)
        XCTAssertEqual(Set(supervisorPreview.targetPIDs), [499, 500], "stopping PM2 takes its apps with it")
        XCTAssertNil(supervisorPreview.riskAssessment.supervisor)
        XCTAssertTrue(supervisorPreview.alternatives.isEmpty)
    }

    func testSupervisorStopKeepsTheRadarNumbersOfItsApps() async throws {
        let (table, server) = supervisedServer()
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 500, parentPID: 499, name: "node", executablePath: "/usr/local/bin/node",
                                            commandLine: "node /app/node_modules/.bin/vite", isRoot: true,
                                            identity: server.identity, cpuPercent: 180, memoryBytes: 900_000_000)],
            ancestors: [pm2],
            parentIsLaunchd: false
        )
        let plan = KillPlan(rootIdentity: server.identity, targetIdentities: [server.identity], protectedPIDs: [],
                            displayName: "vite", workload: workload)
        let preview = await killer(table).preview(plan: plan, forceKillDelay: 2)
        let alternative = try XCTUnwrap(preview.alternatives.first { $0.kind == .stopSupervisor })

        let app = alternative.plan.workload?.processes.first { $0.pid == 500 }
        XCTAssertEqual(app?.identity, server.identity)
        XCTAssertEqual(app?.cpuPercent, 180, "the kill snapshot cannot measure CPU; the radar's reading is all there is")
        XCTAssertEqual(app?.memoryBytes, 900_000_000)
    }

    func testRespawnedLastStopPreselectsTheSupervisor() async throws {
        let (table, server) = supervisedServer()
        let respawned = KillOutcomePosterior.empty.updating(
            with: KillOutcomeObservation(strategy: .gentleDevServer, outcome: .respawned, latencySeconds: 0.2, censored: false),
            at: Date()
        )
        let plan = serverPlan(server, supervisor: pm2, outcomes: KillOutcomeHistory(signature: [.gentleDevServer: respawned]))
        let preview = await killer(table).preview(plan: plan, forceKillDelay: 2)
        XCTAssertEqual(preview.alternatives.first { $0.kind == .stopSupervisor }?.isPreselected, true)
    }

    func testNodemonIsNotRecommendedAsTarget() async {
        let (table, server) = supervisedServer()
        let preview = await killer(table).preview(plan: serverPlan(server, supervisor: nodemon), forceKillDelay: 2)
        XCTAssertEqual(preview.riskAssessment.supervisor?.kind, .nodemon)
        XCTAssertFalse(preview.alternatives.contains { $0.kind == .stopSupervisor },
                       "nodemon waits for the next save; stopping only its child is what you want")
    }

    func testSupervisorOwnedBySomeoneElseIsNotOffered() async {
        let (table, server) = supervisedServer(supervisorUser: 0)
        let preview = await killer(table).preview(plan: serverPlan(server, supervisor: pm2), forceKillDelay: 2)
        XCTAssertTrue(preview.alternatives.isEmpty)
    }

    func testRecycledSupervisorPIDIsNotOffered() async {
        // PM2 exited after the sample and an unrelated process of the same
        // user took PID 499; the server now hangs off launchd.
        let (table, server) = supervisedServer(serverParent: 1)
        let preview = await killer(table).preview(plan: serverPlan(server, supervisor: pm2), forceKillDelay: 2)
        XCTAssertFalse(preview.alternatives.contains { $0.kind == .stopSupervisor },
                       "a PID that is no longer the server's ancestor must not become a stop target")
    }

    func testSupervisorFurtherUpTheChainIsOffered() async throws {
        let table = FakeProcessTable()
        table.add(KillProcessLite.fake(pid: 499, name: "node"))
        table.add(KillProcessLite.fake(pid: 450, parent: 499, name: "sh"))
        let server = KillProcessLite.fake(pid: 500, parent: 450, name: "node")
        table.add(server)
        let preview = await killer(table).preview(plan: serverPlan(server, supervisor: pm2), forceKillDelay: 2)
        let alternative = try XCTUnwrap(preview.alternatives.first { $0.kind == .stopSupervisor })
        XCTAssertEqual(alternative.identity.pid, 499)
    }

    func testDominantHelperOffersHelperOnlyStop() async throws {
        let table = FakeProcessTable()
        let gigabyte: UInt64 = 1_073_741_824
        let app = KillProcessLite.fake(pid: 900, name: "Code", memory: gigabyte / 10)
        let renderer = KillProcessLite.fake(pid: 901, parent: 900, name: "Code Helper (Renderer)", memory: gigabyte * 31 / 10)
        let gpu = KillProcessLite.fake(pid: 902, parent: 900, name: "Code Helper (GPU)", memory: gigabyte / 5)
        [app, renderer, gpu].forEach { table.add($0) }
        let root = "/Applications/Visual Studio Code.app/Contents"
        let workload = KillWorkloadProfile(
            processes: [
                KillWorkloadProcess(pid: 900, parentPID: 1, name: "Code", executablePath: "\(root)/MacOS/Code",
                                    commandLine: "\(root)/MacOS/Code", isRoot: true),
                KillWorkloadProcess(pid: 901, parentPID: 900, name: "Code Helper (Renderer)",
                                    executablePath: "\(root)/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)",
                                    commandLine: "Code Helper (Renderer) --type=renderer"),
                KillWorkloadProcess(pid: 902, parentPID: 900, name: "Code Helper (GPU)",
                                    executablePath: "\(root)/Frameworks/Code Helper (GPU).app/Contents/MacOS/Code Helper (GPU)",
                                    commandLine: "Code Helper (GPU) --type=gpu-process")
            ],
            ancestors: [],
            parentIsLaunchd: true
        )
        let plan = KillPlan(rootIdentity: app.identity, targetIdentities: [app, renderer, gpu].map(\.identity), protectedPIDs: [],
                            displayName: "Visual Studio Code", workload: workload)
        let preview = await killer(table).preview(plan: plan, forceKillDelay: 2)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .quitApp)
        let alternative = try XCTUnwrap(preview.alternatives.first { $0.kind == .stopHelperOnly })
        XCTAssertEqual(alternative.identity, renderer.identity)
        XCTAssertEqual(alternative.title, "Stop only Code Helper (Renderer)")
        XCTAssertEqual(alternative.detail, "Stop only Code Helper (Renderer): frees 3.1 GB of 3.4 GB; the app stays open.")
        XCTAssertTrue(alternative.isRecommended)
        XCTAssertEqual(alternative.plan.scope, .singleRoot)
        XCTAssertEqual(alternative.plan.targetIdentities, [renderer.identity])

        let helperPreview = await killer(table).preview(plan: alternative.plan, forceKillDelay: 2)
        XCTAssertEqual(helperPreview.targetPIDs, [901])
        XCTAssertNotEqual(helperPreview.strategyRecommendation.strategy, .quitApp, "a helper is not asked to quit like the app")
    }

    func testAHelperTheSnapshotDidNotMeasureCanStillBeTheDominantOne() async throws {
        let table = FakeProcessTable()
        let mebibyte: UInt64 = 1_048_576
        let app = KillProcessLite.fake(pid: 920, name: "Code", memory: 50 * mebibyte)
        let gpu = KillProcessLite.fake(pid: 921, parent: 920, name: "Code Helper (GPU)", memory: 120 * mebibyte)
        // Past the kill snapshot's read budget in a big tree, its own row says 0.
        let renderer = KillProcessLite.fake(pid: 922, parent: 920, name: "Code Helper (Renderer)", memory: 0)
        [app, gpu, renderer].forEach { table.add($0) }
        let root = "/Applications/Visual Studio Code.app/Contents"
        let workload = KillWorkloadProfile(
            processes: [
                KillWorkloadProcess(pid: 920, parentPID: 1, name: "Code", executablePath: "\(root)/MacOS/Code",
                                    commandLine: "\(root)/MacOS/Code", isRoot: true, identity: app.identity,
                                    memoryBytes: 50 * mebibyte),
                KillWorkloadProcess(pid: 921, parentPID: 920, name: "Code Helper (GPU)",
                                    executablePath: "\(root)/Frameworks/Code Helper (GPU).app/Contents/MacOS/Code Helper (GPU)",
                                    commandLine: "Code Helper (GPU) --type=gpu-process", identity: gpu.identity,
                                    memoryBytes: 120 * mebibyte),
                KillWorkloadProcess(pid: 922, parentPID: 920, name: "Code Helper (Renderer)",
                                    executablePath: "\(root)/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)",
                                    commandLine: "Code Helper (Renderer) --type=renderer", identity: renderer.identity,
                                    memoryBytes: 900 * mebibyte)
            ],
            ancestors: [],
            parentIsLaunchd: true
        )
        let plan = KillPlan(rootIdentity: app.identity, targetIdentities: [app, gpu, renderer].map(\.identity), protectedPIDs: [],
                            displayName: "Visual Studio Code", workload: workload)

        let preview = await killer(table).preview(plan: plan, forceKillDelay: 2)

        let alternative = try XCTUnwrap(preview.alternatives.first { $0.kind == .stopHelperOnly })
        XCTAssertEqual(alternative.identity, renderer.identity, "not the small helper the snapshot happened to measure")
        XCTAssertEqual(alternative.detail, "Stop only Code Helper (Renderer): frees \(RadarFormat.bytes(900 * mebibyte)) of "
                       + "\(RadarFormat.bytes(1_070 * mebibyte)); the app stays open.")
    }

    func testBalancedFamilyGetsNoHelperOnlyStop() async {
        let table = FakeProcessTable()
        let root = KillProcessLite.fake(pid: 910, name: "server", memory: 400 * 1_048_576)
        let worker = KillProcessLite.fake(pid: 911, parent: 910, name: "worker", memory: 500 * 1_048_576)
        [root, worker].forEach { table.add($0) }
        let plan = KillPlan(rootIdentity: root.identity, targetIdentities: [root.identity, worker.identity], protectedPIDs: [],
                            displayName: "server")
        let preview = await killer(table).preview(plan: plan, forceKillDelay: 2)
        XCTAssertTrue(preview.alternatives.isEmpty)
    }

    // MARK: - Fixtures

    private func supervisedServer(supervisorUser: UInt32 = 501, serverParent: Int32 = 499) -> (FakeProcessTable, KillProcessLite) {
        let table = FakeProcessTable()
        let supervisor = KillProcessLite.fake(pid: 499, name: "node", userID: supervisorUser)
        let server = KillProcessLite.fake(pid: 500, parent: serverParent, name: "node")
        table.add(supervisor)
        table.add(server)
        return (table, server)
    }

    private func serverPlan(_ server: KillProcessLite, supervisor: KillWorkloadAncestor, outcomes: KillOutcomeHistory = .empty) -> KillPlan {
        let workload = KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 500, parentPID: 499, name: "node", executablePath: "/usr/local/bin/node",
                                            commandLine: "node /app/node_modules/.bin/vite", isRoot: true)],
            ancestors: [supervisor],
            parentIsLaunchd: false
        )
        return KillPlan(rootIdentity: server.identity, targetIdentities: [server.identity], protectedPIDs: [], displayName: "vite",
                        workload: workload, strategyCalibrations: outcomes)
    }

    private func killer(_ table: FakeProcessTable) -> ProcessKiller {
        ProcessKiller(snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper)
    }
}
