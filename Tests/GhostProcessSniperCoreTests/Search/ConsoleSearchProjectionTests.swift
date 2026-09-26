import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ConsoleSearchProjectionTests: XCTestCase {
    private let root = metrics(100, "npm", command: "npm run dev")
    private let helper = metrics(101, "node", command: "node /app/node_modules/.bin/vite --port 5173", parent: 100, ports: [5173])
    private let safari = metrics(200, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", memory: 400_000_000)
    private let daemon = metrics(201, "cloudd", user: 0, memory: 0, cpuMeasured: false)

    func testHelpersAreSearchableThroughTheirFamily() {
        let result = project("vite")
        XCTAssertEqual(result.familyRows.map(\.familyKey), [npm.familyKey])
        let reason = result.search.familyMatches[npm.familyKey]?.reason ?? ""
        XCTAssertTrue(reason.contains("node (PID 101)"), reason)
        XCTAssertTrue(result.search.processRows.isEmpty, "a tracked helper is never listed again as untracked")
    }

    func testUntrackedProcessesAppearWithHonestMetrics() {
        let result = project("safari")
        XCTAssertTrue(result.familyRows.isEmpty)
        XCTAssertEqual(result.search.processRows.map(\.name), ["Safari"])
        XCTAssertEqual(result.search.processRows.first?.nameHighlights, [0..<6])

        let unreadable = project("cloudd").search.processRows.first
        XCTAssertEqual(unreadable?.memoryText, "\u{2014}", "an unreadable process shows a dash, not zero")
        XCTAssertEqual(unreadable?.cpuText, "\u{2014}")
    }

    func testFamilyFiltersAndRadarFlagsHideUntrackedProcesses() {
        XCTAssertTrue(project("safari", filter: .attention).search.processRows.isEmpty)
        XCTAssertTrue(project("safari is:hot").search.processRows.isEmpty)
        XCTAssertEqual(project("safari is:mine").search.processRows.map(\.name), ["Safari"])
    }

    func testRelevanceLeadsOnlyForPrioritySort() {
        let other = makeFamily(metrics(300, "node-exporter", command: "node-exporter"), memory: 900_000_000)
        let rows = project("node", families: [npm, other], sort: .smart).familyRows.map(\.displayName)
        XCTAssertEqual(rows.first, "node-exporter", "a name prefix outranks a helper name")
        let byName = project("node", families: [npm, other], sort: .name).familyRows.map(\.displayName)
        XCTAssertEqual(byName, ["node-exporter", "npm"])
    }

    func testIdleConsoleIgnoresSampleChurnButSearchFollowsIt() {
        var cache = ConsoleDerivedSnapshotCache()
        _ = cache.update(request("", sampleRevision: 1))
        _ = cache.update(request("", sampleRevision: 2))
        XCTAssertEqual(cache.missCount, 1, "without a search, new samples do not re-project")
        _ = cache.update(request("safari", sampleRevision: 2))
        _ = cache.update(request("safari", sampleRevision: 3))
        XCTAssertEqual(cache.missCount, 3, "while searching, every sample refreshes the results")
        _ = cache.update(request("safari", sampleRevision: 3))
        XCTAssertEqual(cache.hitCount, 2)
    }

    func testLeaksFilterUsesCredibleLeaksOnly() {
        let snapshot = snapshot([npm])
        XCTAssertTrue(snapshot.families(query: "", filter: .leaking, sort: .smart).isEmpty,
                      "positive memory velocity alone is not a leak")
    }

    // MARK: - Fixtures

    private var npm: ProcessFamily { makeFamily(root, members: [root, helper]) }

    private func project(
        _ text: String,
        families: [ProcessFamily]? = nil,
        filter: RadarFilter = .all,
        sort: RadarSort = .smart
    ) -> ConsoleDerivedSnapshot {
        var cache = ConsoleDerivedSnapshotCache()
        return cache.update(request(text, families: families, filter: filter, sort: sort))
    }

    private func request(
        _ text: String,
        families: [ProcessFamily]? = nil,
        filter: RadarFilter = .all,
        sort: RadarSort = .smart,
        sampleRevision: UInt64 = 1
    ) -> ConsoleProjectionRequest {
        let families = families ?? [npm]
        var state = RadarConsoleState.default
        state.searchText = text
        state.familyFilter = filter
        state.familySort = sort
        return ConsoleProjectionRequest(
            source: snapshot(families),
            incidents: [],
            state: state,
            families: families,
            processes: families.flatMap(\.members) + [safari, daemon],
            sampleRevision: sampleRevision
        )
    }

    private func snapshot(_ families: [ProcessFamily]) -> RadarConsoleSnapshot {
        RadarConsoleSnapshot.build(
            families: families,
            summary: ProcessFamilyBuilder(currentUserID: 501).summary(for: families),
            incidents: [],
            rules: [],
            metrics: .empty,
            health: .starting,
            storeHealth: .empty,
            storeError: nil,
            previous: nil,
            generatedAt: Date(timeIntervalSince1970: 10_000)
        )
    }

    private func makeFamily(_ root: ProcessMetrics, members: [ProcessMetrics]? = nil, memory: UInt64 = 64_000_000) -> ProcessFamily {
        let members = members ?? [root]
        return ProcessFamily(
            root: root,
            members: members,
            totalResidentMemoryBytes: memory,
            totalPhysicalFootprintBytes: memory,
            totalCPUPercent: 1,
            devConfidence: 0.9,
            commandHints: [root.commandLine],
            trend: TrendMetrics(memoryVelocityMegabytesPerMinute: 4, cpuSlopePerMinute: 0, memoryPoints: []),
            score: GhostScore(value: 10, level: .quiet, reasons: []),
            ownedIdentities: members.map(\.identity),
            protectedPIDs: []
        )
    }
}

private func metrics(
    _ pid: Int32,
    _ name: String,
    command: String? = nil,
    path: String = "",
    parent: Int32 = 1,
    user: UInt32 = UInt32(geteuid()),
    memory: UInt64 = 32_000_000,
    cpuMeasured: Bool = true,
    ports: [Int] = []
) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
        parentPID: parent,
        userID: user,
        ownerName: user == 0 ? "root" : "me",
        name: name,
        executablePath: path,
        commandLine: command ?? name,
        residentMemoryBytes: memory,
        physicalFootprintBytes: memory,
        virtualMemoryBytes: memory * 2,
        cpuPercent: 0,
        totalProcessorSeconds: 1,
        threadCount: 2,
        isSystemProcess: user == 0,
        sampledAt: Date(timeIntervalSince1970: 10_000),
        forensics: ProcessForensics(currentDirectory: nil, rootDirectory: nil, openFileCount: nil, socketCount: nil,
                                    listeningPorts: ports, isPartial: false, notes: []),
        cpuMeasurementStatus: cpuMeasured ? .fresh : .unavailable
    )
}
