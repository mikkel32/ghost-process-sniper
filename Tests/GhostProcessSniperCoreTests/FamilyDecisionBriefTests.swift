import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class FamilyDecisionBriefTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_100_000)
    private let mebibyte: Double = 1_048_576

    func testSteadyClimbWithHighFitRecommendsStopWithHighConfidence() {
        let family = makeFamily(points: (0..<8).map { Double(400 + $0 * 40) * mebibyte }, fit: 0.95, forecast: forecast(.leaking, confidence: 0.8))

        let brief = FamilyDetailPanelModel(family: family).brief

        XCTAssertEqual(brief.headline, "Likely leak")
        XCTAssertEqual(brief.recommendation, .stop)
        XCTAssertEqual(brief.confidence, .high)
        XCTAssertTrue(brief.confidenceText.hasPrefix("High confidence"), brief.confidenceText)
        XCTAssertEqual(brief.recommendationText, ProcessAssessment(family: family).recommendation, "one wording, not a second opinion")
        XCTAssertTrue(brief.reclaimText.hasPrefix("Frees "), brief.reclaimText)
    }

    func testSawtoothIsWatchedNotStopped() {
        let points: [Double] = [400, 520, 430, 560, 450, 590, 470, 610].map { $0 * mebibyte }
        // Watch level: a measured Hot level outranks the shape and reads as heavy.
        let family = makeFamily(points: points, fit: 0.3, forecast: forecast(.warming, confidence: 0.6), level: .watch)

        let brief = FamilyDetailPanelModel(family: family).brief

        XCTAssertEqual(brief.headline, "Churning, not leaking")
        XCTAssertEqual(brief.recommendation, .watch)
    }

    func testIncompleteReadingsWaitWithLowConfidence() {
        let family = makeFamily(
            points: (0..<8).map { Double(400 + $0 * 40) * mebibyte },
            fit: 0.95,
            forecast: forecast(.leaking, confidence: 0.8),
            measurement: .unavailable
        )

        let brief = FamilyDetailPanelModel(family: family).brief

        XCTAssertEqual(brief.recommendation, .waitForReading)
        XCTAssertEqual(brief.confidence, .low)
    }

    func testSnoozedFamilyIsLeftAlone() {
        let family = makeFamily(
            points: (0..<8).map { Double(400 + $0 * 40) * mebibyte },
            fit: 0.95,
            forecast: forecast(.leaking, confidence: 0.8),
            alert: AlertState(kind: .snoozed, message: "Snoozed", since: now)
        )

        let brief = FamilyDetailPanelModel(family: family).brief

        XCTAssertEqual(brief.recommendation, .leaveAlone)
        XCTAssertEqual(brief.mute, .snoozed)
    }

    func testFamilyWithoutOwnedTargetsIsNeverRecommendedForStop() {
        let family = makeFamily(
            points: (0..<8).map { Double(400 + $0 * 40) * mebibyte },
            fit: 0.95,
            forecast: forecast(.leaking, confidence: 0.8),
            owned: false
        )

        let brief = FamilyDetailPanelModel(family: family).brief

        XCTAssertNotEqual(brief.recommendation, .stop)
        XCTAssertEqual(brief.recommendation, .watch)
    }

    func testEvidenceLeadsWithTheStrongestScoreComponents() {
        let components = (1...5).map {
            GhostScoreComponent(kind: .memory, title: "signal \($0)", detail: "detail \($0)", impact: Double($0), level: .watch)
        }
        let family = makeFamily(
            points: (0..<8).map { Double(400 + $0 * 40) * mebibyte },
            fit: 0.95,
            forecast: forecast(.leaking, confidence: 0.8),
            components: components
        )

        let evidence = FamilyDetailPanelModel(family: family).brief.evidence

        XCTAssertEqual(Array(evidence.prefix(3)), ["signal 5: detail 5", "signal 4: detail 4", "signal 3: detail 3"])
        XCTAssertGreaterThan(evidence.count, 3, "culprit evidence follows the score components")
    }

    /// A calm 300 MB app used to list "Process relevance: 85% confidence this
    /// belongs to the selected radar scope" and "CPU activity: 3% is 0.0x the
    /// 90% limit" as the evidence for its page: scope trivia and a ratio that
    /// says nothing is wrong. Only what was raised explains the verdict.
    func testEvidenceDropsScopeRelevanceAndQuietFiller() {
        let components = [
            GhostScoreComponent(slot: "memory", kind: .memory, title: "Memory footprint", detail: "1.7 GB is 1.4x the 1.2 GB limit",
                                impact: 30, level: .watch),
            GhostScoreComponent(slot: "relevance", kind: .background, title: "Process relevance",
                                detail: "85% confidence this belongs to the selected radar scope", impact: 10, level: .watch),
            GhostScoreComponent(slot: "cpu", kind: .cpu, title: "CPU activity", detail: "3% is 0.0x the 90% limit", impact: 1, level: .quiet)
        ]
        let family = makeFamily(
            points: (0..<8).map { Double(400 + $0 * 40) * mebibyte }, fit: 0.95,
            forecast: forecast(.leaking, confidence: 0.8), components: components
        )

        let evidence = FamilyDetailPanelModel(family: family).brief.evidence

        XCTAssertEqual(evidence.first, "Memory footprint: 1.7 GB is 1.4x the 1.2 GB limit")
        XCTAssertFalse(evidence.contains { $0.hasPrefix("Process relevance") }, "\(evidence)")
        XCTAssertFalse(evidence.contains { $0.hasPrefix("CPU activity") }, "\(evidence)")
    }

    /// The process tree's own facts still follow when no component was raised.
    func testEvidenceOfAQuietFamilyIsWhatTheCulpritAnalysisSaw() {
        let components = [
            GhostScoreComponent(slot: "cpu", kind: .cpu, title: "CPU activity", detail: "3% is 0.0x the 90% limit", impact: 1, level: .quiet),
            GhostScoreComponent(slot: "relevance", kind: .background, title: "Process relevance", detail: "12% confidence", impact: 2, level: .quiet)
        ]
        let family = makeFamily(
            points: (0..<8).map { Double(400 + $0 * 40) * mebibyte }, fit: 0.95,
            forecast: forecast(.quiet, confidence: 0), components: components, level: .quiet
        )
        let panel = FamilyDetailPanelModel(family: family)

        XCTAssertEqual(panel.brief.evidence, panel.culprit.evidence)
        XCTAssertFalse(panel.brief.evidence.isEmpty)
    }

    func testProcessTreeNestsChildrenAndKeepsEveryMember() {
        let root = process(pid: 100, parent: 1)
        let children = (0..<30).map { process(pid: Int32(200 + $0), parent: $0 == 0 ? 100 : 200) }
        let orphan = process(pid: 900, parent: 777)
        let members = [root] + children + [orphan]

        let rows = FamilyProcessTreeRow.build(members: members, root: root, ownedIdentities: members.map(\.identity))

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isRoot)
        XCTAssertEqual(count(rows), members.count, "nothing is cut off")
        let firstChild = rows[0].children?.first { $0.pid == 200 }
        XCTAssertEqual(firstChild?.children?.count, 29)
        XCTAssertNotNil(rows[0].children?.first { $0.pid == 900 }, "a member with an outside parent hangs off the root")
        XCTAssertNil(firstChild?.children?.first?.children, "leaves have no children array")
    }

    // MARK: - Fixtures

    private func count(_ rows: [FamilyProcessTreeRow]) -> Int {
        rows.reduce(0) { $0 + 1 + count($1.children ?? []) }
    }

    private func forecast(_ state: ForecastState, confidence: Double) -> RiskForecast {
        RiskForecast(
            state: state,
            horizon: .soon,
            confidence: confidence,
            etaSeconds: 600,
            etaText: "10m",
            whyNow: "memory keeps rising",
            recommendedAction: TriageRecommendation(title: "Review", detail: "Review it", action: .inspect, confidence: confidence),
            projectedMemoryBytes: 2_000_000_000,
            projectedCPUPercent: 5,
            leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0,
            staleLikelihood: 0,
            baseline: .unknown,
            generatedAt: now
        )
    }

    private func process(
        pid: Int32,
        parent: Int32,
        memory: UInt64 = 64_000_000,
        measurement: ProcessMeasurementStatus = .fresh
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 2_000_000_000, startTimeMicroseconds: 0),
            parentPID: parent,
            userID: 501,
            ownerName: "me",
            name: "node",
            executablePath: "/usr/local/bin/node",
            commandLine: "node server.js",
            residentMemoryBytes: memory,
            physicalFootprintBytes: memory,
            virtualMemoryBytes: memory * 2,
            cpuPercent: 3,
            totalProcessorSeconds: 10,
            threadCount: 4,
            isSystemProcess: false,
            sampledAt: now,
            measurementStatus: measurement
        )
    }

    private func makeFamily(
        points: [Double],
        fit: Double,
        forecast: RiskForecast,
        measurement: ProcessMeasurementStatus = .fresh,
        alert: AlertState = .normal,
        owned: Bool = true,
        components: [GhostScoreComponent] = [],
        level: GhostLevel = .hot
    ) -> ProcessFamily {
        let root = process(pid: 4_242, parent: 1, memory: UInt64(points.last ?? 0), measurement: measurement)
        let samples = points.enumerated().map { index, bytes in
            TrendSample(date: now.addingTimeInterval(Double(index - points.count + 1) * 12), memoryBytes: UInt64(bytes), cpuPercent: 3)
        }
        let trend = TrendMetrics(
            memoryVelocityMegabytesPerMinute: 200,
            cpuSlopePerMinute: 0,
            memoryPoints: points,
            memoryFitQuality: fit,
            samples: samples
        )
        return ProcessFamily(
            root: root,
            members: [root],
            totalResidentMemoryBytes: root.residentMemoryBytes,
            totalPhysicalFootprintBytes: root.physicalFootprintBytes,
            totalCPUPercent: 3,
            devConfidence: 0.9,
            commandHints: [root.commandLine],
            trend: trend,
            score: GhostScore(value: 60, level: level, reasons: ["memory climbing"], components: components),
            ownedIdentities: owned ? [root.identity] : [],
            protectedPIDs: owned ? [] : [root.pid],
            alertState: alert,
            forecast: forecast
        )
    }
}
