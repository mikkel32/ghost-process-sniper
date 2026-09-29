import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The Duplicates page is for small tools that add up. A leftover pair that
/// frees a few MB is a cluster the detector keeps, but not a row, a badge, an
/// Overview card or a menu-bar count.
final class DuplicateRowsTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    /// One copy, started `startedAgo` seconds before the fixture clock. Pids
    /// stay clear of 1: launchd is the parent of every copy.
    private func copy(
        _ pid: Int32, megabytes: Double, cpu: Double = 0, ports: [Int] = [], startedAgo: TimeInterval = 3_600
    ) -> ProcessMetrics {
        let base = Fixture.process(pid: pid, name: "tool", path: "/Users/dev/.local/bin/tool", command: "tool --serve",
                                   megabytes: megabytes, cpu: cpu, started: Fixture.now.addingTimeInterval(-startedAgo))
        return ProcessMetrics(
            identity: base.identity, parentPID: 1, userID: base.userID, ownerName: base.ownerName, name: base.name,
            executablePath: base.executablePath, commandLine: base.commandLine,
            residentMemoryBytes: base.residentMemoryBytes, physicalFootprintBytes: base.physicalFootprintBytes,
            virtualMemoryBytes: base.virtualMemoryBytes, cpuPercent: cpu, totalProcessorSeconds: 0,
            threadCount: base.threadCount, isSystemProcess: false, sampledAt: base.sampledAt,
            forensics: ProcessForensics(currentDirectory: nil, rootDirectory: nil, openFileCount: nil, socketCount: nil,
                                        listeningPorts: ports, isPartial: false, notes: [])
        )
    }

    /// Copies started independently; the newest is the one to keep, the
    /// others are what stopping would free.
    private func cluster(
        _ members: [ProcessMetrics], kind: DevProcessKind = .cliTool, isInternal: Bool = false
    ) -> DuplicateProcessCluster {
        let newest = members.max { $0.identity.startTimeSeconds < $1.identity.startTimeSeconds }
        return DuplicateProcessCluster(
            key: DuplicateClusterKey(kind: .executablePath, value: "/users/dev/.local/bin/tool", displayName: "tool"),
            displayName: "tool", members: members, independentRootCount: members.count, likelyKind: kind,
            classificationReason: "test", isInternalToSingleFamily: isInternal,
            copyRootIdentities: members.map(\.identity), keepIdentity: newest?.identity
        )
    }

    private func pair(megabytes: Double, cpu: Double = 0, olderPorts: [Int] = [], keptPorts: [Int] = []) -> DuplicateProcessCluster {
        cluster([
            copy(101, megabytes: megabytes, cpu: cpu, ports: olderPorts, startedAgo: 7_200),
            copy(102, megabytes: megabytes, cpu: cpu, ports: keptPorts, startedAgo: 60),
        ])
    }

    private func listed(_ clusters: [DuplicateProcessCluster]) -> [String] {
        DuplicateClusterViewModel.rows(from: clusters).map(\.countText)
    }

    // MARK: Label

    /// A cluster of unclassified user binaries says what it is, not that it is
    /// heavy: the one in the screenshots freed 2 MB.
    func testAnUnclassifiedToolIsARepeatedToolNotAHeavyProcess() {
        XCTAssertEqual(DuplicateClusterViewModel(cluster: cluster([copy(101, megabytes: 2), copy(102, megabytes: 2)], kind: .unknownHeavy)).kindText,
                       "Repeated tool")
        // Every kind the classifier really recognised keeps its own name.
        XCTAssertEqual(DuplicateClusterViewModel(cluster: cluster([copy(101, megabytes: 2), copy(102, megabytes: 2)], kind: .nodeServer)).kindText,
                       "Node server")
        XCTAssertEqual(DuplicateClusterViewModel(cluster: cluster([copy(101, megabytes: 2), copy(102, megabytes: 2)], kind: .cliTool)).kindText,
                       "CLI tool")
    }

    // MARK: Floor

    func testATinyIdlePairIsNotListed() {
        XCTAssertEqual(listed([pair(megabytes: 2, cpu: 0.5)]), [], "two 2 MB copies at 1% CPU in all")
    }

    func testAPairThatAddsUpInMemoryIsListed() {
        XCTAssertEqual(listed([pair(megabytes: 80)]), ["2"])
        // 32 MiB in all is the floor; just under it is a tiny pair.
        XCTAssertEqual(listed([pair(megabytes: 16)]), ["2"])
        XCTAssertEqual(listed([pair(megabytes: 15.9)]), [])
    }

    func testAPairThatBurnsCPUIsListed() {
        XCTAssertEqual(listed([pair(megabytes: 2, cpu: 3)]), ["2"], "6% of one core in all")
        XCTAssertEqual(listed([pair(megabytes: 2, cpu: 2)]), [], "4% is idle noise")
    }

    func testManyCopiesAreListedHoweverSmall() {
        let four = cluster((0..<4).map { copy(Int32($0) + 110, megabytes: 1, startedAgo: 3_600 - Double($0)) })
        XCTAssertEqual(four.independentRootCount, 4)
        XCTAssertEqual(listed([four]), ["4"])
        let three = cluster((0..<3).map { copy(Int32($0) + 110, megabytes: 1, startedAgo: 3_600 - Double($0)) })
        XCTAssertEqual(listed([three]), [])
    }

    /// A tiny copy that serves a port may be one somebody still points at.
    /// Only a copy to stop counts: the kept copy is meant to serve.
    func testATinyPairWhoseOlderCopyServesAPortIsListed() {
        XCTAssertEqual(listed([pair(megabytes: 2, olderPorts: [3000])]), ["2"])
        XCTAssertEqual(listed([pair(megabytes: 2, keptPorts: [5175])]), [])
    }

    func testCopiesInsideOneFamilyAreStillHidden() {
        let pool = cluster([copy(101, megabytes: 80), copy(102, megabytes: 80)], isInternal: true)
        XCTAssertEqual(listed([pool]), [])
    }

    func testTheFloorOnlyHidesRowsNotTheClusters() {
        let tiny = pair(megabytes: 2)
        XCTAssertTrue(tiny.countsAsIndependentCopies)
        XCTAssertEqual(tiny.redundantRootIdentities.count, 1, "it can still be stopped from its family")
        let set = DuplicateClusterSet(clusters: [pair(megabytes: 80), tiny], promotedIdentities: [], detectorMilliseconds: 0)
        XCTAssertEqual(set.clusters.count, 2)
        XCTAssertEqual(set.visibleClusters.count, 1, "what the page, the badge and the menu bar count")
    }

    func testRowsKeepTheirOrder() {
        let big = pair(megabytes: 200)
        let small = pair(megabytes: 20)
        XCTAssertEqual(DuplicateClusterViewModel.rows(from: [small, big]).map(\.cluster.totalPhysicalFootprintBytes),
                       [big.totalPhysicalFootprintBytes, small.totalPhysicalFootprintBytes])
    }

    // MARK: The counts that agree with the page

    /// A cluster that starts to add up is a new row, even when its CPU moved
    /// less than the tolerance a snapshot ignores: a page that waited for a
    /// larger change would not show it.
    func testAClusterCrossingTheFloorChangesTheContentRevision() {
        func measure(cpu: Double, previous: SnapshotContentBaseline?) -> SnapshotContentBaseline {
            SnapshotContentBaseline.measure(
                families: [], summary: .empty, incidents: [], rules: [],
                duplicateClusters: [pair(megabytes: 2, cpu: cpu)], previous: previous)
        }
        let idle = measure(cpu: 0.5, previous: nil)
        XCTAssertEqual(measure(cpu: 2, previous: idle).revision, idle.revision, "4% in all is still under the floor, and noise")
        let busy = measure(cpu: 4, previous: idle)
        XCTAssertNotEqual(busy.revision, idle.revision, "8% in all is a row now")
        XCTAssertNotEqual(measure(cpu: 0.5, previous: busy).revision, busy.revision, "and it leaves again")
    }

    /// The menu bar's "N duplicate clusters" counts what the page lists.
    func testTheMenuBarCountsWhatThePageLists() async throws {
        func listedCount(megabytes: Double) async throws -> (metric: Int, rows: Int) {
            let worker = RadarRefreshWorker(
                store: nil,
                builder: ProcessFamilyBuilder(currentUserID: 501, processorCount: 8, physicalMemoryBytes: 32 << 30,
                                              directoryExists: { _ in true }))
            let processes = [
                Fixture.process(pid: 3_000, name: "node", path: "/usr/local/bin/node", command: "node /Users/dev/api/server.js",
                                megabytes: megabytes, started: Fixture.now.addingTimeInterval(-7_200)),
                Fixture.process(pid: 3_001, name: "node", path: "/usr/local/bin/node", command: "node /Users/dev/api/server.js",
                                megabytes: megabytes, started: Fixture.now.addingTimeInterval(-60)),
            ]
            let request = RefreshRequest(settings: .smart, currentFamilies: [], currentIncidents: [], currentStoreHealth: .empty,
                                         previousConsoleSnapshot: nil, uiVisible: true, focusedSignatureIDs: [],
                                         now: Fixture.now, startedAt: Fixture.now)
            let outcome = await worker.ingest(
                batch: ProcessSampleBatch(processes: processes, sampledAt: Fixture.now, stats: .empty), request: request)
            return (outcome.payload.state.performanceMetrics.smoothness.duplicateClusterCount,
                    outcome.payload.state.consoleSnapshot.duplicateRows.count)
        }
        let tiny = try await listedCount(megabytes: 2)
        XCTAssertEqual(tiny.metric, 0)
        XCTAssertEqual(tiny.rows, 0)
        let big = try await listedCount(megabytes: 200)
        XCTAssertEqual(big.metric, 1)
        XCTAssertEqual(big.rows, 1)
    }
}
