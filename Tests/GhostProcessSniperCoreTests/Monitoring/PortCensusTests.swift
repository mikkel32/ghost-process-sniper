import XCTest
@testable import GhostProcessSniperCore

final class PortCensusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testQuietClassifiedFamilyBecomesAHintAndACensusCandidate() {
        let dev = devFamily(pids: [3_000, 3_001])
        let plain = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(9, pid: 4_000))
        let demand = FamilySamplingDemand(families: [dev, plain], focusedKeys: [])
        XCTAssertEqual(demand.devIdentities, Set(dev.members.map(\.identity)))
        XCTAssertTrue(demand.candidateIdentities.isEmpty, "a quiet family is not a candidate")

        var scheduler = RadarScheduler(pressureProvider: { .nominal })
        let plan = scheduler.plan(settings: .smart, families: [dev, plain], uiVisible: true, now: now)
        XCTAssertEqual(plan.hintedIdentities, Set(dev.members.map(\.identity)))
        XCTAssertEqual(plan.portCensusIdentities, Set(dev.members.map(\.identity)))
    }

    func testAPlainAppIsNotDeveloperWork() {
        let app = classified(RefreshPerformanceFixture.process(9, pid: 4_000), devConfidence: 0.1,
                             DevClassification(kind: .unknownHeavy, confidence: 0.2, reason: "Heavy or watched process"))
        let weak = classified(RefreshPerformanceFixture.process(10, pid: 4_100), devConfidence: 0.1,
                              DevClassification(kind: .nodeServer, confidence: 0.3, reason: "node"))
        let strong = classified(RefreshPerformanceFixture.process(11, pid: 4_200), devConfidence: 0.1,
                                DevClassification(kind: .nodeServer, confidence: 0.9, reason: "vite"))
        let demand = FamilySamplingDemand(families: [app, weak, strong], focusedKeys: [])
        XCTAssertEqual(demand.devIdentities, [strong.root.identity], "every family is classified; only real evidence counts")
    }

    func testCensusSlotsAreBoundedAndRotate() {
        let dev = devFamily(pids: (0..<10).map { 3_000 + Int32($0) })
        var scheduler = RadarScheduler(pressureProvider: { .nominal })
        var covered = Set<ProcessIdentity>()
        for step in 0..<5 {
            let plan = scheduler.plan(settings: .smart, families: [dev], uiVisible: false,
                                      now: now.addingTimeInterval(Double(step) * 3.5))
            XCTAssertLessThanOrEqual(plan.portCensusIdentities.count, 2)
            XCTAssertTrue(covered.isDisjoint(with: plan.portCensusIdentities), "oldest reads go first")
            covered.formUnion(plan.portCensusIdentities)
        }
        XCTAssertEqual(covered, Set(dev.members.map(\.identity)))
        let rested = scheduler.plan(settings: .smart, families: [dev], uiVisible: false,
                                    now: now.addingTimeInterval(20))
        XCTAssertTrue(rested.portCensusIdentities.isEmpty, "nothing is due again before the census age")
    }

    func testNoCensusWhenOptionalForensicsArePaused() {
        let dev = devFamily(pids: [3_000])
        var scheduler = RadarScheduler(pressureProvider: { .serious })
        let plan = scheduler.plan(settings: .smart, families: [dev], uiVisible: true, now: now)
        XCTAssertTrue(plan.portCensusIdentities.isEmpty)
        XCTAssertFalse(plan.allowsOptionalForensics)
    }

    func testCensusFindsTheQuietServersPortWithoutFullForensics() async throws {
        let source = FakeProbeSource.table(count: 20)
        source.update(pid: 1_007) { $0.ports = [3000] }
        let sampler = NativeProcessSampler(source: source)
        let first = try await sampler.sample(plan: .fixture(at: 0))
        let identity = try XCTUnwrap(first.processes.first { $0.pid == 1_007 }?.identity)

        let census = try await sampler.sample(plan: .fixture(at: 1) { $0.portCensusIdentities = [identity] })
        XCTAssertEqual(census.processes.first { $0.pid == 1_007 }?.forensics.listeningPorts, [3000])
        XCTAssertEqual(census.stats.portCensusCount, 1)
        XCTAssertEqual(source.recordedCalls.forensics, 0, "the census reads ports only")

        let later = try await sampler.sample(plan: .fixture(at: 30))
        XCTAssertEqual(later.processes.first { $0.pid == 1_007 }?.forensics.listeningPorts, [3000],
                       "a quiet process keeps its census ports")
    }

    func testOnDemandCensusCoversEverySameUserProcessWithOpenFiles() async throws {
        let source = FakeProbeSource.table(count: 30)
        source.update(pid: 1_003) { $0.ports = [5173] }
        source.update(pid: 1_004) { $0.openFiles = 0 }
        source.update(pid: 1_005) { $0.userID = 0 }
        let sampler = NativeProcessSampler(source: source)
        let batch = try await sampler.sample(plan: .fixture(at: 0) {
            $0.portCensusAll = true
            $0.allowsOptionalForensics = false
        })
        XCTAssertEqual(batch.stats.portCensusCount, 28)
        XCTAssertEqual(batch.processes.first { $0.pid == 1_003 }?.forensics.listeningPorts, [5173])
    }

    func testCensusMergeKeepsAFullReadsFacts() {
        var cache = ForensicsCache()
        let identity = ProcessIdentity(pid: 5, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let full = ProcessForensics(currentDirectory: "/work", rootDirectory: "/", openFileCount: 9,
                                    socketCount: 2, listeningPorts: [], isPartial: false, notes: [])
        cache.update(full, for: identity, at: now)
        let merged = cache.mergePorts([8080], for: identity, at: now.addingTimeInterval(30))
        XCTAssertEqual(merged.currentDirectory, "/work")
        XCTAssertEqual(merged.listeningPorts, [8080])
        XCTAssertEqual(cache.entry(for: identity)?.refreshedAt, now, "the full read keeps its own age")
        XCTAssertEqual(cache.entry(for: identity)?.portsRefreshedAt, now.addingTimeInterval(30))
    }

    /// Docker's backend can publish a dozen ports; search and the stop's
    /// freed-port list must see the high ones too.
    func testEveryListeningPortIsKeptForSearchAndTheStop() throws {
        let ports: Set<Int> = [3000, 3001, 5432, 6379, 8000, 8001, 8025, 8080, 9000, 9200]
        var cache = ForensicsCache()
        let identity = ProcessIdentity(pid: 7, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let merged = cache.mergePorts(ports, for: identity, at: now)
        XCTAssertEqual(merged.listeningPorts, ports.sorted())

        let subject = SearchSubject(
            root: SearchableProcess(pid: 7, name: "com.docker.backend", commandLine: "com.docker.backend",
                                    executablePath: "", ownerName: "dev", listeningPorts: merged.listeningPorts),
            measurements: SearchMeasurements(cpuPercent: 1, memoryBytes: 1, gpuPercent: 0, threads: 1), flags: [])
        let outcome = ProcessSearchEngine.search(ProcessSearchQuery("port:9200"), families: [], processes: [subject])
        XCTAssertEqual(outcome.processes.count, 1)

        let risk = KillRiskAssessor().assess(KillWorkloadProfile(
            processes: [KillWorkloadProcess(pid: 7, parentPID: 1, name: "node", executablePath: "/usr/local/bin/node",
                                            commandLine: "node server.js", listeningPorts: merged.listeningPorts, isRoot: true)],
            ancestors: [], parentIsLaunchd: false))
        XCTAssertEqual(risk.freedPorts.count, 10)
        XCTAssertEqual(risk.risks.first { $0.kind == .freesPorts }?.title, "Frees 10 ports")
    }

    func testPortsOnlyEntryIsNotANegativeCacheHit() {
        var cache = ForensicsCache()
        let identity = ProcessIdentity(pid: 5, startTimeSeconds: 1, startTimeMicroseconds: 0)
        cache.mergePorts([3000], for: identity, at: now)
        XCTAssertEqual(cache.entry(for: identity)?.isPortsOnly, true)
        XCTAssertNil(cache.negativeEntry(for: identity, now: now, maxAge: 120),
                     "a census must not block the first full read")
    }

    private func classified(_ root: ProcessMetrics, devConfidence: Double, _ classification: DevClassification) -> ProcessFamily {
        let base = RefreshPerformanceFixture.family(root)
        return ProcessFamily(root: base.root, members: base.members,
            totalResidentMemoryBytes: base.totalResidentMemoryBytes,
            totalPhysicalFootprintBytes: base.totalPhysicalFootprintBytes,
            totalCPUPercent: base.totalCPUPercent, devConfidence: devConfidence, commandHints: [],
            trend: base.trend, score: base.score, ownedIdentities: base.ownedIdentities, protectedPIDs: [],
            classification: classification)
    }

    private func devFamily(pids: [Int32]) -> ProcessFamily {
        let members = pids.map { RefreshPerformanceFixture.process(Int($0), pid: $0) }
        let base = RefreshPerformanceFixture.family(members[0], members: members)
        return ProcessFamily(root: base.root, members: base.members,
            totalResidentMemoryBytes: base.totalResidentMemoryBytes,
            totalPhysicalFootprintBytes: base.totalPhysicalFootprintBytes,
            totalCPUPercent: base.totalCPUPercent, devConfidence: 0.9, commandHints: [],
            trend: base.trend, score: base.score, ownedIdentities: base.ownedIdentities, protectedPIDs: [],
            classification: DevClassification(kind: .nodeServer, confidence: 0.9, reason: "vite"))
    }
}
