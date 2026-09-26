import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class LeanPublishTests: XCTestCase {
    func testKeySortMatchesTheSmartComparatorWithTies() {
        var generator = SeededGenerator(seed: 0x5eed)
        let families = (0..<500).map { family($0, generator: &generator) }
        let snapshot = RadarConsoleSnapshot.build(
            families: families, summary: .empty, incidents: [], rules: [], metrics: .empty,
            health: .starting, storeHealth: .empty, storeError: nil, previous: nil,
            generatedAt: Date(timeIntervalSince1970: 10_000), detailSignatures: []
        )
        let oracle = families.map { FamilyTriageViewModel(family: $0) }
            .sorted { FamilyTriageViewModel.areInIncreasingOrder($0, $1, by: .smart) }
        XCTAssertEqual(snapshot.families.map(\.id), oracle.map(\.id))
        XCTAssertEqual(snapshot.families, oracle)
        XCTAssertEqual(snapshot.compact.allRows, oracle.map(CompactSidebarRowModel.init(item:)))
    }

    func testPublishComputesTheRevisionOfItsInputs() {
        var generator = SeededGenerator(seed: 7)
        let families = (0..<20).map { family($0, generator: &generator) }
        let payload = RadarPublishPayload.build(
            families: families, summary: .empty, rules: [], incidents: [], health: .starting,
            storeHealth: .empty, storeError: nil, performance: .empty, previous: nil,
            generatedAt: Date(timeIntervalSince1970: 10_000), detailSignatures: []
        )
        let expected = SnapshotContentRevision.compute(
            families: families, summary: .empty, incidents: [], rules: [], duplicateClusters: []
        )
        XCTAssertEqual(payload.state.consoleSnapshot.contentRevision, expected)
        XCTAssertEqual(payload.delta.nextRevision, expected)
    }

    private func family(_ index: Int, generator: inout SeededGenerator) -> ProcessFamily {
        let levels: [GhostLevel] = [.quiet, .watch, .hot, .critical]
        let level = levels[Int.random(in: 0..<levels.count, using: &generator)]
        let heatValue = [20.0, 55, 80][Int.random(in: 0..<3, using: &generator)]
        let score = [10.0, 40, 70][Int.random(in: 0..<3, using: &generator)]
        let memory = UInt64([64, 128, 256][Int.random(in: 0..<3, using: &generator)]) * 1_048_576
        let cpu = [0.0, 12, 90][Int.random(in: 0..<3, using: &generator)]
        let velocity = [0.0, 5][Int.random(in: 0..<2, using: &generator)]
        let identity = ProcessIdentity(pid: Int32(60_000 + index), startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let date = Date(timeIntervalSince1970: 10_000)
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: "worker",
                                  executablePath: "/usr/local/bin/worker", commandLine: "worker --job",
                                  residentMemoryBytes: memory, physicalFootprintBytes: memory,
                                  virtualMemoryBytes: memory * 2, cpuPercent: cpu, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        let heat = GhostHeat(value: heatValue, level: level, confidence: 0.5, evidence: [], sustainedSignalCount: 0)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: memory,
                             totalPhysicalFootprintBytes: memory, totalCPUPercent: cpu,
                             devConfidence: 0.9, commandHints: [root.commandLine],
                             trend: TrendMetrics(memoryVelocityMegabytesPerMinute: velocity, cpuSlopePerMinute: 0, memoryPoints: []),
                             score: GhostScore(value: score, level: level, reasons: [], heat: heat),
                             ownedIdentities: [identity], protectedPIDs: [], lastScoredAt: date)
    }
}

/// SplitMix64, so failures reproduce.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
