import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The content revision gates every rebuild and redraw, so ordinary CPU
/// noise must leave it alone while real changes still move it.
final class ContentRevisionStabilityTests: XCTestCase {
    func testCPUNoiseOnAWorkstationMostlyPublishesDiagnosticsOnly() async {
        let worker = RadarRefreshWorker(store: nil, builder: Self.builder())
        let base = DevWorkstationFixture.processes(count: 600, tick: 0)
        var cpuSeconds = Dictionary(uniqueKeysWithValues: base.map { ($0.identity, $0.totalProcessorSeconds) })
        var families: [ProcessFamily] = []
        var incidents: [RadarIncident] = []
        var previous: RadarConsoleSnapshot?
        var diagnosticsOnly = 0
        for tick in 0..<40 {
            let now = DevWorkstationFixture.date(tick: tick)
            let processes = base.enumerated().map { index, process -> ProcessMetrics in
                let noise = sin(Double(tick * 7 + index * 13))
                let cpu = process.cpuPercent > 0 ? max(0, process.cpuPercent + noise) : 0
                cpuSeconds[process.identity, default: 0] += cpu / 100 * DevWorkstationFixture.cadence
                return Self.process(process, cpu: cpu, totalProcessorSeconds: cpuSeconds[process.identity]!, at: now)
            }
            let request = RefreshRequest(settings: .smart, currentFamilies: families, currentIncidents: incidents,
                                         currentStoreHealth: .empty, previousConsoleSnapshot: previous, uiVisible: true,
                                         focusedSignatureIDs: [], now: now, startedAt: now)
            let outcome = await worker.ingest(batch: ProcessSampleBatch(processes: processes, sampledAt: now, stats: .empty),
                                              request: request)
            if tick >= 20, outcome.payload.delta.mode == .diagnosticsOnly { diagnosticsOnly += 1 }
            previous = outcome.payload.state.consoleSnapshot
            families = outcome.families
            incidents = outcome.incidents
        }
        XCTAssertGreaterThanOrEqual(diagnosticsOnly, 15, "\(diagnosticsOnly)/20 noisy ticks skipped the content rebuild")
    }

