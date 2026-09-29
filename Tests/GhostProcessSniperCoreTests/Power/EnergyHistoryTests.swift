import XCTest
@testable import GhostProcessSniperCore

final class EnergyHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("energy-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return calendar
    }()

    private func assignment(_ name: String, app: String? = nil) -> EnergyGroupAssignment {
        EnergyGroupAssignment(key: app ?? "job:\(name):\(UUID().uuidString)", displayName: name,
                              kind: app == nil ? .job : .app, applicationPath: app, hostAppName: nil)
    }

    private func charge(_ joules: Double) -> EnergyMinute {
        var minute = EnergyMinute(start: .distantPast)
        minute.joules = joules
        return minute
    }

    func testDayKeysAndJobKeysRepeatAcrossRuns() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(EnergyHistory.dayKey(for: date, calendar: calendar), "2026-03-07")
        XCTAssertEqual(EnergyHistory.key(for: assignment("vite")), "name:vite", "two runs of vite are one row")
        XCTAssertEqual(EnergyHistory.key(for: assignment("Safari", app: "/Applications/Safari.app")),
                       "/Applications/Safari.app")
    }

    func testTodayAccumulatesRollsOverAndWritesEveryFiveMinutes() {
        var tracker = EnergyHistoryTracker()
        let morning = Date(timeIntervalSince1970: 1_790_000_000)
        tracker.record([(assignment("vite"), charge(360)), (assignment("vite"), charge(360))], now: morning)
        XCTAssertNil(tracker.takeFlush(now: morning), "nothing is written before the stored day is loaded")
        tracker.load([EnergyDayUsage(day: EnergyHistory.dayKey(for: morning), usage: EnergyUsage(
            key: "name:vite", displayName: "vite", applicationPath: nil, joules: 3_600))], now: morning)
        let summary = tracker.summary(fullChargeWattHours: 50, now: morning)
        XCTAssertEqual(summary.entries.first?.wattHours ?? 0, 1.2, accuracy: 1e-9, "stored 1 Wh plus 0.2 Wh measured")
        XCTAssertEqual(summary.shareOfFullCharge ?? 0, 1.2 / 50, accuracy: 1e-9)

        XCTAssertNil(tracker.takeFlush(now: morning), "the first write waits five minutes")
        let batches = tracker.takeFlush(now: morning.addingTimeInterval(301))
        XCTAssertEqual(batches?.count, 1)
        XCTAssertEqual(batches?.first?.usages.first?.joules ?? 0, 720, accuracy: 1e-9, "only what was not stored yet")
        XCTAssertNil(tracker.takeFlush(now: morning.addingTimeInterval(302)))

        let tomorrow = morning.addingTimeInterval(86_400)
        tracker.record([(assignment("Xcode", app: "/Applications/Xcode.app"), charge(7_200))], now: tomorrow)
        let next = tracker.summary(fullChargeWattHours: nil, now: tomorrow)
        XCTAssertEqual(next.entries.map(\.displayName), ["Xcode"])
        XCTAssertEqual(next.days.map(\.wattHours), [1.2, 2], "yesterday's total, then today's")
    }

    func testAFailedWriteIsRetriedWithNothingLost() {
        var tracker = EnergyHistoryTracker()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        tracker.load([], now: now)
        tracker.record([(assignment("job"), charge(100))], now: now)
        let batches = tracker.takeFlush(now: now, force: true) ?? []
        tracker.restore(batches)
        tracker.record([(assignment("job"), charge(50))], now: now)
        XCTAssertEqual(tracker.takeFlush(now: now, force: true)?.first?.usages.first?.joules, 150)
    }

    func testTheStoreAddsToEachDaysRowsAndPrunesOldDays() async throws {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        let now = Date()
        let today = EnergyHistory.dayKey(for: now)
        let old = EnergyHistory.dayKey(for: now.addingTimeInterval(-40 * 86_400))
        let usage = EnergyUsage(key: "/Applications/Safari.app", displayName: "Safari",
                                applicationPath: "/Applications/Safari.app", joules: 1_000, wakeups: 10)
        try await store.recordEnergy([usage], day: today, now: now)
        try await store.recordEnergy([usage], day: today, now: now)
        try await store.recordEnergy([usage], day: old, now: now)
        let rows = try await store.energyHistory(days: 7, now: now)
        XCTAssertEqual(rows.count, 1, "the 40-day-old row is outside the window")
        XCTAssertEqual(rows.first?.usage.joules, 2_000)
        XCTAssertEqual(rows.first?.usage.wakeups, 20)
        XCTAssertEqual(rows.first?.usage.applicationPath, "/Applications/Safari.app")

        try await store.pruneIfNeeded(now: now)
        let all = try await store.energyHistory(days: 60, now: now)
        XCTAssertEqual(all.map(\.day), [today], "days older than five weeks are pruned")
        await store.close()
    }

    func testTheWorkerCarriesTodayAcrossARestart() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let now = Date()
        let first = RadarRefreshWorker(store: RadarStore(url: url), battery: nil, sleepAssertions: nil)
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index) * 5)
            _ = await first.ingest(batch: ProcessSampleBatch(processes: [
                EnergyFixture.process(pid: 42, name: "render", path: "/usr/local/bin/render",
                                      counters: .init(joules: 1_800 * Double(index)), at: date)
            ], sampledAt: date, stats: .empty), request: .fixture(at: date))
        }
        await first.syncEnergyHistory(now: now.addingTimeInterval(15), force: true)

        let second = RadarRefreshWorker(store: RadarStore(url: url), battery: nil, sleepAssertions: nil)
        let date = now.addingTimeInterval(20)
        let outcome = await second.ingest(batch: ProcessSampleBatch(processes: [
            EnergyFixture.process(pid: 42, name: "render", path: "/usr/local/bin/render",
                                  counters: .init(joules: 9_000), at: date)
        ], sampledAt: date, stats: .empty), request: .fixture(at: date))
        _ = outcome
        let reloaded = await second.ingest(batch: ProcessSampleBatch(processes: [
            EnergyFixture.process(pid: 42, name: "render", path: "/usr/local/bin/render",
                                  counters: .init(joules: 9_000), at: date.addingTimeInterval(5))
        ], sampledAt: date.addingTimeInterval(5), stats: .empty), request: .fixture(at: date.addingTimeInterval(5)))
        XCTAssertEqual(reloaded.energy.today.entries.first?.displayName, "render")
        XCTAssertEqual(reloaded.energy.today.wattHours, 1, accuracy: 1e-9, "3,600 J from before the restart")
    }
}

extension RefreshRequest {
    static func fixture(at date: Date) -> RefreshRequest {
        RefreshRequest(settings: .smart, currentFamilies: [], currentIncidents: [], currentStoreHealth: .empty,
                       previousConsoleSnapshot: nil, uiVisible: false, focusedSignatureIDs: [],
                       portCensusRequested: false, hitchReport: .empty, lastPublishMilliseconds: 0,
                       coalescedRefreshCount: 0, now: date, startedAt: date)
    }
}
