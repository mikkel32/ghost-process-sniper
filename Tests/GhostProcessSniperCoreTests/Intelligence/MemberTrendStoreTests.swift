import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class MemberTrendStoreTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private func member(
        _ pid: Int32,
        parent: Int32 = 1,
        name: String = "node",
        path: String = "/usr/local/bin/node",
        command: String = "node /Users/dev/web/node_modules/.bin/vite",
        megabytes: Double,
        cpu: Double = 1,
        at date: Date,
        status: ProcessMeasurementStatus = .fresh
    ) -> ProcessMetrics {
        Fixture.process(pid: pid, parent: parent, name: name, path: path, command: command, megabytes: megabytes,
                        cpu: cpu, started: Date(timeIntervalSince1970: 1_000), date: date, status: status)
    }

    /// Runs `ticks` ticks `cadence` apart ending at the fixture clock.
    private func run(
        ticks: Int,
        cadence: TimeInterval,
        world: (Int, Date) -> [ProcessMetrics],
        inspect: (Int, Date, [ProcessFamily]) -> Void = { _, _, _ in }
    ) -> [ProcessFamily] {
        var pipeline = RadarPipeline(
            builder: ProcessFamilyBuilder(currentUserID: 501, processorCount: 8),
            intelligence: RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8, physicalMemoryBytes: 16 << 30))
        )
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        let start = Fixture.now.addingTimeInterval(-Double(ticks - 1) * cadence)
        var families: [ProcessFamily] = []
        for tick in 0..<ticks {
            let date = start.addingTimeInterval(Double(tick) * cadence)
            families = pipeline.run(processes: world(tick, date), settings: .smart, context: context, now: date).families
            inspect(tick, date, families)
        }
        return families
    }

    func testTransientChildrenDoNotBreakTheSeries() throws {
        let families = run(ticks: 60, cadence: 3) { tick, date in
            var world = [self.member(100, megabytes: 400 + Double(tick) * 0.5, at: date)]
            if tick % 3 == 0 {
                world.append(self.member(Int32(10_000 + tick), parent: 100, name: "git", path: "/usr/bin/git",
                                         command: "git status", megabytes: 30, at: date))
            }
            return world
        }
        let vite = try XCTUnwrap(families.first { $0.root.pid == 100 })
        XCTAssertGreaterThanOrEqual(vite.trend.sampleCount, 55)
        XCTAssertEqual(vite.trend.memoryVelocityMegabytesPerMinute, 10, accuracy: 1)
    }

    func testANewLargeMemberIsNotGrowth() throws {
        var velocities: [Double] = []
        _ = run(ticks: 40, cadence: 3, world: { tick, date in
            var world = [self.member(200, megabytes: 250, at: date)]
            if tick >= 20 {
                world.append(self.member(201, parent: 200, name: "worker", path: "/usr/local/bin/worker",
                                         command: "worker", megabytes: 300, at: date))
            }
            return world
        }, inspect: { _, _, families in
            if let family = families.first { velocities.append(family.trend.memoryVelocityMegabytesPerMinute) }
        })
        XCTAssertLessThan(velocities.map(abs).max() ?? 0, 1)
    }

    /// A family out of the candidates for two and a half minutes still has
    /// samples in the trend window; a member that joined meanwhile must not
    /// read as growth when it returns.
    func testAFamilyReturningWithinTheTrendWindowKeepsItsChain() {
        var velocities: [Double] = []
        _ = run(ticks: 86, cadence: 3, world: { tick, date in
            var world = [self.member(300, name: "ruby", path: "/usr/bin/ruby", command: "ruby app.rb", megabytes: 200, at: date)]
            if tick < 20 || tick >= 70 {
                world.append(self.member(200, megabytes: 250, at: date))
            }
            if tick >= 70 {
                world.append(self.member(201, parent: 200, name: "worker", path: "/usr/local/bin/worker",
                                         command: "worker", megabytes: 300, at: date))
            }
            return world
        }, inspect: { tick, _, families in
            if tick >= 70, let family = families.first(where: { $0.root.pid == 200 }) {
                velocities.append(family.trend.memoryVelocityMegabytesPerMinute)
            }
        })
        XCTAssertFalse(velocities.isEmpty)
        XCTAssertLessThan(velocities.map(abs).max() ?? 0, 1)
    }

    func testSlowLeakUnderJitterIsFoundWithinTwentyFiveMinutes() throws {
        var jitter = Fixture.Jitter(seed: 11)
        var leakingAt: Int?
        let cadence = 3.5
        let ticks = Int(60 * 60 / cadence)
        let families = run(ticks: ticks, cadence: cadence, world: { tick, date in
            let minutes = Double(tick) * cadence / 60
            return [self.member(300, megabytes: 500 + 8 * minutes + jitter.next(amplitude: 5), at: date)]
        }, inspect: { tick, _, families in
            if leakingAt == nil, families.first?.forecast.state == .leaking {
                leakingAt = tick
            }
        })
        let family = try XCTUnwrap(families.first)
        XCTAssertEqual(family.longTermTrend.slopeMegabytesPerMinute, 8, accuracy: 1)
        let minutes = try XCTUnwrap(leakingAt).advanced(by: 0)
        XCTAssertLessThanOrEqual(Double(minutes) * cadence / 60, 25)
        XCTAssertTrue(family.forecastIsCredibleEscalation)
        XCTAssertTrue(family.forecast.whyNow.contains("crept up"), family.forecast.whyNow)
    }

    func testGarbageCollectedSawtoothIsNotALeak() {
        var leaked = false
        let cadence = 3.5
        _ = run(ticks: Int(60 * 60 / cadence), cadence: cadence, world: { tick, date in
            // Climbs 200 MB over 140 s, then collects back to the same floor.
            [self.member(400, megabytes: 300 + Double(tick % 40) * 5, at: date)]
        }, inspect: { _, _, families in
            if families.first?.forecast.state == .leaking { leaked = true }
        })
        XCTAssertFalse(leaked)
    }

    func testGrowingHelperIsNamedAsTheCulprit() throws {
        let app = "/Applications/Visual Studio Code.app/Contents"
        let families = run(ticks: Int(12 * 60 / 3), cadence: 3) { tick, date in
            let minutes = Double(tick) * 3 / 60
            return [
                self.member(500, name: "Electron", path: "\(app)/MacOS/Electron", command: "\(app)/MacOS/Electron", megabytes: 400, at: date),
                self.member(501, parent: 500, name: "Code Helper (Renderer)",
                            path: "\(app)/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)",
                            command: "Code Helper (Renderer) --type=renderer", megabytes: 300 + 40 * minutes, at: date),
                self.member(502, parent: 500, name: "Code Helper (Plugin)",
                            path: "\(app)/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                            command: "Code Helper (Plugin) --type=utility", megabytes: 250, at: date),
            ]
        }
        let editor = try XCTUnwrap(families.first { $0.root.pid == 500 })
        let culprit = try XCTUnwrap(editor.culprit)
        XCTAssertEqual(culprit.identity.pid, 501)
        XCTAssertGreaterThanOrEqual(culprit.share, 0.9)
        XCTAssertEqual(culprit.slopeMegabytesPerMinute, 40, accuracy: 4)
    }

    func testCachedReadingsAddNoSamples() throws {
        let measuredAt = Fixture.now.addingTimeInterval(-600)
        let families = run(ticks: 10, cadence: 3) { _, date in
            [self.member(600, megabytes: 300, at: date, status: .cached(measuredAt))]
        }
        XCTAssertEqual(families.first?.trend.sampleCount, 1)
    }

    func testSixHundredProcessesStayInsideTheMemoryCapAndBudget() {
        // Debug builds run a smaller, coarser world to keep the suite quick;
        // both fill the ninety-minute ring, so memory is at steady state.
        #if DEBUG
        let (familyCount, ticks, cadence) = (30, 100, 60.0)
        #else
        let (familyCount, ticks, cadence) = (150, 1_200, 5.0)
        #endif
        var store = MemberTrendStore()
        let families = (0..<familyCount).map { family in (0..<4).map { Int32(20_000 + family * 4 + $0) } }
        let start = Date(timeIntervalSince1970: 1_000_000)
        var elapsed: UInt64 = 0
        for tick in 0..<ticks {
            let date = start.addingTimeInterval(Double(tick) * cadence)
            let world = families.enumerated().map { index, pids in
                pids.map { self.member($0, megabytes: 100 + Double(tick % 50) + Double(index), at: date) }
            }
            let began = DispatchTime.now().uptimeNanoseconds
            for (index, members) in world.enumerated() {
                _ = store.advance(familyKey: "family-\(index)", members: members, now: date)
            }
            elapsed += DispatchTime.now().uptimeNanoseconds - began
        }
        XCTAssertEqual(store.seriesCount, familyCount * 4)
        // At the series cap, the store stays within 4 MB.
        XCTAssertLessThanOrEqual(store.estimatedBytes / store.seriesCount * MemberTrendStore.seriesCap, 4 << 20)
        let perTick = Double(elapsed) / Double(ticks) / 1_000_000
        print("member trend store \(perTick) ms per tick, \(store.estimatedBytes) bytes for \(store.seriesCount) series")
        #if !DEBUG
        XCTAssertLessThanOrEqual(perTick, 5)
        #endif

        // New identities beyond the cap get no series.
        let later = start.addingTimeInterval(Double(ticks) * cadence)
        for pid in 0..<Int32(1_300) {
            _ = store.advance(familyKey: "overflow", members: [member(30_000 + pid, megabytes: 10, at: later)], now: later)
        }
        XCTAssertLessThanOrEqual(store.seriesCount, MemberTrendStore.seriesCap)
    }
}
