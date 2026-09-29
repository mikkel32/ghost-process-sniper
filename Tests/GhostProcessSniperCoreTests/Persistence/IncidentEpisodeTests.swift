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

    func testRecurrenceSortRanksReopenedEpisodeAboveSingleHits() {
        let signature = ProcessSignature(id: "a", displayName: "a", canonicalPath: "/a", commandFingerprint: "a")
        let other = ProcessSignature(id: "b", displayName: "b", canonicalPath: "/b", commandFingerprint: "b")
        let reopened = incident(signature: signature, hits: 4, lastSeen: at(0))
        let splitA = incident(signature: other, hits: 1, lastSeen: at(10))
        let splitB = incident(signature: other, hits: 1, lastSeen: at(20))
        let sorted = IncidentQuery(sort: .recurrence).apply(to: [splitA, splitB, reopened])
        XCTAssertEqual(sorted.first?.id, reopened.id, "four hits in one episode outrank two single-hit rows")
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
        alert: AlertStateKind = .normal,
        memory: UInt64? = nil,
        at date: Date
    ) -> ProcessFamily {
        let identity = ProcessIdentity(pid: 731, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let footprint = memory ?? (level >= .hot ? 3_000_000_000 : 40_000_000)
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: "node",
                                  executablePath: "/usr/local/bin/node", commandLine: "node server.js",
                                  residentMemoryBytes: footprint, physicalFootprintBytes: footprint,
                                  virtualMemoryBytes: footprint * 2, cpuPercent: 0, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: date)
        let value: Double = switch level {
        case .critical: 95
        case .hot: 80
        default: 20
        }
        let score = GhostScore(value: value, level: level, reasons: level >= .hot ? ["memory"] : [])
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: footprint,
                             totalPhysicalFootprintBytes: footprint, totalCPUPercent: 0,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: score, ownedIdentities: [identity], protectedPIDs: [],
                             alertState: AlertState(kind: alert, message: alert.rawValue, since: date),
                             lastScoredAt: date)
    }
}
