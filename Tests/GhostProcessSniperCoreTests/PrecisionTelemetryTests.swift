import Darwin
import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

final class PrecisionTelemetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let mib: UInt64 = 1_048_576

    func testSensorDecodersAcceptCelsiusAndRejectInvalidData() throws {
        let bits = Float(79.25).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        XCTAssertEqual(try XCTUnwrap(SMCTemperatureCodec.decode(type: "flt ", bytes: bytes)), 79.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SMCTemperatureCodec.decode(type: "sp78", bytes: [0x4f, 0x40])), 79.25, accuracy: 0.001)
        XCTAssertNil(SMCTemperatureCodec.decode(type: "flt ", bytes: [0, 0, 0, 0]))
        XCTAssertNil(SMCTemperatureCodec.decode(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]))
        XCTAssertNil(SMCTemperatureCodec.decode(type: "flt ", bytes: [1, 2]))
        XCTAssertNil(SMCTemperatureCodec.decode(type: "sp78", bytes: [0xff, 0]))
        XCTAssertNil(SMCTemperatureCodec.decode(type: "ui16", bytes: [0x4f, 0x40]))
    }

    func testTemperatureAvailabilityUsesSampleAge() {
        let snapshot = ThermalSnapshot(sampledAt: now, cpuCelsius: 75.5, gpuCelsius: nil, sensorCount: 1,
                                       sensorKeys: ["Tp09"], systemState: "Nominal", unavailableReason: nil)
        XCTAssertEqual(snapshot.temperatureText(snapshot.cpuCelsius, at: now), "75.5°C")
        XCTAssertEqual(snapshot.temperatureText(snapshot.cpuCelsius, at: now.addingTimeInterval(16)), "Unavailable")
        XCTAssertEqual(snapshot.temperatureText(snapshot.cpuCelsius, at: now.addingTimeInterval(-1)), "Unavailable")
        XCTAssertEqual(snapshot.temperatureText(snapshot.gpuCelsius, at: now), "Unavailable")
    }

    func testCachedAndOutOfOrderReadingsDoNotManufactureHistory() {
        var window = TrendWindow()
        _ = window.update(signatureID: "instance", memoryBytes: 100 * mib, cpuPercent: 0, at: now)
        for _ in 0..<20 {
            let repeated = window.update(signatureID: "instance", memoryBytes: 100 * mib, cpuPercent: 0, at: now)
            XCTAssertEqual(repeated.sampleCount, 1)
        }
        let old = window.update(signatureID: "instance", memoryBytes: 0, cpuPercent: 0, at: now.addingTimeInterval(-1))
        XCTAssertEqual(old.sampleCount, 1)
        let resumed = window.update(signatureID: "instance", memoryBytes: 500 * mib, cpuPercent: 1, at: now.addingTimeInterval(200))
        XCTAssertEqual(resumed.sampleCount, 1)
        XCTAssertEqual(resumed.memoryVelocityMegabytesPerMinute, 0)
    }

    func testMissingThenMeasuredFootprintStartsANewTrend() throws {
        var window = TrendWindow()
        let builder = ProcessFamilyBuilder(currentUserID: 501)
        var settings = ThresholdSettings.smart
        settings.radarMode = .all
        settings.groupFamilies = false
        let missing = process(bytes: 0, status: .unavailable)
        let first = try XCTUnwrap(builder.buildFamilies(from: [missing], settings: settings, trendWindow: &window, now: now).first)
        XCTAssertEqual(first.trend.sampleCount, 0)
        let measured = process(bytes: 3_000 * mib, date: now.addingTimeInterval(5))
        let second = try XCTUnwrap(builder.buildFamilies(from: [measured], settings: settings, trendWindow: &window, now: now.addingTimeInterval(5)).first)
        XCTAssertEqual(second.trend.sampleCount, 1)
        XCTAssertEqual(second.trend.memoryVelocityMegabytesPerMinute, 0)
    }

    func testCachedFamilySampleRetainsOriginalMeasurementDate() throws {
        var window = TrendWindow()
        let builder = ProcessFamilyBuilder(currentUserID: 501)
        var settings = ThresholdSettings.smart
        settings.radarMode = .all
        settings.groupFamilies = false
        _ = builder.buildFamilies(from: [process()], settings: settings, trendWindow: &window, now: now)
        let cached = process(date: now.addingTimeInterval(4), status: .cached(now))
        let next = try XCTUnwrap(builder.buildFamilies(from: [cached], settings: settings, trendWindow: &window, now: now.addingTimeInterval(4)).first)
        XCTAssertEqual(next.trend.sampleCount, 1)
        XCTAssertEqual(next.measurementDate, now)
        XCTAssertFalse(next.hasRecentMeasurements(at: now.addingTimeInterval(16)))
    }

    func testIncompleteMeasurementsDoNotRaiseLiveAlertsOrTrainBaseline() {
        let missing = family(root: process(bytes: 3_000 * mib, status: .unavailable), level: .critical)
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        let enriched = RadarIntelligence().enrich(family: missing, context: context, settings: .smart, now: now)
        XCTAssertFalse(enriched.score.heat.shouldRaiseLiveAlert)
        XCTAssertEqual(ProcessAssessment(family: enriched).status, "Measuring")
        let baseline = FamilyBaselineLearner().updated(existing: nil, family: enriched, now: now)
        XCTAssertEqual(baseline.sampleCount, 0)
        XCTAssertEqual(baseline.meanMemoryBytes, 0)
    }

    func testLegacyBaselineIsRelearnedAndCachedDataIsNotLearnedTwice() {
        let f = family(root: process())
        let legacy = FamilyBaseline(signature: f.signature, sampleCount: 1_000, meanMemoryBytes: 12,
            peakMemoryBytes: 20, meanCPUPercent: 0, peakCPUPercent: 0, meanLeakVelocityMegabytesPerMinute: 0,
            incidentCount: 0, firstSeenAt: now.addingTimeInterval(-600), lastSeenAt: now.addingTimeInterval(-1), measurementVersion: 0)
        XCTAssertEqual(legacy.memoryMultiple(for: f.totalPhysicalFootprintBytes), 1)
        let learned = FamilyBaselineLearner().updated(existing: legacy, family: f, now: now)
        XCTAssertEqual(learned.sampleCount, 1)
        XCTAssertEqual(learned.meanMemoryBytes, Double(f.totalPhysicalFootprintBytes))
        let cachedFamily = family(root: process(date: now.addingTimeInterval(2), status: .cached(now)))
        let repeated = FamilyBaselineLearner().updated(existing: learned, family: cachedFamily, now: now.addingTimeInterval(2))
        XCTAssertEqual(repeated.sampleCount, 1)
    }

    func testBaselineSchemaMigrationPreservesLegacyRowAndPersistsProvenance() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-precision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let signature = process().signatureForTest
        let sql = """
        CREATE TABLE baselines(signature_id TEXT PRIMARY KEY, display_name TEXT, canonical_path TEXT,
          command_fingerprint TEXT, sample_count INTEGER, mean_memory_bytes REAL, peak_memory_bytes INTEGER,
          mean_cpu_percent REAL, peak_cpu_percent REAL, mean_leak_velocity REAL, incident_count INTEGER,
          first_seen_at REAL, last_seen_at REAL);
        INSERT INTO baselines VALUES('\(signature.id)', 'node', '/usr/local/bin/node', '\(signature.commandFingerprint)', 999, 12, 20, 0, 0, 0, 0, 9000, 9999);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let store = try RadarStore(url: url)
        let f = family(root: process())
        let initial = try await store.context(for: [f], settings: .smart, now: now)
        XCTAssertEqual(initial.baselines[f.signature.id]?.measurementVersion, 0)
        XCTAssertEqual(initial.baselines[f.signature.id]?.sampleCount, 999)
        let model = RadarModel(families: [f], summary: .empty, incidents: [], rules: [], health: .starting, generatedAt: now)
        _ = try await store.enqueue(model: model, settings: .smart)
        try await store.flush()
        let reopened = try RadarStore(url: url)
        let loaded = try await reopened.context(for: [f], settings: .smart, now: now)
        XCTAssertEqual(loaded.baselines[f.signature.id]?.measurementVersion, 1)
        XCTAssertEqual(loaded.baselines[f.signature.id]?.sampleCount, 1)
    }

    func testRecurringHistoryAloneDoesNotMakeQuietActivityUrgent() {
        let f = family(root: process())
        let refined = GhostHeatModel.refined(base: .quiet, family: f, baseline: nil, recentIncidentCount: 500,
                                            pressure: .unknown, forecast: .quiet)
        XCTAssertEqual(refined.level, .quiet)
        XCTAssertEqual(refined.value, 0)
        XCTAssertFalse(refined.shouldNotify)
    }

    func testShortBurstDoesNotBecomeSustainedLeakEvidence() {
        let samples = (0..<4).map { TrendSample(date: now.addingTimeInterval(Double($0)), memoryBytes: UInt64(100 + $0 * 100) * mib, cpuPercent: 0) }
        let trend = TrendMetrics(memoryVelocityMegabytesPerMinute: 6_000, cpuSlopePerMinute: 0,
            memoryPoints: samples.map { Double($0.memoryBytes) }, memoryFitQuality: 1, samples: samples)
        XCTAssertFalse(trend.hasSustainedHistory)
        let heat = GhostHeatModel.initial(memoryRatio: 0.4, cpuRatio: 0, gpuRatio: 0, leakRatio: 60, trend: trend, hardwareLevel: .quiet)
        XCTAssertEqual(heat.sustainedSignalCount, 0)
        XCTAssertNotEqual(heat.level, .critical)
    }

    func testAirSubstringDoesNotMisclassifyNativeServices() {
        let classifier = DevProcessClassifier()
        for name in ["AirPlayUIAgent", "remotepairingd"] {
            XCTAssertNotEqual(classifier.classification(for: process(name: name, path: "/System/Library/" + name)).kind, .goService)
        }
        XCTAssertEqual(classifier.classification(for: process(name: "air", path: "/opt/homebrew/bin/air")).kind, .goService)
    }

    func testApprovedSingleProcessPreviewExcludesDescendants() async {
        let root = process(pid: 92_001, bytes: 100 * mib)
        let child = process(pid: 92_002, parent: 92_001, bytes: 200 * mib)
        let world = PrecisionWorld([root, child])
        let killer = ProcessKiller(lookup: world, signaler: world, currentUserID: 501, sleeper: { _ in })
        let plan = family(root: root, members: [root, child]).killPlan().targetingOnly(root)
        let preview = await killer.preview(plan: plan)
        XCTAssertEqual(preview.targetIdentities, [root.identity])
        XCTAssertEqual(preview.estimatedMemoryReclaimBytes, root.memoryForScoringBytes)
    }

    func testApprovedScopeSkipsNewChildAndOnlySignalsApprovedIdentity() async {
        let root = process(pid: 92_011)
        let child = process(pid: 92_012, parent: 92_011)
        let world = PrecisionWorld([root, child])
        let killer = ProcessKiller(lookup: world, signaler: world, currentUserID: 501, sleeper: { _ in })
        let plan = family(root: root).killPlan().binding(to: [root.identity], expiresAt: Date().addingTimeInterval(60), strategy: .standard)
        let preview = await killer.preview(plan: plan)
        XCTAssertEqual(preview.targetIdentities, [root.identity])
        XCTAssertTrue(preview.lockedTargets.contains { $0.identity == child.identity })
        let report = await killer.kill(plan: plan, forceKillDelay: 0, skipForce: true)
        XCTAssertFalse(world.signals.isEmpty)
        XCTAssertEqual(world.signals.first?.signal, SIGTERM, "Confirmation must retain the selected strategy")
        XCTAssertEqual(Set(world.signals.map(\.pid)), [root.pid])
        XCTAssertFalse(report.gracefulPIDs.contains(child.pid))
    }

    func testExpiredApprovalCannotSendAnySignal() async {
        let root = process(pid: 92_021)
        let world = PrecisionWorld([root])
        let killer = ProcessKiller(lookup: world, signaler: world, currentUserID: 501, sleeper: { _ in })
        let plan = family(root: root).killPlan().binding(to: [root.identity], expiresAt: Date().addingTimeInterval(-1))
        let report = await killer.kill(plan: plan, forceKillDelay: 0)
        XCTAssertTrue(world.signals.isEmpty)
        XCTAssertTrue(report.failures.contains { $0.contains("expired") })
    }

    func testRecycledIdentityCannotInheritApproval() async {
        let original = process(pid: 92_031)
        let replacement = process(pid: 92_031, started: 9_900)
        let world = PrecisionWorld([replacement])
        let killer = ProcessKiller(lookup: world, signaler: world, currentUserID: 501, sleeper: { _ in })
        let plan = family(root: original).killPlan().binding(to: [original.identity], expiresAt: Date().addingTimeInterval(60))
        _ = await killer.kill(plan: plan, forceKillDelay: 0)
        XCTAssertTrue(world.signals.isEmpty)
    }

    func testMissingSingleTargetMetricsNeverClaimWholeFamilyReclaim() {
        let root = process(bytes: 500 * mib)
        let child = process(pid: 92_041, parent: root.pid, bytes: 0)
        let plan = family(root: root, members: [root, child]).killPlan().targetingOnly(child)
        let target = KillTarget(process: child, depth: 0, state: .ready, reason: "fixture", rootIdentity: child.identity)
        XCTAssertEqual(KillReclaimEstimator().estimate(plan: plan, targets: [target]).memoryBytes, 0)
        XCTAssertEqual(KillReclaimEstimator().estimate(plan: plan, targets: []).memoryBytes, 0)
    }

    func testCurrentSeverityOutranksAnUnconfirmedForecast() {
        let urgent = family(root: process(pid: 92_060, bytes: 2_000 * mib), level: .critical)
        let unconfirmed = RiskForecast(state: .runaway, horizon: .imminent, confidence: 0.1,
            etaSeconds: 30, etaText: "30s", whyNow: "Unconfirmed fixture", recommendedAction: RiskForecast.quiet.recommendedAction,
            projectedMemoryBytes: 1_000 * mib, projectedCPUPercent: 200, leakAccelerationMegabytesPerMinute2: 0,
            recurrenceRisk: 0, staleLikelihood: 0, baseline: .unknown, generatedAt: now)
        let quiet = family(root: process(pid: 92_061)).enriched(forecast: unconfirmed)
        let snapshot = RadarConsoleSnapshot.build(families: [quiet, urgent], summary: .empty, incidents: [],
            rules: [], metrics: .empty, health: .starting, storeHealth: .empty, storeError: nil,
            previous: nil, generatedAt: now)
        XCTAssertEqual(snapshot.families.first?.familyKey, urgent.familyKey)
        XCTAssertEqual(snapshot.compact.topRiskRows.first?.id, urgent.familyKey)
    }

    func testNewFamilyMemberDoesNotBecomeAnArtificialLeak() throws {
        let root = process(pid: 92_070)
        let child = process(pid: 92_071, parent: root.pid, bytes: 300 * mib,
                            date: now.addingTimeInterval(5), name: "worker", path: "/usr/local/bin/worker")
        let builder = ProcessFamilyBuilder(currentUserID: 501)
        var settings = ThresholdSettings.smart
        settings.groupFamilies = true
        settings.radarMode = .dev
        var window = TrendWindow()
        _ = builder.buildFamilies(from: [root], settings: settings, trendWindow: &window, now: now)
        let refreshedRoot = process(pid: root.pid, date: now.addingTimeInterval(5))
        let updated = try XCTUnwrap(builder.buildFamilies(from: [refreshedRoot, child], settings: settings,
            trendWindow: &window, now: now.addingTimeInterval(5)).first { $0.root.pid == root.pid })
        XCTAssertEqual(updated.members.count, 2)
        XCTAssertEqual(updated.trend.sampleCount, 1)
        XCTAssertEqual(updated.trend.memoryVelocityMegabytesPerMinute, 0)
    }

    func testEmptyApprovalCannotExpandToAnOwnedTree() async {
        let root = process(pid: 92_080)
        let world = PrecisionWorld([root])
        let killer = ProcessKiller(lookup: world, signaler: world, currentUserID: 501, sleeper: { _ in })
        let plan = family(root: root).killPlan().binding(to: [], expiresAt: Date().addingTimeInterval(60))
        _ = await killer.kill(plan: plan, forceKillDelay: 0)
        XCTAssertTrue(world.signals.isEmpty)
    }

    func testScoringCacheKeepsFreshReadingsWhenResourceNumbersAreUnchanged() throws {
        var cache = FamilyScoringCache()
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        let first = family(root: process())
        cache.store(first, context: context)
        let nextDate = now.addingTimeInterval(2)
        let current = family(root: process(date: nextDate))
        let reused = try XCTUnwrap(cache.cachedFamily(for: current, context: context))
        XCTAssertEqual(reused.root.sampledAt, nextDate)
        XCTAssertEqual(reused.measurementDate, nextDate)
        XCTAssertEqual(reused.score, first.score)
        XCTAssertEqual(ProcessAssessment(family: reused).status, "Stable")
    }

    func testScoringCacheInvalidatesWhenMeasurementsBecomeStaleOrMissing() {
        var cache = FamilyScoringCache()
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        cache.store(family(root: process()), context: context)
        let stale = family(root: process(date: now.addingTimeInterval(16), status: .cached(now)))
        XCTAssertNil(cache.cachedFamily(for: stale, context: context))
        let missing = family(root: process(status: .unavailable))
        XCTAssertNil(cache.cachedFamily(for: missing, context: context))
    }

    private func process(pid: Int32 = 92_000, parent: Int32 = 1, bytes: UInt64 = 100 * 1_048_576,
                         cpu: Double = 0, date: Date? = nil, status: ProcessMeasurementStatus = .fresh,
                         name: String = "node", path: String = "/usr/local/bin/node", started: UInt64 = 9_000) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: started, startTimeMicroseconds: 0),
                       parentPID: parent, userID: 501, ownerName: "fixture", name: name, executablePath: path,
                       commandLine: name + " fixture", residentMemoryBytes: bytes, physicalFootprintBytes: bytes,
                       virtualMemoryBytes: bytes, cpuPercent: cpu, totalProcessorSeconds: 0, threadCount: 1,
                       isSystemProcess: false, sampledAt: date ?? now, measurementStatus: status)
    }

    private func family(root: ProcessMetrics, members: [ProcessMetrics]? = nil, level: GhostLevel = .quiet) -> ProcessFamily {
        let members = members ?? [root]
        return ProcessFamily(root: root, members: members,
                             totalResidentMemoryBytes: members.reduce(0) { $0 + $1.residentMemoryBytes },
                             totalPhysicalFootprintBytes: members.reduce(0) { $0 + $1.physicalFootprintBytes },
                             totalCPUPercent: members.reduce(0) { $0 + $1.cpuPercent }, devConfidence: 0.9,
                             commandHints: [root.commandLine], trend: .empty,
                             score: GhostScore(value: level == .quiet ? 0 : 90, level: level, reasons: []),
                             ownedIdentities: members.map(\.identity), protectedPIDs: [], lastScoredAt: root.sampledAt)
    }
}

private extension ProcessMetrics {
    var signatureForTest: ProcessSignature { ProcessSignature.from(root: self) }
}

/// An isolated process namespace. No test here calls Darwin.kill or touches live processes.
private final class PrecisionWorld: ProcessLookup, ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: [ProcessMetrics]
    private var sent: [(pid: Int32, signal: Int32)] = []
    init(_ processes: [ProcessMetrics]) { alive = processes }
    var signals: [(pid: Int32, signal: Int32)] { lock.withLock { sent } }
    func processes() async throws -> [ProcessMetrics] { lock.withLock { alive } }
    func send(signal: Int32, to pid: Int32) throws {
        lock.withLock {
            sent.append((pid, signal))
            alive.removeAll { $0.pid == pid }
        }
    }
    func exists(pid: Int32) -> Bool { lock.withLock { alive.contains { $0.pid == pid } } }
}
