import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ProcessFamilyAdHocTests: XCTestCase {
    private let me: UInt32 = 501

    func testTreeIsAssembledAndOwnershipIsSplit() {
        let root = process(100, parent: 1)
        let child = process(101, parent: 100, memory: 10_000_000, cpu: 20)
        let grandchild = process(102, parent: 101, memory: 5_000_000)
        let foreign = process(103, parent: 100, user: 0)
        let system = process(104, parent: 101, system: true)
        let unrelated = process(200, parent: 1)
        let sample = [unrelated, grandchild, root, foreign, child, system]

        let family = ProcessFamily.adHoc(rootedAt: root.identity, in: sample, currentUserID: uid_t(me))

        XCTAssertEqual(family?.root.identity, root.identity)
        XCTAssertEqual(Set(family?.members.map(\.pid) ?? []), [100, 101, 102, 103, 104])
        XCTAssertEqual(Set(family?.ownedIdentities ?? []), [root.identity, child.identity, grandchild.identity])
        XCTAssertEqual(family?.ownedIdentities.last, root.identity, "the root is stopped last")
        XCTAssertEqual(family?.protectedPIDs, [103, 104])
        XCTAssertEqual(family?.totalPhysicalFootprintBytes, 32_000_000 * 3 + 10_000_000 + 5_000_000)
        XCTAssertEqual(family?.totalCPUPercent ?? 0, 24, accuracy: 0.001)
        XCTAssertEqual(family?.score.level, .quiet)
        XCTAssertEqual(family?.forecast.state, .quiet)
        XCTAssertNil(family?.baseline)
        XCTAssertNil(family?.duplicateCluster)
    }

    func testMissingIdentityGivesNil() {
        let sample = [process(100, parent: 1)]
        let missing = ProcessIdentity(pid: 999, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        XCTAssertNil(ProcessFamily.adHoc(rootedAt: missing, in: sample, currentUserID: uid_t(me)))
    }

    func testRecycledPIDGivesNil() {
        let sample = [process(100, parent: 1, start: 2_000)]
        let stale = ProcessIdentity(pid: 100, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        XCTAssertNil(ProcessFamily.adHoc(rootedAt: stale, in: sample, currentUserID: uid_t(me)),
                     "same PID with a different start time is another process")
    }

    func testMembersAreCapped() {
        let root = process(1_000, parent: 1)
        let children = (0..<400).map { process(Int32(2_000 + $0), parent: 1_000) }

        let family = ProcessFamily.adHoc(rootedAt: root.identity, in: [root] + children, currentUserID: uid_t(me))

        XCTAssertEqual(family?.members.count, ProcessFamily.adHocMemberLimit)
        XCTAssertEqual(family?.members.first?.identity, root.identity)
    }

    func testSearchRowsKnowWhetherTheyCanBeStopped() {
        let mine = process(300, parent: 1, name: "sleeper")
        let theirs = process(301, parent: 1, name: "sleepwatcher", user: 0, system: true)
        var state = RadarConsoleState.default
        state.searchText = "sleep"
        let request = ConsoleProjectionRequest(
            source: .empty,
            incidents: [],
            state: state,
            families: [],
            processes: [mine, theirs],
            sampleRevision: 1
        )
        var index = ProcessSearchIndex(currentUserID: me)
        index.update(rows: [], families: [], processes: [mine, theirs], sampleRevision: 1, contentRevision: request.source.contentRevision)

        let rows = ConsoleDerivedSnapshot.build(request, index: index).search.processRows

        XCTAssertEqual(rows.first { $0.pid == 300 }?.isStoppable, true)
        XCTAssertEqual(rows.first { $0.pid == 301 }?.isStoppable, false)
    }

    private func process(
        _ pid: Int32,
        parent: Int32,
        name: String = "node",
        start: UInt64 = 1_000,
        user: UInt32 = 501,
        system: Bool = false,
        memory: UInt64 = 32_000_000,
        cpu: Double = 1
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
            parentPID: parent,
            userID: user,
            ownerName: user == 0 ? "root" : "me",
            name: name,
            executablePath: "/usr/local/bin/\(name)",
            commandLine: "\(name) --serve",
            residentMemoryBytes: memory,
            physicalFootprintBytes: memory,
            virtualMemoryBytes: memory * 2,
            cpuPercent: cpu,
            totalProcessorSeconds: 1,
            threadCount: 2,
            isSystemProcess: system,
            sampledAt: Date(timeIntervalSince1970: 10_000)
        )
    }
}
