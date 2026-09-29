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
        XCTAssertEqual(brief.actionTitle, "Inspect signals")
        XCTAssertNil(brief.stopConsequence)
    }

    func testRecommendationSaysWhatStoppingWillDo() {
        let supervisor = process(pid: 950, parent: 1, name: "nodemon", command: "node /usr/local/bin/nodemon server.js")
        let server = family(pid: 960, parent: supervisor.pid, name: "node", heat: heat(80, confirmed: true))
        let brief = snapshot([server], processes: [supervisor, server.root]).compact.intelligenceBrief

        XCTAssertEqual(brief.familyKey, server.familyKey)
        XCTAssertTrue(brief.recommendation.contains("nodemon"), brief.recommendation)
        XCTAssertEqual(brief.actionTitle, "Review family", "it opens the server's page, not the supervisor's")
        let risk = KillRiskAssessor().assess(KillWorkloadProfile(family: server, sample: [supervisor, server.root]))
        XCTAssertEqual(brief.stopConsequence, risk.headline)
    }

    func testDataStoreIsReviewedNotStopped() {
        let database = family(pid: 970, name: "postgres", heat: heat(85, confirmed: true))
        let brief = snapshot([database], processes: [database.root]).compact.intelligenceBrief
        XCTAssertEqual(brief.actionTitle, "Review database")
        XCTAssertNotNil(brief.stopConsequence)
        XCTAssertTrue(brief.recommendation.hasPrefix(brief.stopConsequence ?? "-"))
    }

    /// The hero's first button opens the family page; only the Quick Stop
    /// beside it stops anything, so no label may promise a stop.
    func testTheReviewButtonNeverSaysItStopsAnything() {
        let app = family(pid: 980, parent: 77, name: "TextEdit", heat: heat(85, confirmed: true),
                         path: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        let database = family(pid: 970, name: "postgres", heat: heat(85, confirmed: true))
        let docker = family(pid: 965, name: "docker", heat: heat(85, confirmed: true))
        let server = family(pid: 990, name: "vite", heat: heat(85, confirmed: true))
        let supervisor = process(pid: 950, parent: 1, name: "nodemon", command: "node /usr/local/bin/nodemon server.js")
        let supervised = family(pid: 960, parent: supervisor.pid, name: "node", heat: heat(80, confirmed: true))
        let cases: [(ProcessFamily, [ProcessMetrics], String)] = [
            (app, [app.root], "Review app"),
            (database, [database.root], "Review database"),
            (docker, [docker.root], "Review containers"),
            (server, [server.root], "Review family"),
            (supervised, [supervisor, supervised.root], "Review family")
        ]
        for (family, processes, title) in cases {
            let brief = snapshot([family], processes: processes).compact.intelligenceBrief
            XCTAssertEqual(brief.actionTitle, title, family.displayName)
            for verb in ["Quit", "Stop", "Shut"] {
                XCTAssertFalse(brief.actionTitle.hasPrefix(verb), "\(family.displayName): \(brief.actionTitle)")
            }
        }
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

    // MARK: Watched families: an early warning has to be more than being big

    /// A big app at a size it does not usually reach is watched, not warned
    /// about: the hero stays calm, names no target and offers no Quick Stop.
    func testABigFamilyWatchedForItsSizeAloneLeavesTheHeroCalm() {
        let big = watched(pid: 1_000, name: "ControlCenter")
        XCTAssertTrue(big.isWatchedForSizeOnly)
        let compact = snapshot([big], processes: []).compact

        XCTAssertNil(compact.intelligenceBrief.familyKey, "no target, so no Quick Stop candidate either")
        XCTAssertEqual(compact.intelligenceBrief.eyebrow, "Live guidance")
        XCTAssertEqual(compact.intelligenceBrief.level, .quiet)
        XCTAssertEqual(compact.intelligenceBrief.title, "No credible problems right now")
        XCTAssertTrue(compact.intelligenceBrief.detail.hasPrefix("1 family is watched for size only"),
                      compact.intelligenceBrief.detail)
        XCTAssertEqual(compact.intelligenceBrief.evidence.count, 1)
        XCTAssertTrue(compact.intelligenceBrief.evidence[0].hasPrefix("ControlCenter "), "\(compact.intelligenceBrief.evidence)")
        XCTAssertEqual(compact.warmingRows.map(\.familyKey), [big.familyKey], "still listed, just not announced")
    }

    func testTheCalmBriefNamesTheLargestThreeAndCountsAll() {
        let families = (0..<4).map { watched(pid: Int32(1_100 + $0), name: "big\($0)") }
        let brief = snapshot(families, processes: []).compact.intelligenceBrief
        XCTAssertNil(brief.familyKey)
        XCTAssertTrue(brief.detail.hasPrefix("4 families are watched for size only"), brief.detail)
        XCTAssertEqual(brief.evidence.count, 3)
    }

    /// Any other reason to look keeps the early warning: growth, a forgotten
    /// tree, duplicates, context votes, or a size above its learned normal.
    func testAnythingBesidesSizeStaysAnEarlyWarning() {
        let growing = trend(megabytesPerMinute: 30)
        let forgotten = GhostScoreComponent(slot: "forgotten", kind: .background, title: "likely forgotten",
                                            detail: "", impact: 4, level: .watch)
        let duplicate = GhostScoreComponent(slot: "duplicate", kind: .fanout, title: "2 independent copies",
                                            detail: "", impact: 8, level: .watch)
        let cpu = GhostScoreComponent(slot: "cpu", kind: .cpu, title: "CPU activity", detail: "", impact: 12, level: .watch)
        let relevance = GhostScoreComponent(slot: "relevance", kind: .background, title: "Process relevance",
                                            detail: "", impact: 4, level: .watch)
        let cases: [(String, ProcessFamily)] = [
            ("growth", watched(pid: 1_200, name: "grower", trend: growing)),
            ("forgotten", watched(pid: 1_210, name: "forgotten", extra: [forgotten])),
            ("duplicate", watched(pid: 1_220, name: "twin", extra: [duplicate])),
            ("cpu", watched(pid: 1_230, name: "busy", extra: [cpu])),
            ("host pressure or baseline vote", watched(pid: 1_240, name: "voted", corroboration: 1)),
            ("above its learned normal", watched(pid: 1_250, name: "swollen", usualMegabytes: 400)),
            ("nothing raised but a Watch level", watched(pid: 1_260, name: "unexplained", components: [relevance])),
            ("a leaking forecast", watched(pid: 1_270, name: "leaker", forecastState: .leaking))
        ]
        for (reason, family) in cases {
            XCTAssertFalse(family.isWatchedForSizeOnly, reason)
            let brief = snapshot([family], processes: []).compact.intelligenceBrief
            XCTAssertEqual(brief.familyKey, family.familyKey, reason)
            XCTAssertEqual(brief.eyebrow, "Early warning", reason)
            XCTAssertEqual(brief.actionTitle, "Inspect early", reason)
        }
    }

    /// A family that is big for its learned normal but merely at it is size only.
    func testAFamilyAtItsLearnedNormalIsStillSizeOnly() {
        XCTAssertTrue(watched(pid: 1_300, name: "usual", usualMegabytes: 880).isWatchedForSizeOnly)
    }

    /// The hero's target must sit in the prepared prefix of the queue, so the
    /// rows with something against them come first, in their own order.
    func testWarmingRowsPutEarlyWarningsBeforeSizeOnlyOnes() {
        let bigger = watched(pid: 1_400, name: "bigger", heatValue: 55)
        let forgotten = GhostScoreComponent(slot: "forgotten", kind: .background, title: "likely forgotten",
                                            detail: "", impact: 4, level: .watch)
        let smaller = watched(pid: 1_410, name: "forgotten", heatValue: 32, extra: [forgotten])
        let rows = [bigger, smaller].map { CompactSidebarRowModel(item: FamilyTriageViewModel(family: $0)) }
        XCTAssertEqual(rows.map(\.isWatchedForSizeOnly), [true, false])

        let warming = CompactConsoleSnapshot.priorityRows(from: rows).warming
        XCTAssertEqual(warming.map(\.title), ["forgotten", "bigger"])
        XCTAssertEqual(CompactConsoleSnapshot.priorityRows(from: rows.reversed()).warming.map(\.title), ["forgotten", "bigger"])
    }

    /// Slow growth moves no gauge by a tolerance, so the revision has to see
    /// the family stop being "big and nothing else" itself, or the calm
    /// verdict would outlive it.
    func testAFamilyThatStopsBeingSizeOnlyMovesTheContentRevision() {
        let flat = watched(pid: 1_450, name: "flat")
        let creeping = watched(pid: 1_450, name: "flat", trend: trend(megabytesPerMinute: 12))
        XCTAssertTrue(flat.isWatchedForSizeOnly)
        XCTAssertFalse(creeping.isWatchedForSizeOnly, "12 MB/min is proven growth")

        func revision(_ family: ProcessFamily) -> SnapshotContentRevision {
            SnapshotContentRevision.compute(families: [family], summary: ProcessFamilyBuilder(currentUserID: 501).summary(for: [family]),
                                            incidents: [], rules: [])
        }
        XCTAssertNotEqual(revision(flat), revision(creeping))
    }

    func testAHotConfirmedRowStillOutranksWatchedOnes() {
        let steady = family(pid: 1_500, name: "steady", heat: heat(80, confirmed: true))
        let brief = snapshot([watched(pid: 1_510, name: "big"), steady], processes: []).compact.intelligenceBrief
        XCTAssertEqual(brief.familyKey, steady.familyKey)
        XCTAssertEqual(brief.eyebrow, "Recommended now")
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

    private let megabyte = 1_048_576.0

    /// Ten dated readings, twelve seconds apart, rising at a steady rate: a
    /// history long enough to prove growth (or to prove there is none).
    private func trend(megabytesPerMinute rate: Double) -> TrendMetrics {
        let samples = (0..<10).map { index in
            TrendSample(date: now.addingTimeInterval(Double(index - 9) * 12),
                        memoryBytes: UInt64((858 + rate * 0.2 * Double(index)) * megabyte), cpuPercent: 3)
        }
        return TrendMetrics(memoryVelocityMegabytesPerMinute: rate, cpuSlopePerMinute: 0,
                            memoryPoints: samples.map { Double($0.memoryBytes) }, memoryFitQuality: 0.95, samples: samples)
    }

    /// A Watch family with hand-picked evidence: by default its footprint is
    /// its only raised component, which is being big and nothing else.
    private func watched(pid: Int32, name: String, heatValue: Double = 42, components: [GhostScoreComponent]? = nil,
                         extra: [GhostScoreComponent] = [], trend: TrendMetrics? = nil,
                         forecastState: ForecastState = .warming, corroboration: Int = 0,
                         usualMegabytes: Double? = nil) -> ProcessFamily {
        let root = process(pid: pid, parent: 1, name: name)
        let memory = GhostScoreComponent(slot: "memory", kind: .memory, title: "Memory footprint", detail: "", impact: 24, level: .watch)
        let signature = ProcessSignature.from(root: root)
        let baseline = usualMegabytes.map { usual in
            FamilyBaseline(signature: signature, sampleCount: 2_000, meanMemoryBytes: usual * megabyte,
                           peakMemoryBytes: UInt64(usual * 1.2 * megabyte), meanCPUPercent: 3, peakCPUPercent: 40,
                           meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
                           firstSeenAt: now.addingTimeInterval(-86_400), lastSeenAt: now.addingTimeInterval(-5),
                           memoryVariance: (100 * megabyte) * (100 * megabyte), cpuVariance: 25,
                           observedSeconds: 36_000, sessionCount: 4)
        }
        let forecast = RiskForecast(
            state: forecastState, horizon: .later, confidence: 0.6, etaSeconds: nil, etaText: "No threshold ETA",
            whyNow: "Level is Watch",
            recommendedAction: TriageRecommendation(title: "Watch closely", detail: "Predictive signals are warming before a hard threshold breach.",
                                                    action: .highlight, confidence: 0.6),
            projectedMemoryBytes: 0, projectedCPUPercent: 0, leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0, staleLikelihood: 0, baseline: .unknown, generatedAt: now)
        let watchHeat = GhostHeat(value: heatValue, level: .watch, confidence: 0.5, evidence: ["Memory footprint is elevated"],
                             sustainedSignalCount: 0, corroborationCount: corroboration)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                             totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: 3,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: trend ?? self.trend(megabytesPerMinute: 0),
                             score: GhostScore(value: 40, level: .watch, reasons: ["large memory footprint"],
                                               components: (components ?? [memory]) + extra, heat: watchHeat),
                             ownedIdentities: [root.identity], protectedPIDs: [], signature: signature, baseline: baseline,
                             forecast: forecast, lastScoredAt: now)
    }
}
