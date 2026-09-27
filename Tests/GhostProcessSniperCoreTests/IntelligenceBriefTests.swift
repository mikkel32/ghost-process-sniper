import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class IntelligenceBriefTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 30_000)

    func testConfirmedTroubleOutranksAHotterUnconfirmedSpike() {
        let spike = family(pid: 900, name: "spike", heat: heat(90, confirmed: false))
        let confirmed = family(pid: 910, name: "steady", heat: heat(80, confirmed: true))
        let brief = snapshot([spike, confirmed], processes: []).compact.intelligenceBrief

        XCTAssertEqual(brief.familyKey, confirmed.familyKey)
        XCTAssertEqual(brief.eyebrow, "Recommended now")
    }

    func testUnconfirmedSpikeIsStillTheFallbackTarget() {
        let spike = family(pid: 900, name: "spike", heat: heat(90, confirmed: false))
        let brief = snapshot([spike], processes: []).compact.intelligenceBrief
        XCTAssertEqual(brief.familyKey, spike.familyKey)
        XCTAssertEqual(brief.eyebrow, "Confirming activity")
        XCTAssertNil(brief.stopConsequence)
    }

    func testRecommendationSaysWhatStoppingWillDo() {
        let supervisor = process(pid: 950, parent: 1, name: "nodemon", command: "node /usr/local/bin/nodemon server.js")
        let server = family(pid: 960, parent: supervisor.pid, name: "node", heat: heat(80, confirmed: true))
        let brief = snapshot([server], processes: [supervisor, server.root]).compact.intelligenceBrief

        XCTAssertEqual(brief.familyKey, server.familyKey)
        XCTAssertTrue(brief.recommendation.contains("nodemon"), brief.recommendation)
        XCTAssertEqual(brief.actionTitle, "Review supervisor")
        let risk = KillRiskAssessor().assess(KillWorkloadProfile(family: server, sample: [supervisor, server.root]))
        XCTAssertEqual(brief.stopConsequence, risk.headline)
    }

    func testDataStoreIsStoppedSafely() {
        let database = family(pid: 970, name: "postgres", heat: heat(85, confirmed: true))
        let brief = snapshot([database], processes: [database.root]).compact.intelligenceBrief
        XCTAssertEqual(brief.actionTitle, "Stop safely")
        XCTAssertNotNil(brief.stopConsequence)
        XCTAssertTrue(brief.recommendation.hasPrefix(brief.stopConsequence ?? "-"))
    }

    func testAppRecommendationSaysItOnce() {
        // Started from a shell, so nothing restarts it and only the headline should remain.
        let app = family(pid: 980, parent: 77, name: "TextEdit", heat: heat(85, confirmed: true),
                         path: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        let brief = snapshot([app], processes: [app.root]).compact.intelligenceBrief
        XCTAssertNotNil(brief.stopConsequence)
        XCTAssertEqual(brief.recommendation, brief.stopConsequence, "the unsaved-work hazard restates the headline")
        XCTAssertEqual(brief.recommendation.components(separatedBy: "quit like").count, 2, brief.recommendation)
    }

    private func snapshot(_ families: [ProcessFamily], processes: [ProcessMetrics]) -> RadarConsoleSnapshot {
        let summary = ProcessFamilyBuilder(currentUserID: 501).summary(for: families)
        return RadarConsoleSnapshot.build(
            families: families, summary: summary, incidents: [], rules: [], metrics: .empty,
            health: .starting, storeHealth: .empty, storeError: nil, previous: nil,
            generatedAt: now, detailSignatures: [], processes: processes
        )
    }

    private func heat(_ value: Double, confirmed: Bool) -> GhostHeat {
        GhostHeat(value: value, level: .hot, confidence: confirmed ? 0.7 : 0.2, evidence: ["CPU pinned"],
                  sustainedSignalCount: confirmed ? 2 : 0)
    }

    private func process(pid: Int32, parent: Int32, name: String, command: String? = nil,
                         path: String? = nil) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
                       parentPID: parent, userID: 501, ownerName: "test", name: name,
                       executablePath: path ?? "/usr/local/bin/\(name)", commandLine: command ?? "\(name) --serve",
                       residentMemoryBytes: 900_000_000, physicalFootprintBytes: 900_000_000,
                       virtualMemoryBytes: 1_800_000_000, cpuPercent: 95, totalProcessorSeconds: 100,
                       threadCount: 8, isSystemProcess: false, sampledAt: now)
    }

    private func family(pid: Int32, parent: Int32 = 1, name: String, heat: GhostHeat, path: String? = nil) -> ProcessFamily {
        let root = process(pid: pid, parent: parent, name: name, path: path)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                             totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: 95,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: 70, level: .hot, reasons: ["CPU pinned"], heat: heat),
                             ownedIdentities: [root.identity], protectedPIDs: [], lastScoredAt: now)
    }
}
