import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class IncidentEpisodeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-episodes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testDipsAndSnoozesStayOneEpisode() async throws {
        let store = makeStore()
        let steps: [(GhostLevel, AlertStateKind)] = [
            (.hot, .normal), (.hot, .normal), (.watch, .normal), (.hot, .normal),
            (.watch, .normal), (.hot, .normal), (.hot, .snoozed), (.hot, .normal)
        ]
        for (index, step) in steps.enumerated() {
            let date = at(Double(index) * 3)
            try await persist([family(level: step.0, alert: step.1, at: date)], store: store, at: date)
        }

        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.count, 1, "one busy process is one episode")
        XCTAssertNil(incidents.first?.resolvedAt)
        XCTAssertEqual(incidents.first?.occurrenceCount, 1)
        let hot = family(level: .hot, at: at(24))
        let context = try await store.context(for: [hot], settings: .smart, now: at(24))
        XCTAssertEqual(context.recentIncidentCounts[hot.signature.id, default: 0], 0)
    }

    func testCriticalPeakSurvivesCoolingToHot() async throws {
        let store = makeStore()
        try await persist([family(level: .critical, memory: 5_000_000_000, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, memory: 3_000_000_000, at: at(40))], store: store, at: at(40))

        let incident = try await latest(store)
        XCTAssertEqual(incident.level, .critical, "an episode is filed under its peak")
        XCTAssertEqual(incident.memoryBytes, 5_000_000_000, "memory is the episode's peak")
        XCTAssertEqual(incident.lastSeenAt, at(40))
    }

    func testQuietUpdatesAreThrottledToEveryThirtySeconds() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, at: at(3))], store: store, at: at(3))
        var incident = try await latest(store)
        XCTAssertEqual(incident.lastSeenAt, at(0), "an unchanged episode is not rewritten every tick")

        try await persist([family(level: .hot, at: at(33))], store: store, at: at(33))
        incident = try await latest(store)
        XCTAssertEqual(incident.lastSeenAt, at(33))
    }

    func testAbsenceResolvesAtTheLastActiveTime() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, at: at(3))], store: store, at: at(3))
        try await persist([], store: store, at: at(50))
        var incident = try await latest(store)
        XCTAssertNil(incident.resolvedAt, "a short absence keeps the episode open")

        try await persist([], store: store, at: at(103))
        incident = try await latest(store)
        XCTAssertEqual(incident.resolvedAt, at(3))
        XCTAssertEqual(incident.lastSeenAt, at(3), "closing must not move the last sighting")
    }

    func testReturnWithinTenMinutesReopensTheSameEpisode() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([], store: store, at: at(100))
        let closed = try await latest(store)
        XCTAssertEqual(closed.resolvedAt, at(0))

        try await persist([family(level: .hot, at: at(300))], store: store, at: at(300))
        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?.id, closed.id)
        XCTAssertEqual(incidents.first?.occurrenceCount, 2)
        XCTAssertNil(incidents.first?.resolvedAt)
        XCTAssertEqual(incidents.first?.startedAt, at(0))
    }

    func testReturnAfterTwentyMinutesStartsANewEpisode() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([], store: store, at: at(100))
        try await persist([family(level: .hot, at: at(1_200))], store: store, at: at(1_200))

        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents.map(\.occurrenceCount), [1, 1])
        let hot = family(level: .hot, at: at(1_203))
        let context = try await store.context(for: [hot], settings: .smart, now: at(1_203))
        XCTAssertEqual(context.recentIncidentCounts[hot.signature.id], 1)
    }

    func testGapLongerThanTenMinutesEndsTheEpisodeBeforeItContinues() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, at: at(3))], store: store, at: at(3))
        // The Mac slept: no scan for an hour, then the family is still hot.
        try await persist([family(level: .hot, at: at(3_603))], store: store, at: at(3_603))

        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.count, 2, "an hour nobody watched is not part of the episode")
        let fresh = try XCTUnwrap(incidents.first)
        let old = try XCTUnwrap(incidents.last)
        XCTAssertNil(fresh.resolvedAt)
        XCTAssertEqual(fresh.startedAt, at(3_603))
        XCTAssertEqual(old.resolvedAt, at(3), "the old episode ends at its last sighting")
        XCTAssertEqual(old.lastSeenAt, at(3))
        let hot = family(level: .hot, at: at(3_606))
        let context = try await store.context(for: [hot], settings: .smart, now: at(3_606))
        XCTAssertEqual(context.recentIncidentCounts[hot.signature.id], 1, "the ended episode counts as a past one")
    }

    func testGapBetweenNinetySecondsAndTenMinutesReopensAndCountsAHit() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, at: at(3))], store: store, at: at(3))
        try await persist([family(level: .hot, at: at(303))], store: store, at: at(303))

        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?.occurrenceCount, 2, "five minutes unobserved is a second hit on the same row")
        XCTAssertEqual(incidents.first?.startedAt, at(0))
        XCTAssertNil(incidents.first?.resolvedAt)
    }

    func testMutedFamilyEndsItsEpisodeAtAGapToo() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, at: at(3))], store: store, at: at(3))
        try await persist([family(level: .hot, alert: .snoozed, at: at(3_603))], store: store, at: at(3_603))

        let incidents = try await store.recentIncidents()
        XCTAssertEqual(incidents.count, 1, "a snoozed family starts no episode")
        XCTAssertEqual(incidents.first?.resolvedAt, at(3), "the hour before it was snoozed is not part of the episode")
    }

    func testIgnoredFamilyKeepsItsEpisodeAliveWithoutWriting() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        for second in stride(from: 30.0, through: 150, by: 30) {
            try await persist([family(level: .hot, alert: .ignored, at: at(second))], store: store, at: at(second))
        }
        let incident = try await latest(store)
        XCTAssertNil(incident.resolvedAt, "an ignored family that is still hot keeps its episode open")
        XCTAssertEqual(incident.lastSeenAt, at(0), "suppressed samples write nothing")
    }

    func testOpenEpisodeFromAPreviousRunClosesAtItsLastSighting() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let first = RadarStore(url: url)
        try await persist([family(level: .hot, at: at(0))], store: first, at: at(0))
        await first.close()

        let second = RadarStore(url: url)
        try await persist([], store: second, at: at(3_600))
        let incident = try await latest(second)
        XCTAssertEqual(incident.resolvedAt, at(0), "a restart must not stamp old episodes with the launch time")
        XCTAssertEqual(incident.lastSeenAt, at(0))
    }

    func testCPUAndGrowthAreTheEpisodePeaks() async throws {
        let store = makeStore()
        let climbing = climbingTrend()
        XCTAssertGreaterThan(climbing.credibleMemoryVelocity, 100, "the fixture must be a proven climb")
        try await persist([family(level: .hot, cpu: 300, trend: climbing, at: at(0))], store: store, at: at(0))
        // The write that lands 40 s later is a calm tick.
        try await persist([family(level: .hot, cpu: 5, at: at(40))], store: store, at: at(40))

        let incident = try await latest(store)
        XCTAssertEqual(incident.lastSeenAt, at(40), "the calm tick was the throttled write")
        XCTAssertEqual(incident.cpuPercent, 300, "CPU is the episode's peak, not the last sample written")
        XCTAssertEqual(incident.leakVelocityMegabytesPerMinute, climbing.credibleMemoryVelocity, accuracy: 0.001)
    }

    func testAPeakBetweenWritesIsCarriedWhenTheEpisodeCloses() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, cpu: 50, at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, cpu: 400, trend: climbingTrend(), at: at(10))], store: store, at: at(10))
        var incident = try await latest(store)
        XCTAssertEqual(incident.cpuPercent, 50, "a CPU peak alone does not trigger a write")

        try await persist([], store: store, at: at(200))
        incident = try await latest(store)
        XCTAssertNotNil(incident.resolvedAt)
        XCTAssertEqual(incident.cpuPercent, 400)
        XCTAssertGreaterThan(incident.leakVelocityMegabytesPerMinute, 100)
    }

    func testOneSampleJumpIsNotRecordedAsGrowth() async throws {
        let store = makeStore()
        let jump = IntelligenceFixture.trend(megabytes: [300, 340], cadence: 0.75)
        XCTAssertGreaterThan(jump.memoryVelocityMegabytesPerMinute, 1_000, "the raw two-point slope is huge")
        XCTAssertEqual(jump.credibleMemoryVelocity, 0)
        try await persist([family(level: .hot, trend: jump, at: at(0))], store: store, at: at(0))

        let incident = try await latest(store)
        XCTAssertEqual(incident.leakVelocityMegabytesPerMinute, 0, "growth needs proven history, like the scorer")
    }

    func testSlowLeakGrowthIsRecordedFromTheLongTermTrend() async throws {
        let store = makeStore()
        // Half an hour of steady, persistent growth that the short window
        // alone cannot prove: the app's own definition of a slow leak.
        let slowLeak = LongTermTrend(slopeMegabytesPerMinute: 100, floorSlopeMegabytesPerMinute: 90, rSquared: 0.9,
                                     spanMinutes: 30, persistentSlopeMegabytesPerMinute: 100)
        try await persist([family(level: .hot, longTerm: slowLeak, at: at(0))], store: store, at: at(0))

        let incident = try await latest(store)
        XCTAssertEqual(incident.leakVelocityMegabytesPerMinute, 100)
    }

    func testPeaksSurviveARelaunch() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let first = RadarStore(url: url)
        try await persist([family(level: .hot, cpu: 300, trend: climbingTrend(), at: at(0))], store: first, at: at(0))
        let peak = try await latest(first)
        await first.close()

        // The episode is still open, so the cooler refresh continues it.
        let second = RadarStore(url: url)
        try await persist([family(level: .hot, cpu: 5, at: at(45))], store: second, at: at(45))
        let incident = try await latest(second)
        XCTAssertEqual(incident.lastSeenAt, at(45))
        XCTAssertEqual(incident.cpuPercent, 300, "a relaunch starts its tracking at zero and must not lower the row")
        XCTAssertEqual(incident.leakVelocityMegabytesPerMinute, peak.leakVelocityMegabytesPerMinute)
    }

    func testReopenedEpisodeKeepsItsPeaks() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, cpu: 300, trend: climbingTrend(), at: at(0))], store: store, at: at(0))
        try await persist([], store: store, at: at(100))
        try await persist([family(level: .hot, cpu: 5, at: at(300))], store: store, at: at(300))

        let incident = try await latest(store)
        XCTAssertEqual(incident.occurrenceCount, 2)
        XCTAssertEqual(incident.cpuPercent, 300)
        XCTAssertGreaterThan(incident.leakVelocityMegabytesPerMinute, 100)
    }

    func testCopiedReportNamesTheValuesAsPeaks() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, cpu: 300, trend: climbingTrend(), at: at(0))], store: store, at: at(0))
        try await persist([family(level: .hot, cpu: 5, at: at(40))], store: store, at: at(40))

        let report = try await store.exportIncidentReport()
        XCTAssertTrue(report.contains("peak cpu: 300%"), report)
        XCTAssertTrue(report.contains("peak growth: 200 MB/min"), report)
    }

    func testRecurrenceSortRanksReopenedEpisodeAboveSingleHits() {
        let signature = ProcessSignature(id: "a", displayName: "a", canonicalPath: "/a", commandFingerprint: "a")
        let other = ProcessSignature(id: "b", displayName: "b", canonicalPath: "/b", commandFingerprint: "b")
        let reopened = incident(signature: signature, hits: 4, lastSeen: at(0))
        let splitA = incident(signature: other, hits: 1, lastSeen: at(10))
        let splitB = incident(signature: other, hits: 1, lastSeen: at(20))
        let sorted = IncidentQuery(sort: .recurrence).apply(to: [splitA, splitB, reopened])
        XCTAssertEqual(sorted.first?.id, reopened.id, "four hits in one episode outrank two single-hit rows")
    }

    // MARK: History

    func testHistoryReachesPastThePublishedWindow() async throws {
        let store = makeStore()
        try await persistJobs(120, store: store)

        let published = try await store.recentIncidents()
        XCTAssertEqual(published.count, IncidentHistory.publishedWindow)
        XCTAssertFalse(published.contains { $0.familyName == "job-000" }, "the oldest episode is outside the published window")

        let history = try await store.incidentHistory()
        XCTAssertEqual(history.incidents.count, 120)
        XCTAssertFalse(history.isTruncated)
        XCTAssertEqual(history.incidents.first?.familyName, "job-119", "newest first, like the published list")
        XCTAssertEqual(history.incidents.last?.familyName, "job-000")
    }

    func testHistoryReportsWhenTheTableHoldsMoreThanItReturned() async throws {
        let store = makeStore()
        try await persistJobs(7, store: store)

        let short = try await store.incidentHistory(limit: 5)
        XCTAssertEqual(short.incidents.map(\.familyName), ["job-006", "job-005", "job-004", "job-003", "job-002"])
        XCTAssertTrue(short.isTruncated)

        let exact = try await store.incidentHistory(limit: 7)
        XCTAssertEqual(exact.incidents.count, 7)
        XCTAssertFalse(exact.isTruncated, "asking for exactly what is there leaves nothing out")
    }

    func testEveryHistoryReadHasItsOwnRevision() async throws {
        let store = makeStore()
        try await persistJobs(2, store: store)
        let first = try await store.incidentHistory()
        let second = try await store.incidentHistory()
        XCTAssertGreaterThan(first.revision, 0, "zero means no history in a console request")
        XCTAssertGreaterThan(second.revision, first.revision, "an unchanged table must still be told apart from an earlier read")
    }

    func testIncidentWritesCountOnlyWhatReachedTheTable() async throws {
        let store = makeStore()
        var writes = await store.storeHealth().writeStats.incidentWrites
        XCTAssertEqual(writes, 0)

        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        writes = await store.storeHealth().writeStats.incidentWrites
        XCTAssertEqual(writes, 1, "opening an episode inserts one row")

        try await persist([family(level: .hot, at: at(3))], store: store, at: at(3))
        let quiet = await store.storeHealth().writeStats.incidentWrites
        XCTAssertEqual(quiet, writes, "a throttled tick writes nothing, so a reader has nothing to re-read")

        try await persist([], store: store, at: at(100))
        let closed = await store.storeHealth().writeStats.incidentWrites
        XCTAssertGreaterThan(closed, quiet, "closing the episode is a write")
    }

    func testHistoryCarriesTheWriteCountItWasReadAt() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        let health = await store.storeHealth()
        let history = try await store.incidentHistory()
        XCTAssertEqual(history.writeCount, health.writeStats.incidentWrites, "rows and counter are read together, so they cannot disagree")
    }

    func testAFailedFlushDoesNotCountItsStagedWrites() async throws {
        let store = makeStore()
        try await persist([family(level: .hot, at: at(0))], store: store, at: at(0))
        let before = await store.storeHealth().writeStats.incidentWrites

        // The next episode's insert fails inside the transaction and is discarded.
        try await store.execute("DROP TABLE incidents")
        do {
            try await persist([family(level: .hot, name: "other", at: at(1_200))], store: store, at: at(1_200))
            XCTFail("the flush should have failed without an incidents table")
        } catch {}
        let after = await store.storeHealth().writeStats.incidentWrites
        XCTAssertEqual(after, before, "a rolled-back write must not tell readers the table changed")
    }

    /// `count` distinct jobs twenty minutes apart: each is its own episode,
    /// closed by the next one's scan.
    private func persistJobs(_ count: Int, store: RadarStore) async throws {
        for index in 0..<count {
            let date = at(Double(index) * 1_200)
            let name = "job-" + String(format: "%03d", index)
            try await persist([family(level: .hot, name: name, at: date)], store: store, at: date)
        }
    }

    /// 200 MB/min for a minute: a real TrendWindow, so its growth is credible.
    private func climbingTrend() -> TrendMetrics {
        IntelligenceFixture.trend(megabytes: (0..<10).map { 500 + Double($0) * 20 }, cadence: 6)
    }

    private func makeStore() -> RadarStore {
        RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func latest(_ store: RadarStore) async throws -> RadarIncident {
        let incidents = try await store.recentIncidents()
        return try XCTUnwrap(incidents.first)
    }

    private func persist(_ families: [ProcessFamily], store: RadarStore, at date: Date) async throws {
        let model = RadarModel(families: families, summary: .empty, incidents: [], rules: [], health: .starting, generatedAt: date)
        _ = try await store.enqueue(model: model, settings: .smart, now: date)
        try await store.flush(now: date)
    }

    private func incident(signature: ProcessSignature, hits: Int, lastSeen: Date) -> RadarIncident {
        RadarIncident(id: UUID(), signature: signature, familyName: signature.displayName, level: .hot, maxScore: 80,
                      memoryBytes: 1, cpuPercent: 0, leakVelocityMegabytesPerMinute: 0, reasons: [],
                      startedAt: lastSeen, lastSeenAt: lastSeen, resolvedAt: lastSeen, occurrenceCount: hits)
    }

    private func family(
        level: GhostLevel,
        name: String = "node",
        alert: AlertStateKind = .normal,
        memory: UInt64? = nil,
        cpu: Double = 0,
        trend: TrendMetrics = .empty,
        longTerm: LongTermTrend = .none,
        at date: Date
    ) -> ProcessFamily {
        let identity = ProcessIdentity(pid: 731, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let footprint = memory ?? (level >= .hot ? 3_000_000_000 : 40_000_000)
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: name,
                                  executablePath: "/usr/local/bin/\(name)", commandLine: "\(name) server.js",
                                  residentMemoryBytes: footprint, physicalFootprintBytes: footprint,
                                  virtualMemoryBytes: footprint * 2, cpuPercent: cpu, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        let value: Double = switch level {
        case .critical: 95
        case .hot: 80
        default: 20
        }
        let score = GhostScore(value: value, level: level, reasons: level >= .hot ? ["memory"] : [])
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: footprint,
                             totalPhysicalFootprintBytes: footprint, totalCPUPercent: cpu,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: trend,
                             score: score, ownedIdentities: [identity], protectedPIDs: [],
                             alertState: AlertState(kind: alert, message: alert.rawValue, since: date),
                             lastScoredAt: date, longTermTrend: longTerm)
    }
}