    func testFamilyOrderDoesNotChangeTheRevision() async {
        let (families, summary, incidents, rules) = await Self.settledWorkstation()
        XCTAssertGreaterThan(families.count, 20)
        let forward = SnapshotContentRevision.compute(families: families, summary: summary, incidents: incidents, rules: rules)
        let reversed = SnapshotContentRevision.compute(families: families.reversed(), summary: summary,
                                                       incidents: incidents, rules: rules)
        var shuffled = families
        shuffled.swapAt(0, shuffled.count - 1)
        shuffled.swapAt(3, 11)
        let swapped = SnapshotContentRevision.compute(families: shuffled, summary: summary, incidents: incidents, rules: rules)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, swapped)
    }

    func testAFamilyTurningHotOrGrowingStillChangesTheRevision() async {
        let (families, summary, incidents, rules) = await Self.settledWorkstation()
        let index = families.firstIndex { $0.score.level < .hot }!
        let before = SnapshotContentRevision.compute(families: families, summary: summary, incidents: incidents, rules: rules)

        var hot = families
        let family = families[index]
        hot[index] = family.enriched(score: GhostScore(value: family.score.value, level: .hot, reasons: family.score.reasons))
        XCTAssertNotEqual(SnapshotContentRevision.compute(families: hot, summary: summary, incidents: incidents, rules: rules), before)

        var grown = families
        grown[index] = Self.growing(family, by: 200 * 1_048_576)
        XCTAssertNotEqual(SnapshotContentRevision.compute(families: grown, summary: summary, incidents: incidents, rules: rules), before)
    }

    func testSmallDriftHoldsTheRevisionUntilItAddsUpToATolerance() async {
        let (families, summary, incidents, rules) = await Self.settledWorkstation()
        let index = families.firstIndex { $0.score.level < .hot && $0.forecast.state < .leaking && $0.totalCPUPercent < 50 }!
        func measure(cpu: Double, previous: SnapshotContentBaseline?) -> SnapshotContentBaseline {
            var changed = families
            changed[index] = Self.resized(families[index], cpu: cpu)
            return SnapshotContentBaseline.measure(families: changed, summary: summary, incidents: incidents, rules: rules,
                                                   duplicateClusters: [], previous: previous)
        }
        let cpu = families[index].totalCPUPercent
        let shown = measure(cpu: cpu, previous: nil)
        let nudged = measure(cpu: cpu + 6, previous: shown)
        XCTAssertEqual(nudged.revision, shown.revision, "a few points of CPU are noise")
        XCTAssertEqual(measure(cpu: cpu + 3, previous: nudged).revision, shown.revision)
        let drifted = measure(cpu: cpu + 12, previous: nudged)
        XCTAssertNotEqual(drifted.revision, shown.revision, "drift is measured from the shown value, not the last sample")
        XCTAssertEqual(measure(cpu: cpu + 14, previous: drifted).revision, drifted.revision, "the change re-anchors")
    }

    private static func settledWorkstation() async -> ([ProcessFamily], RadarSummary, [RadarIncident], [RadarRule]) {
        let worker = RadarRefreshWorker(store: nil, builder: builder())
        var outcome: RefreshOutcome?
        for tick in 0..<4 {
            let now = DevWorkstationFixture.date(tick: tick)
            let request = RefreshRequest(settings: .smart, currentFamilies: outcome?.families ?? [], currentIncidents: [],
                                         currentStoreHealth: .empty, previousConsoleSnapshot: outcome?.payload.state.consoleSnapshot,
                                         uiVisible: true, focusedSignatureIDs: [], now: now, startedAt: now)
            let batch = ProcessSampleBatch(processes: DevWorkstationFixture.processes(count: 600, tick: tick), sampledAt: now, stats: .empty)
            outcome = await worker.ingest(batch: batch, request: request)
        }
        return (outcome!.families, outcome!.summary, outcome!.incidents, outcome!.rules)
    }

    private static func growing(_ family: ProcessFamily, by bytes: UInt64) -> ProcessFamily {
        resized(family, bytes: bytes)
    }

    private static func resized(_ family: ProcessFamily, bytes: UInt64 = 0, cpu: Double? = nil) -> ProcessFamily {
        ProcessFamily(root: family.root, members: family.members, totalResidentMemoryBytes: family.totalResidentMemoryBytes + bytes,
                      totalPhysicalFootprintBytes: family.totalPhysicalFootprintBytes + bytes,
                      totalCPUPercent: cpu ?? family.totalCPUPercent,
                      totalGPUPercent: family.totalGPUPercent, devConfidence: family.devConfidence, commandHints: family.commandHints,
                      trend: family.trend, score: family.score, ownedIdentities: family.ownedIdentities,
                      protectedPIDs: family.protectedPIDs, signature: family.signature, suggestions: family.suggestions,
                      alertState: family.alertState, forecast: family.forecast, signatureVersion: family.signatureVersion,
                      lastScoredAt: family.lastScoredAt, classification: family.classification,
                      hardwareSignals: family.hardwareSignals, coverage: family.coverage)
    }

    private static func builder() -> ProcessFamilyBuilder {
        ProcessFamilyBuilder(currentUserID: DevWorkstationFixture.user, processorCount: 8,
                             physicalMemoryBytes: 32 << 30, directoryExists: { _ in true })
    }

    private static func process(_ process: ProcessMetrics, cpu: Double, totalProcessorSeconds: Double, at now: Date) -> ProcessMetrics {
        ProcessMetrics(identity: process.identity, parentPID: process.parentPID, userID: process.userID, ownerName: process.ownerName,
                       name: process.name, executablePath: process.executablePath, commandLine: process.commandLine,
                       residentMemoryBytes: process.residentMemoryBytes, physicalFootprintBytes: process.physicalFootprintBytes,
                       virtualMemoryBytes: process.virtualMemoryBytes, cpuPercent: cpu, totalProcessorSeconds: totalProcessorSeconds,
                       threadCount: process.threadCount, isSystemProcess: process.isSystemProcess, sampledAt: now)
    }
}
