import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class DuplicateCullPlanTests: XCTestCase {
    private let me: UInt32 = 501

    func testStopsOrphanedCopiesAndKeepsTheOnesInUse() {
        let helper = process(50, parent: 1, name: "Code Helper (Plugin)", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", cpu: 3)
        let used = [tsserver(101, parent: 50), tsserver(102, parent: 50)]
        let orphans = (103...109).map { tsserver(Int32($0), parent: 1) }
        let cluster = cluster(used + orphans)

        let plan = DuplicateCullPlan.plan(for: cluster, sample: [helper] + used + orphans, currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, 7)
        XCTAssertEqual(Set(plan.stopTargets.map(\.pid)), Set(103...109))
        XCTAssertEqual(plan.decisions.filter { $0.verdict == .keep }.map(\.reason), ["Used by Code Helper (Plugin)", "Used by Code Helper (Plugin)"])
        XCTAssertEqual(plan.reclaimBytes, 7 * 40_000_000)
        XCTAssertTrue(plan.summary.hasPrefix("Stop 7 orphaned copies"), plan.summary)
    }

    func testBusyCopiesAreKept() {
        let busy = tsserver(201, parent: 1, cpu: 12)
        let serving = tsserver(202, parent: 1, ports: [5173])
        let idle = [tsserver(203, parent: 1), tsserver(204, parent: 1)]
        let sample = [busy, serving] + idle

        let plan = DuplicateCullPlan.plan(for: cluster(sample), sample: sample, currentUserID: uid_t(me))

        XCTAssertEqual(plan.decision(for: busy)?.verdict, .keep)
        XCTAssertEqual(plan.decision(for: busy)?.rule, .busy)
        XCTAssertEqual(plan.decision(for: serving)?.rule, .busy)
        XCTAssertTrue(plan.decision(for: serving)?.reason.contains("5173") ?? false)
        XCTAssertEqual(Set(plan.stopTargets.map(\.pid)), [203, 204])
    }

    func testCopyWhoseChildIsBusyIsKept() {
        let parent = tsserver(301, parent: 1)
        let worker = process(310, parent: 301, name: "typingsInstaller", cpu: 40)
        let other = [tsserver(302, parent: 1), tsserver(303, parent: 1)]
        let sample = [parent, worker] + other

        let plan = DuplicateCullPlan.plan(for: cluster([parent] + other), sample: sample, currentUserID: uid_t(me))

        XCTAssertEqual(plan.decision(for: parent)?.rule, .busyChild)
        XCTAssertEqual(plan.stopCount, 2)
    }

    func testAnotherOwnersCopyIsNeverStopped() {
        let foreign = tsserver(401, parent: 1, user: 0)
        let system = tsserver(402, parent: 1, system: true)
        let mine = [tsserver(403, parent: 1), tsserver(404, parent: 1)]
        let sample = [foreign, system] + mine

        let plan = DuplicateCullPlan.plan(for: cluster(sample), sample: sample, currentUserID: uid_t(me))

        XCTAssertEqual(plan.decision(for: foreign)?.rule, .notYours)
        XCTAssertEqual(plan.decision(for: system)?.rule, .notYours)
        XCTAssertEqual(Set(plan.stopTargets.map(\.pid)), [403, 404])
    }

    func testLaunchdAgentsAndAppsWithParentOneAreKept() {
        let loginItem = process(501, parent: 1, name: "Helper",
                                path: "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")
        let appSupport = process(502, parent: 1, name: "Helper", path: "/Users/me/Library/Application Support/Foo/Helper")
        let xpc = process(503, parent: 1, name: "Helper", path: "/Users/me/Apps/Foo.app/Contents/XPCServices/Helper.xpc/Contents/MacOS/Helper")
        let app = process(504, parent: 1, name: "Foo", path: "/Users/me/Apps/Foo.app/Contents/MacOS/Foo")
        let sample = [loginItem, appSupport, xpc, app]

        let plan = DuplicateCullPlan.plan(for: cluster(sample), sample: sample, currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, 0)
        XCTAssertEqual(plan.decision(for: loginItem)?.rule, .launchdService)
        XCTAssertEqual(plan.decision(for: appSupport)?.rule, .launchdService)
        XCTAssertEqual(plan.decision(for: xpc)?.rule, .launchdService)
        XCTAssertEqual(plan.decision(for: app)?.rule, .openedApp)
    }

    func testCopiesAttachedToLiveParentsStopNothing() {
        let shell = process(60, parent: 1, name: "zsh")
        let editor = process(61, parent: 1, name: "nvim")
        let copies = [tsserver(601, parent: 60), tsserver(602, parent: 61), tsserver(603, parent: 61)]

        let plan = DuplicateCullPlan.plan(for: cluster(copies), sample: [shell, editor] + copies, currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, 0)
        XCTAssertTrue(plan.stopTargets.isEmpty)
        XCTAssertEqual(plan.reclaimBytes, 0)
        XCTAssertEqual(plan.decision(for: copies[0])?.reason, "Used by zsh")
        XCTAssertTrue(plan.summary.hasPrefix("Nothing to stop"), plan.summary)
    }

    func testParentOutsideTheScanIsKept() {
        let copies = [tsserver(701, parent: 70), tsserver(702, parent: 70)]

        let plan = DuplicateCullPlan.plan(for: cluster(copies), sample: copies, currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, 0)
        XCTAssertEqual(plan.decision(for: copies[0])?.rule, .parentOutsideScan)
    }

    func testRecycledIdentityIsIgnored() {
        let clustered = tsserver(801, parent: 1, start: 1_000)
        let recycled = tsserver(801, parent: 1, start: 2_000)
        let others = [tsserver(802, parent: 1), tsserver(803, parent: 1)]

        let plan = DuplicateCullPlan.plan(for: cluster([clustered] + others), sample: [recycled] + others, currentUserID: uid_t(me))

        XCTAssertNil(plan.decisions.first { $0.pid == 801 })
        XCTAssertFalse(plan.stopTargets.contains { $0.pid == 801 })
        XCTAssertEqual(plan.decisions.count, 2)
    }

    func testNewestCopyIsKeptWhenEveryCopyIsOrphaned() {
        let copies = [tsserver(901, parent: 1, start: 1_000), tsserver(902, parent: 1, start: 3_000), tsserver(903, parent: 1, start: 2_000)]

        let plan = DuplicateCullPlan.plan(for: cluster(copies), sample: copies, currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, 2)
        XCTAssertEqual(plan.decision(for: copies[1])?.rule, .keptNewest)
    }

    func testStopsAreCapped() {
        let copies = (0..<40).map { tsserver(Int32(1_000 + $0), parent: 1) }
        let keeper = process(90, parent: 1, name: "zsh")
        let used = tsserver(1_100, parent: 90)

        let plan = DuplicateCullPlan.plan(for: cluster(copies + [used]), sample: copies + [keeper, used], currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, DuplicateCullPlan.maximumStops)
        XCTAssertEqual(plan.decisions.filter { $0.rule == .overLimit }.count, 40 - DuplicateCullPlan.maximumStops)
    }

    func testCopyStartedByAStoppedCopyGoesWithIt() {
        let orphan = tsserver(1_201, parent: 1)
        let child = tsserver(1_202, parent: 1_201, start: 1_100)
        let shell = process(95, parent: 1, name: "zsh")
        let used = tsserver(1_203, parent: 95)
        let sample = [orphan, child, shell, used]

        let plan = DuplicateCullPlan.plan(for: cluster([orphan, child, used]), sample: sample, currentUserID: uid_t(me))

        XCTAssertEqual(plan.stopCount, 2)
        XCTAssertEqual(plan.stopTargets.map(\.pid), [1_201])
        XCTAssertEqual(plan.decision(for: child)?.stopsWith, orphan.identity)
        XCTAssertEqual(plan.decision(for: used)?.verdict, .keep)
    }

    func testPlansForSeveralClustersMatchSinglePlans() {
        let first = [tsserver(1_301, parent: 1), tsserver(1_302, parent: 1)]
        let second = [process(1_401, parent: 1, name: "vite"), process(1_402, parent: 1, name: "vite", cpu: 30)]
        let clusters = [cluster(first), cluster(second, name: "vite")]
        let sample = first + second

        let plans = DuplicateCullPlan.plans(for: clusters, sample: sample, currentUserID: uid_t(me))

        XCTAssertEqual(plans.count, 2)
        for cluster in clusters {
            XCTAssertEqual(plans[cluster.id], DuplicateCullPlan.plan(for: cluster, sample: sample, currentUserID: uid_t(me)))
        }
    }

    private func tsserver(
        _ pid: Int32,
        parent: Int32,
        start: UInt64 = 1_000,
        user: UInt32 = 501,
        system: Bool = false,
        cpu: Double = 0.2,
        ports: [Int] = []
    ) -> ProcessMetrics {
        process(pid, parent: parent, name: "tsserver", path: "/opt/homebrew/bin/node", start: start,
                user: user, system: system, cpu: cpu, ports: ports)
    }

    private func process(
        _ pid: Int32,
        parent: Int32,
        name: String,
        path: String? = nil,
        start: UInt64 = 1_000,
        user: UInt32 = 501,
        system: Bool = false,
        cpu: Double = 0.2,
        ports: [Int] = []
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
            parentPID: parent,
            userID: user,
            ownerName: user == 0 ? "root" : "me",
            name: name,
            executablePath: path ?? "/usr/local/bin/\(name)",
            commandLine: name,
            residentMemoryBytes: 40_000_000,
            physicalFootprintBytes: 40_000_000,
            virtualMemoryBytes: 80_000_000,
            cpuPercent: cpu,
            totalProcessorSeconds: 1,
            threadCount: 4,
            isSystemProcess: system,
            sampledAt: Date(timeIntervalSince1970: 10_000),
            forensics: ProcessForensics(
                currentDirectory: nil, rootDirectory: nil, openFileCount: nil, socketCount: nil,
                listeningPorts: ports, isPartial: false, notes: []
            )
        )
    }

    private func cluster(_ members: [ProcessMetrics], name: String = "tsserver") -> DuplicateProcessCluster {
        DuplicateProcessCluster(
            key: DuplicateClusterKey(kind: .commandPrefix, value: name, displayName: name),
            displayName: name,
            members: members,
            independentRootCount: members.count,
            likelyKind: .nodeServer,
            classificationReason: "test"
        )
    }
}

private extension DuplicateCullPlan {
    func decision(for process: ProcessMetrics) -> Decision? {
        decisions.first { $0.identity == process.identity }
    }
}
