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

    // MARK: - Growth in the tree

    func testTreeNamesTheMemberTheGrowthComesFrom() {
        let root = process(pid: 100, parent: 1)
        let small = process(pid: 200, parent: 100, memory: 50 * 1_048_576)
        let big = process(pid: 201, parent: 100, memory: 900 * 1_048_576)
        let middle = process(pid: 202, parent: 100, memory: 300 * 1_048_576)
        let members = [root, small, big, middle]

        let rows = FamilyProcessTreeRow.build(
            members: members, root: root, ownedIdentities: members.map(\.identity),
            growth: [growth(big, slope: 42, share: 0.8), growth(middle, slope: 5, share: 0.05)],
            culprit: big.identity
        )

        let bigRow = tree(rows, pid: 201)
        XCTAssertEqual(bigRow?.growthText, "+42 MB/min")
        XCTAssertEqual(bigRow?.isGrowthCulprit, true)
        XCTAssertNil(tree(rows, pid: 202)?.growthText, "5% of the growth is not worth a figure")
        XCTAssertEqual(tree(rows, pid: 202)?.isGrowthCulprit, false)
        XCTAssertNil(tree(rows, pid: 200)?.growthText)
        XCTAssertNil(tree(rows, pid: 100)?.growthText)
        XCTAssertEqual(rows[0].children?.map(\.pid), [201, 202, 200], "siblings stay ordered by memory")
    }

    func testTreeShowsNoFigureThatWouldRoundToNothing() {
        let root = process(pid: 100, parent: 1)
        let kids = (0..<4).map { process(pid: Int32(200 + $0), parent: 100) }
        let members = [root] + kids

        let rows = FamilyProcessTreeRow.build(
            members: members, root: root, ownedIdentities: members.map(\.identity),
            growth: [
                growth(kids[0], slope: 0.3, share: 0.5),
                growth(kids[1], slope: 1, share: 0.1),
                growth(kids[2], slope: 8, share: 0.09),
                growth(kids[3], slope: 1_234, share: 0.3)
            ]
        )

        XCTAssertNil(tree(rows, pid: 200)?.growthText, "0.3 MB/min would print as +0 MB/min")
        XCTAssertEqual(tree(rows, pid: 201)?.growthText, "+1 MB/min", "the floors are inclusive")
        XCTAssertNil(tree(rows, pid: 202)?.growthText, "under a tenth of the growth")
        XCTAssertEqual(tree(rows, pid: 203)?.growthText, "+1234 MB/min")
        XCTAssertFalse(flatten(rows).contains(where: \.isGrowthCulprit), "no culprit was named")
    }

    func testAMemberIsCalledLeakingOnlyWhenTheEngineCallsTheFamilyALeak() throws {
        let points = (0..<8).map { Double(400 + $0 * 40) * mebibyte }
        let child = process(pid: 5_000, parent: 4_242, memory: 900 * 1_048_576)
        let attributed = [growth(child, slope: 42, share: 0.8)]
        XCTAssertTrue(try XCTUnwrap(attributed.first).isCulprit, "the fixture is the engine's culprit")

        // A credible leak: the named member is marked and carries its figure.
        var leaking = makeFamily(points: points, fit: 0.95, forecast: forecast(.leaking, confidence: 0.8), extraMembers: [child])
        leaking.attribute(growth: attributed)
        XCTAssertTrue(leaking.hasCredibleLeak)
        let marked = tree(FamilyDetailPanelModel(family: leaking).processTree, pid: 5_000)
        XCTAssertEqual(marked?.isGrowthCulprit, true)
        XCTAssertEqual(marked?.growthText, "+42 MB/min")

        // Growing but not called a leak: the figure is honest, the verdict is not borrowed.
        var growing = makeFamily(points: points, fit: 0.95, forecast: forecast(.quiet, confidence: 0), level: .quiet, extraMembers: [child])
        growing.attribute(growth: attributed)
        XCTAssertFalse(growing.hasCredibleLeak)
        XCTAssertGreaterThan(growing.trend.credibleMemoryVelocity, 0)
        let figure = tree(FamilyDetailPanelModel(family: growing).processTree, pid: 5_000)
        XCTAssertEqual(figure?.growthText, "+42 MB/min")
        XCTAssertEqual(figure?.isGrowthCulprit, false, "MemberGrowth.isCulprit alone is not a leak verdict")

        // A family whose history proves no growth shows neither, whatever was attributed.
        var flat = makeFamily(points: Array(repeating: 400 * mebibyte, count: 8), fit: 0.1,
                              forecast: forecast(.quiet, confidence: 0), level: .quiet, extraMembers: [child])
        flat.attribute(growth: attributed)
        XCTAssertEqual(flat.trend.credibleMemoryVelocity, 0)
        let quiet = tree(FamilyDetailPanelModel(family: flat).processTree, pid: 5_000)
        XCTAssertNil(quiet?.growthText)
        XCTAssertEqual(quiet?.isGrowthCulprit, false)
    }

    // MARK: - Largest processes

    func testLargestListsTheRootThenTheBiggestProcessesAnywhereInTheOutline() {
        let root = process(pid: 100, parent: 1)
        let small = process(pid: 200, parent: 100, memory: 50 * 1_048_576)
        let big = process(pid: 201, parent: 100, memory: 900 * 1_048_576)
        let middle = process(pid: 202, parent: 100, memory: 300 * 1_048_576)
        let deep = process(pid: 203, parent: 201, memory: 2_000 * 1_048_576)
        let members = [root, small, big, middle, deep]
        let rows = FamilyProcessTreeRow.build(members: members, root: root, ownedIdentities: members.map(\.identity))

        XCTAssertEqual(FamilyProcessTreeRow.largest(rows, limit: 2).map(\.pid), [100, 203])
        XCTAssertEqual(FamilyProcessTreeRow.largest(rows, limit: 4).map(\.pid), [100, 203, 201, 202])
        XCTAssertEqual(FamilyProcessTreeRow.largest(rows, limit: 99).map(\.pid), [100, 203, 201, 202, 200])
        XCTAssertEqual(FamilyProcessTreeRow.largest(rows, limit: 0).map(\.pid), [])
        XCTAssertTrue(FamilyProcessTreeRow.largest(rows, limit: 5).allSatisfy { $0.children == nil }, "the list is flat")
        XCTAssertEqual(FamilyProcessTreeRow.largest(rows, limit: 1).first?.isRoot, true, "the root stays even when it is the smallest")
    }

    func testLargestBreaksTiesByPid() {
        let root = process(pid: 100, parent: 1)
        let kids = [process(pid: 230, parent: 100), process(pid: 210, parent: 100), process(pid: 220, parent: 100)]
        let members = [root] + kids
        let rows = FamilyProcessTreeRow.build(members: members, root: root, ownedIdentities: members.map(\.identity))

        XCTAssertEqual(FamilyProcessTreeRow.largest(rows, limit: 3).map(\.pid), [100, 210, 220])
    }

    func testTheInspectorListsTheBiggestTenOfALargeFamilyNotTheFirstTen() {
        // The bigger the pid, the bigger the process, so the first ten by pid are the smallest.
        let children = (0..<39).map { process(pid: Int32(5_000 + $0), parent: 4_242, memory: UInt64(100 + $0) * 1_048_576) }
        let family = makeFamily(points: (0..<8).map { Double(400 + $0 * 40) * mebibyte }, fit: 0.95,
                                forecast: forecast(.quiet, confidence: 0), level: .quiet, extraMembers: children)

        let shown = FamilyDetailPanelModel(family: family).inspectorTree

        XCTAssertEqual(shown.count, FamilyDetailPanelModel.inspectorTreeLimit)
        XCTAssertEqual(shown.first?.isRoot, true)
        XCTAssertEqual(shown.dropFirst().map(\.pid), (0..<9).map { Int32(5_038 - $0) })
        XCTAssertEqual(shown.dropFirst().first?.memoryText, "138 MB")
    }

    // MARK: - Fixtures

    private func growth(_ member: ProcessMetrics, slope: Double, share: Double, rSquared: Double = 0.9) -> MemberGrowth {
        MemberGrowth(identity: member.identity, name: member.name, slopeMegabytesPerMinute: slope, rSquared: rSquared, share: share)
    }

    private func flatten(_ rows: [FamilyProcessTreeRow]) -> [FamilyProcessTreeRow] {
        rows.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func tree(_ rows: [FamilyProcessTreeRow], pid: Int32) -> FamilyProcessTreeRow? {
        flatten(rows).first { $0.pid == pid }
    }

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
        level: GhostLevel = .hot,
        extraMembers: [ProcessMetrics] = []
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
            members: [root] + extraMembers,
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
