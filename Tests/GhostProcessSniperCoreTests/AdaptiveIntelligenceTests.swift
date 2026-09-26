import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class AdaptiveIntelligenceTests: XCTestCase {
    private let gibibyte: UInt64 = 1_073_741_824
    private let mebibyte: UInt64 = 1_048_576

    func testAutomaticProfileScalesToHostAndTightensUnderPressure() {
        var settings = ThresholdSettings.smart
        settings.sensitivity = .balanced

        let nominal = settings.resolvedProfile(
            systemPressure: .unknown,
            physicalMemoryBytes: 16 * gibibyte
        )
        let warning = settings.resolvedProfile(
            systemPressure: SystemMemoryPressure(
                level: .warning,
                usedFraction: 0.88,
                totalBytes: 16 * gibibyte,
                availableBytes: 2 * gibibyte,
                compressedBytes: 3 * gibibyte
            )
        )

        XCTAssertTrue(nominal.isAdaptive)
        XCTAssertEqual(nominal.effectiveSettings.detectionMode, .automatic)
        XCTAssertGreaterThan(nominal.effectiveSettings.memoryBytes, gibibyte)
        XCTAssertLessThan(warning.effectiveSettings.memoryBytes, nominal.effectiveSettings.memoryBytes)
        XCTAssertLessThan(warning.effectiveSettings.leakVelocityMegabytesPerMinute, nominal.effectiveSettings.leakVelocityMegabytesPerMinute)
        XCTAssertLessThanOrEqual(warning.effectiveSettings.cpuPercent, nominal.effectiveSettings.cpuPercent)
        XCTAssertTrue(warning.detail.localizedCaseInsensitiveContains("pressure"))
    }

    func testCustomProfileAndLegacyJSONPreserveExactLimits() throws {
        var custom = ThresholdSettings.aggressive
        custom.memoryBytes = 2 * gibibyte
        custom.cpuPercent = 123
        custom.leakVelocityMegabytesPerMinute = 456

        let resolved = custom.resolvedProfile(
            systemPressure: SystemMemoryPressure(
                level: .critical,
                usedFraction: 0.97,
                totalBytes: 8 * gibibyte,
                availableBytes: 256 * mebibyte,
                compressedBytes: 3 * gibibyte
            )
        )

        XCTAssertFalse(resolved.isAdaptive)
        XCTAssertEqual(resolved.effectiveSettings.memoryBytes, custom.memoryBytes)
        XCTAssertEqual(resolved.effectiveSettings.cpuPercent, 123)
        XCTAssertEqual(resolved.effectiveSettings.leakVelocityMegabytesPerMinute, 456)

        let legacyJSON = """
        {
          "memoryBytes": 3221225472,
          "cpuPercent": 140,
          "leakVelocityMegabytesPerMinute": 300,
          "sustainedSeconds": 7,
          "refreshInterval": 2,
          "forceKillDelay": 3,
          "radarMode": "heavy",
          "groupFamilies": false,
          "performanceMode": "batterySaver"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: legacyJSON)

        XCTAssertEqual(decoded.detectionMode, .custom)
        XCTAssertEqual(decoded.sensitivity, .balanced)
        XCTAssertFalse(decoded.adaptivePerformance)
        XCTAssertEqual(decoded.memoryBytes, 3 * gibibyte)
        XCTAssertEqual(decoded.performanceMode, .batterySaver)
    }

    func testAdaptivePerformanceUsesIntentAndPressureInsteadOfManualKnobs() {
        var settings = ThresholdSettings.smart

        XCTAssertEqual(
            settings.resolvedPerformanceMode(
                summaryLevel: .quiet,
                popoverVisible: false,
                systemPressure: .nominal
            ),
            .balanced
        )
        XCTAssertEqual(
            settings.resolvedPerformanceMode(
                summaryLevel: .quiet,
                popoverVisible: true,
                systemPressure: .nominal
            ),
            .realtime
        )
        XCTAssertEqual(
            settings.resolvedPerformanceMode(
                summaryLevel: .quiet,
                popoverVisible: false,
                systemPressure: .serious
            ),
            .batterySaver
        )
        XCTAssertEqual(
            settings.resolvedPerformanceMode(
                summaryLevel: .hot,
                popoverVisible: false,
                systemPressure: .nominal
            ),
            .realtime
        )

        settings.adaptivePerformance = false
        settings.performanceMode = .batterySaver
        XCTAssertEqual(
            settings.resolvedPerformanceMode(
                summaryLevel: .critical,
                popoverVisible: true,
                systemPressure: .nominal
            ),
            .batterySaver
        )
    }

    func testExtremeEvidenceScoreDoesNotAutomaticallyMeanCriticalHeat() {
        let heat = GhostHeatModel.initial(
            memoryRatio: 1.7,
            cpuRatio: 0.15,
            gpuRatio: 0,
            leakRatio: 0,
            trend: TrendMetrics(
                memoryVelocityMegabytesPerMinute: 0,
                cpuSlopePerMinute: 0,
                memoryPoints: [1_800],
                memoryFitQuality: 0,
                sampleCount: 1,
                samples: []
            ),
            hardwareLevel: .quiet
        )
        let score = GhostScore(
            value: 100,
            level: .critical,
            reasons: ["large one-off allocation"],
            heat: heat
        )

        XCTAssertEqual(score.value, 100)
        XCTAssertNotEqual(score.level, .critical)
        XCTAssertEqual(score.level, heat.level)
        XCTAssertLessThan(heat.confidence, 0.6)
    }

    func testSustainedCorroboratedHeatCanBecomeCritical() {
        let now = Date(timeIntervalSince1970: 2_000_000_300)
        var samples: [TrendSample] = []
        for offset in 0..<8 {
            let seconds = Double(offset - 7) * 15
            let memory = UInt64(700 + offset * 120) * mebibyte
            samples.append(
                TrendSample(
                    date: now.addingTimeInterval(seconds),
                    memoryBytes: memory,
                    cpuPercent: 125
                )
            )
        }
        let heat = GhostHeatModel.initial(
            memoryRatio: 1.25,
            cpuRatio: 1.55,
            gpuRatio: 0.2,
            leakRatio: 1.8,
            trend: TrendMetrics(
                memoryVelocityMegabytesPerMinute: 180,
                cpuSlopePerMinute: 18,
                memoryPoints: samples.map { Double($0.memoryBytes) },
                memoryFitQuality: 0.94,
                sampleCount: samples.count,
                samples: samples
            ),
            hardwareLevel: .hot
        )

        XCTAssertEqual(heat.level, GhostLevel.critical)
        XCTAssertGreaterThanOrEqual(heat.sustainedSignalCount, 2)
        XCTAssertGreaterThanOrEqual(heat.confidence, 0.58)
        XCTAssertTrue(heat.evidence.contains { $0.localizedCaseInsensitiveContains("sustained") || $0.localizedCaseInsensitiveContains("stayed elevated") })
    }

    @MainActor
    func testIdenticalIngestKeepsContentRevisionStable() {
        var settings = ThresholdSettings.aggressive
        settings.memoryBytes = 100_000_000
        let sampledAt = Date(timeIntervalSince1970: 3_080)
        let process = makeNodeProcess(
            identity: ProcessIdentity(pid: 308, startTimeSeconds: 3_000, startTimeMicroseconds: 0),
            memoryBytes: 150_000_000,
            cpuPercent: 0,
            at: sampledAt
        )
        let monitor = ProcessMonitor(
            builder: ProcessFamilyBuilder(currentUserID: 501),
            settings: settings,
            store: nil
        )

        monitor.ingest([process], now: sampledAt)
        let firstRevision = monitor.consoleSnapshot.contentRevision
        let firstHeat = monitor.families.first?.score.heat
        monitor.ingest([process], now: sampledAt.addingTimeInterval(1))
        let secondRevision = monitor.consoleSnapshot.contentRevision
        let secondHeat = monitor.families.first?.score.heat

        XCTAssertEqual(
            secondRevision,
            firstRevision,
            "Identical ingest changed revision. First heat: \(String(describing: firstHeat)); second heat: \(String(describing: secondHeat))"
        )
    }

    func testBaselineLearnerDoesNotNormalizeActiveIncidents() throws {
        let start = Date(timeIntervalSince1970: 2_000_010_000)
        let identity = ProcessIdentity(
            pid: 42_050,
            startTimeSeconds: UInt64(start.addingTimeInterval(-3_600).timeIntervalSince1970),
            startTimeMicroseconds: 0
        )
        let learner = FamilyBaselineLearner()

        let healthyRoot = makeNodeProcess(
            identity: identity,
            memoryBytes: 512 * mebibyte,
            cpuPercent: 12,
            at: start
        )
        let healthy = makeFamily(
            root: healthyRoot,
            score: GhostScore(value: 10, level: .quiet, reasons: ["inside normal range"])
        )
        let learned = learner.updated(existing: nil, family: healthy, now: start)

        let incidentRoot = makeNodeProcess(
            identity: identity,
            memoryBytes: 4 * gibibyte,
            cpuPercent: 220,
            at: start.addingTimeInterval(60)
        )
        let incident = makeFamily(
            root: incidentRoot,
            score: GhostScore(value: 96, level: .critical, reasons: ["memory above threshold"])
        )
        let protected = learner.updated(
            existing: learned,
            family: incident,
            now: start.addingTimeInterval(60)
        )

        XCTAssertEqual(protected.sampleCount, learned.sampleCount)
        XCTAssertEqual(protected.meanMemoryBytes, learned.meanMemoryBytes, accuracy: 0.001)
        XCTAssertEqual(protected.peakMemoryBytes, learned.peakMemoryBytes)
        XCTAssertEqual(protected.meanCPUPercent, learned.meanCPUPercent, accuracy: 0.001)
        XCTAssertEqual(protected.incidentCount, learned.incidentCount)

        let recordedIncident = makeFamily(
            root: incidentRoot,
            score: GhostScore(value: 96, level: .critical, reasons: ["memory above threshold"]),
            recentIncidentCount: 1
        )
        let withRecordedIncident = learner.updated(
            existing: protected,
            family: recordedIncident,
            now: start.addingTimeInterval(61)
        )
        let sameIncidentAgain = learner.updated(
            existing: withRecordedIncident,
            family: recordedIncident,
            now: start.addingTimeInterval(62)
        )
        XCTAssertEqual(withRecordedIncident.incidentCount, 1)
        XCTAssertEqual(sameIncidentAgain.incidentCount, 1, "Repeated refreshes must not manufacture recurrences")

        let recoveredRoot = makeNodeProcess(
            identity: identity,
            memoryBytes: 640 * mebibyte,
            cpuPercent: 16,
            at: start.addingTimeInterval(120)
        )
        let recovered = makeFamily(
            root: recoveredRoot,
            score: GhostScore(value: 14, level: .quiet, reasons: ["recovered"])
        )
        let relearned = learner.updated(
            existing: sameIncidentAgain,
            family: recovered,
            now: start.addingTimeInterval(120)
        )

        XCTAssertEqual(relearned.sampleCount, learned.sampleCount + 1)
        XCTAssertGreaterThan(relearned.meanMemoryBytes, learned.meanMemoryBytes)
        XCTAssertLessThan(relearned.meanMemoryBytes, Double(gibibyte))
    }

    func testFirstObservedIncidentDoesNotBecomeNormalPeak() {
        let now = Date(timeIntervalSince1970: 2_000_020_000)
        let root = makeNodeProcess(
            identity: ProcessIdentity(pid: 42_060, startTimeSeconds: 2_000_010_000, startTimeMicroseconds: 0),
            memoryBytes: 6 * gibibyte,
            cpuPercent: 260,
            at: now
        )
        let family = makeFamily(
            root: root,
            score: GhostScore(value: 100, level: .critical, reasons: ["extreme incident"])
        )

        let baseline = FamilyBaselineLearner().updated(existing: nil, family: family, now: now)

        XCTAssertEqual(baseline.sampleCount, 0)
        XCTAssertEqual(baseline.meanMemoryBytes, 0)
        XCTAssertEqual(baseline.peakMemoryBytes, 0)
        XCTAssertEqual(baseline.meanCPUPercent, 0)
        XCTAssertEqual(baseline.peakCPUPercent, 0)
    }

    func testQuietVerdictRequiresTrustedBaselineBeforeClaimingLearnedRange() {
        let now = Date(timeIntervalSince1970: 2_000_020_100)
        let root = makeNodeProcess(
            identity: ProcessIdentity(pid: 42_061, startTimeSeconds: 2_000_010_000, startTimeMicroseconds: 0),
            memoryBytes: 128 * mebibyte,
            cpuPercent: 4,
            at: now
        )
        let family = makeFamily(root: root, score: GhostScore(value: 0, level: .quiet, reasons: []))
        let unlearned = FamilyVerdict.synthesize(family: family, pattern: .unknown)
        XCTAssertEqual(unlearned.headline, "No unusual activity observed")
        XCTAssertFalse(unlearned.detail.contains("Inside its learned range"))

        let immatureBaseline = FamilyBaseline(
            signature: family.signature, sampleCount: 1, meanMemoryBytes: Double(16 * mebibyte),
            peakMemoryBytes: 16 * mebibyte, meanCPUPercent: 4, peakCPUPercent: 4,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: now, lastSeenAt: now
        )
        let stillLearning = FamilyVerdict.synthesize(
            family: family.enriched(baseline: immatureBaseline), pattern: .unknown
        )
        XCTAssertEqual(stillLearning.headline, unlearned.headline)

        let legacyBaseline = FamilyBaseline(
            signature: family.signature, sampleCount: 10, meanMemoryBytes: Double(16 * mebibyte),
            peakMemoryBytes: 16 * mebibyte, meanCPUPercent: 4, peakCPUPercent: 4,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: now, lastSeenAt: now, measurementVersion: nil
        )
        let legacy = FamilyVerdict.synthesize(
            family: family.enriched(baseline: legacyBaseline), pattern: .unknown
        )
        XCTAssertEqual(legacy.headline, unlearned.headline)

        let trustedBaseline = FamilyBaseline(
            signature: family.signature, sampleCount: 4, meanMemoryBytes: Double(128 * mebibyte),
            peakMemoryBytes: 128 * mebibyte, meanCPUPercent: 4, peakCPUPercent: 4,
            meanLeakVelocityMegabytesPerMinute: 0, incidentCount: 0,
            firstSeenAt: now, lastSeenAt: now
        )
        let learned = FamilyVerdict.synthesize(
            family: family.enriched(baseline: trustedBaseline), pattern: .unknown
        )
        XCTAssertEqual(learned.headline, "Behaving normally")
        XCTAssertTrue(learned.detail.contains("Inside its learned range"))
    }

    func testVerdictWaitsForCurrentMeasurementsBeforeCallingProcessNormal() {
        let now = Date(timeIntervalSince1970: 2_000_020_200)
        let identity = ProcessIdentity(pid: 42_062, startTimeSeconds: 2_000_010_000, startTimeMicroseconds: 0)
        let root = makeNodeProcess(identity: identity, memoryBytes: 128 * mebibyte, cpuPercent: 4, at: now)
        let score = GhostScore(value: 0, level: .quiet, reasons: [])

        let stale = makeFamily(root: root, score: score).enriched(lastScoredAt: now.addingTimeInterval(16))
        let staleVerdict = FamilyVerdict.synthesize(family: stale, pattern: .unknown)
        XCTAssertEqual(staleVerdict.headline, "Waiting for a current reading")
        XCTAssertFalse(staleVerdict.detail.contains("no confirmed resource problem"))

        let missingRoot = makeNodeProcess(
            identity: identity, memoryBytes: 128 * mebibyte, cpuPercent: 0, at: now,
            measurementStatus: .unavailable
        )
        let missing = FamilyVerdict.synthesize(
            family: makeFamily(root: missingRoot, score: score), pattern: .unknown
        )
        XCTAssertEqual(missing.headline, "Waiting for a current reading")
        XCTAssertTrue(missing.detail.contains("missing"))
    }

    func testScoreComponentsRemainTruthfulAfterBuilderAndIntelligence() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let identity = ProcessIdentity(
            pid: 42_001,
            startTimeSeconds: UInt64(now.addingTimeInterval(-3_600).timeIntervalSince1970),
            startTimeMicroseconds: 0
        )
        let builder = ProcessFamilyBuilder(currentUserID: 501)
        var trendWindow = TrendWindow(retention: 300, maxSamples: 20)
        var settings = ThresholdSettings.aggressive
        settings.memoryBytes = 512 * mebibyte
        settings.cpuPercent = 50
        settings.leakVelocityMegabytesPerMinute = 80
        settings.radarMode = .dev

        // Establish a continuous measured window, rather than interpreting an
        // unobserved minute followed by one allocation as leak evidence.
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index * 20 - 60))
            _ = builder.buildFamilies(
                from: [makeNodeProcess(identity: identity, memoryBytes: UInt64(128 + index * 600) * mebibyte, cpuPercent: 4, at: date)],
                settings: settings,
                trendWindow: &trendWindow,
                now: date
            )
        }
        let built = builder.buildFamilies(
            from: [makeNodeProcess(identity: identity, memoryBytes: 2 * gibibyte, cpuPercent: 130, at: now)],
            settings: settings,
            trendWindow: &trendWindow,
            now: now
        )

        let baseFamily = try XCTUnwrap(built.first)
        XCTAssertTrue(baseFamily.score.components.contains { $0.kind == .memory })
        XCTAssertTrue(baseFamily.score.components.contains { $0.kind == .cpu })
        XCTAssertTrue(baseFamily.score.components.contains { $0.kind == .leak })
        XCTAssertEqual(
            baseFamily.score.components.reduce(0) { $0 + $1.impact },
            baseFamily.score.value,
            accuracy: 0.0001
        )

        let enriched = RadarIntelligence().enrich(
            family: baseFamily,
            context: RadarContext(
                baselines: [:],
                recentIncidentCounts: [:],
                rules: RadarRule.builtIns(settings: settings),
                systemPressure: SystemMemoryPressure(
                    level: .warning,
                    usedFraction: 0.9,
                    totalBytes: 16 * gibibyte,
                    availableBytes: 1 * gibibyte,
                    compressedBytes: 3 * gibibyte
                )
            ),
            settings: settings,
            now: now
        )

        XCTAssertFalse(enriched.score.components.isEmpty)
        XCTAssertTrue(enriched.score.components.allSatisfy { $0.impact > 0 })
        XCTAssertEqual(
            enriched.score.components.reduce(0) { $0 + $1.impact },
            enriched.score.value,
            accuracy: 0.0001
        )
    }

    func testIntelligenceBriefTargetsHighestRiskWithEvidence() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_100)
        let root = makeNodeProcess(
            identity: ProcessIdentity(
                pid: 42_101,
                startTimeSeconds: UInt64(now.addingTimeInterval(-7_200).timeIntervalSince1970),
                startTimeMicroseconds: 0
            ),
            memoryBytes: 2 * gibibyte,
            cpuPercent: 115,
            at: now
        )
        let score = GhostScore(
            value: 82,
            level: .hot,
            reasons: ["memory above threshold", "CPU above threshold"],
            components: [
                GhostScoreComponent(
                    kind: .memory,
                    title: "Memory far above normal",
                    detail: "2 GB exceeds the learned range",
                    impact: 48,
                    level: .hot
                ),
                GhostScoreComponent(
                    kind: .cpu,
                    title: "CPU remains elevated",
                    detail: "115% sustained CPU",
                    impact: 34,
                    level: .hot
                )
            ],
            heat: GhostHeat(
                value: 82,
                level: .hot,
                confidence: 0.72,
                evidence: ["Memory far above normal", "CPU stayed elevated"],
                sustainedSignalCount: 1
            )
        )
        let family = ProcessFamily(
            root: root,
            members: [root],
            totalResidentMemoryBytes: root.residentMemoryBytes,
            totalPhysicalFootprintBytes: root.physicalFootprintBytes,
            totalCPUPercent: root.cpuPercent,
            devConfidence: 0.95,
            commandHints: [root.commandLine],
            trend: TrendMetrics(
                memoryVelocityMegabytesPerMinute: 180,
                cpuSlopePerMinute: 12,
                memoryPoints: [900, 1_200, 1_650, 2_048],
                memoryFitQuality: 0.96
            ),
            score: score,
            ownedIdentities: [root.identity],
            protectedPIDs: [],
            lastScoredAt: now
        )
        let triage = [FamilyTriageViewModel(family: family)]
        let panel = FamilyDetailPanelModel(family: family, previous: nil)
        let summary = RadarSummary(
            statusText: "1 hot",
            level: .hot,
            familyCount: 1,
            hotCount: 1,
            totalMemoryBytes: family.totalPhysicalFootprintBytes,
            topFamilyName: family.displayName,
            leakingCount: 1,
            suggestionCount: 0
        )
        let compact = CompactConsoleSnapshot.build(
            summary: summary,
            triage: triage,
            detailPanels: [family.familyKey: panel],
            engineStatus: .empty
        )

        XCTAssertEqual(compact.intelligenceBrief.familyKey, family.familyKey)
        XCTAssertEqual(compact.intelligenceBrief.familyName, family.displayName)
        XCTAssertFalse(compact.intelligenceBrief.title.isEmpty)
        XCTAssertFalse(compact.intelligenceBrief.recommendation.isEmpty)
        XCTAssertTrue(compact.intelligenceBrief.evidence.contains("Memory far above normal"))
        XCTAssertEqual(compact.intelligenceBrief.level, .hot)
        XCTAssertEqual(compact.intelligenceBrief.confidenceText, "Building history")
        XCTAssertTrue(compact.intelligenceBrief.title.contains("node"))
        XCTAssertFalse(compact.intelligenceBrief.confidenceText.contains("Heat"))
        XCTAssertTrue(compact.intelligenceBrief.recommendation.contains("Kill Preview"))
    }

    private func makeNodeProcess(
        identity: ProcessIdentity,
        memoryBytes: UInt64,
        cpuPercent: Double,
        at date: Date,
        measurementStatus: ProcessMeasurementStatus = .fresh
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: identity,
            parentPID: 1,
            userID: 501,
            ownerName: "tester",
            name: "node",
            executablePath: "/usr/local/bin/node",
            commandLine: "node server.js --port 3000",
            residentMemoryBytes: memoryBytes,
            physicalFootprintBytes: memoryBytes,
            virtualMemoryBytes: memoryBytes * 2,
            cpuPercent: cpuPercent,
            totalProcessorSeconds: 90,
            threadCount: 12,
            isSystemProcess: false,
            sampledAt: date,
            measurementStatus: measurementStatus
        )
    }

    private func makeFamily(
        root: ProcessMetrics,
        score: GhostScore,
        recentIncidentCount: Int = 0
    ) -> ProcessFamily {
        ProcessFamily(
            root: root,
            members: [root],
            totalResidentMemoryBytes: root.residentMemoryBytes,
            totalPhysicalFootprintBytes: root.physicalFootprintBytes,
            totalCPUPercent: root.cpuPercent,
            devConfidence: 0.95,
            commandHints: [root.commandLine],
            trend: .empty,
            score: score,
            ownedIdentities: [root.identity],
            protectedPIDs: [],
            recentIncidentCount: recentIncidentCount
        )
    }
}
