import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalActivityHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_100_000)

    func testRecentWorkRemainsVisibleWhenCurrentLoadIsQuiet() {
        var history = ThermalActivityHistory()
        _ = history.record(activity(cpu: 120, at: start), at: start)
        let later = start.addingTimeInterval(30)
        let current = history.record(activity(cpu: 0, at: later), at: later)

        XCTAssertTrue(current.contributors.isEmpty)
        XCTAssertEqual(current.historySampleCount, 2)
        XCTAssertEqual(current.historySpanSeconds, 30)
        XCTAssertEqual(current.recentContributors.first?.displayName, "Editor")
        XCTAssertEqual(current.recentContributors.first?.lastActiveAt, start)

        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(84, at: later), activity: current, at: later)
        let insight = ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis, at: later)
        XCTAssertEqual(insight.kind, .recent)
        XCTAssertEqual(insight.evidenceStrength, .singleSample)
        XCTAssertTrue(insight.evidence.contains("30s ago"))
        XCTAssertTrue(insight.badge.contains("unconfirmed"))
    }

    func testRepeatedSamplesIncreaseEvidenceWithoutCountingTimerTicks() {
        var history = ThermalActivityHistory()
        for offset in [0.0, 10.0, 25.0] {
            let date = start.addingTimeInterval(offset)
            _ = history.record(activity(cpu: 120, at: date), at: date)
        }
        let current = history.record(activity(cpu: 120, at: start.addingTimeInterval(25)),
                                     at: start.addingTimeInterval(25))
        XCTAssertEqual(current.historySampleCount, 3)
        XCTAssertEqual(current.recentContributors.first?.activeSampleCount, 3)
        XCTAssertEqual(current.recentContributors.first?.activeSpanSeconds, 25)

        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(84, at: current.sampledAt),
                                                  activity: current, at: current.sampledAt)
        XCTAssertEqual(ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis,
                                                  at: current.sampledAt).evidenceStrength, .repeated)
    }

    func testRecentWorkExpiresAfterThreeMinutes() {
        var history = ThermalActivityHistory()
        _ = history.record(activity(cpu: 120, at: start), at: start)
        let later = start.addingTimeInterval(181)
        let current = history.record(activity(cpu: 0, at: later), at: later)
        XCTAssertTrue(current.recentContributors.isEmpty)
        XCTAssertEqual(current.historySampleCount, 1)
    }

    func testCurrentSubstantialAppOutranksDifferentRecentlyBusyApp() {
        var history = ThermalActivityHistory()
        _ = history.record(activity(cpu: 120, at: start), at: start)
        let later = start.addingTimeInterval(30)
        let browser = ThermalActivitySample(
            identity: ProcessIdentity(pid: 99, startTimeSeconds: 2_000_099_000, startTimeMicroseconds: 0),
            familyKey: "browser", name: "Browser",
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            cpuPercent: 100, gpuPercent: 0, measuredAt: later)
        let current = history.record(ThermalActivitySummary.build(samples: [browser], now: later,
            processorCount: 10), at: later)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(84, at: later), activity: current, at: later)
        let insight = ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis, at: later)
        XCTAssertEqual(insight.kind, .active)
        XCTAssertEqual(insight.contributor?.displayName, "Browser")
        XCTAssertTrue(current.recentContributors.contains { $0.displayName == "Editor" })
    }

    func testCoolingComparisonUsesNewQuietReading() throws {
        let baseline = try XCTUnwrap(activity(cpu: 120, at: start).contributors.first)
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: snapshot(84, at: start), at: start)
        let later = start.addingTimeInterval(25)
        let result = check.evaluate(activity: activity(cpu: 1, at: later),
                                    snapshot: snapshot(80, at: later), at: later)
        XCTAssertEqual(result.title, "Reading comparison: Editor")
        XCTAssertTrue(result.detail.contains("App CPU capacity"))
        XCTAssertTrue(result.detail.contains("CPU temperature: down"))
    }

    func testCoolingComparisonDoesNotCompareDifferentPhysicalSensors() throws {
        let baseline = try XCTUnwrap(activity(cpu: 120, at: start).contributors.first)
        let before = ThermalSnapshot(sampledAt: start, cpuCelsius: 84, gpuCelsius: nil,
            sensorCount: 2, sensorKeys: ["core-a", "core-b"], systemState: "Nominal",
            unavailableReason: nil, cpuSensorKey: "core-a")
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: before, at: start)
        let later = start.addingTimeInterval(25)
        let after = ThermalSnapshot(sampledAt: later, cpuCelsius: 80, gpuCelsius: nil,
            sensorCount: 2, sensorKeys: ["core-a", "core-b"], systemState: "Nominal",
            unavailableReason: nil, cpuSensorKey: "core-b")
        let result = check.evaluate(activity: activity(cpu: 1, at: later), snapshot: after, at: later)
        XCTAssertTrue(result.detail.contains("App CPU capacity"))
        XCTAssertFalse(result.detail.contains("CPU temperature:"))
    }

    func testCoolingCheckComparesSameSensorSetAcrossRotatingCores() throws {
        let baseline = try XCTUnwrap(activity(cpu: 120, at: start).contributors.first)
        let before = ThermalSnapshot(sampledAt: start, cpuCelsius: 84, gpuCelsius: nil,
            sensorCount: 2, sensorKeys: ["Tp01", "Tp05"], systemState: "Nominal",
            unavailableReason: nil, cpuSensorKey: "Tp01", cpuSeriesID: "cpu:Tp01,Tp05")
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: before, at: start)
        let later = start.addingTimeInterval(25)
        let after = ThermalSnapshot(sampledAt: later, cpuCelsius: 80, gpuCelsius: nil,
            sensorCount: 2, sensorKeys: ["Tp01", "Tp05"], systemState: "Nominal",
            unavailableReason: nil, cpuSensorKey: "Tp05", cpuSeriesID: "cpu:Tp01,Tp05")
        let result = check.evaluate(activity: activity(cpu: 1, at: later), snapshot: after, at: later)
        XCTAssertTrue(result.detail.contains("CPU temperature: down 4.0°C"))
    }

    func testSustainedCompileOutranksARecentSingleBlip() {
        var history = ThermalActivityHistory()
        for offset in stride(from: 0.0, through: 150, by: 3) {
            let date = start.addingTimeInterval(offset)
            _ = history.record(jobs([("Compiler", 80)], at: date), at: date)
        }
        let blip = start.addingTimeInterval(155)
        _ = history.record(jobs([("Chat", 12)], at: blip), at: blip)
        let later = start.addingTimeInterval(160)
        let current = history.record(jobs([], at: later), at: later)

        XCTAssertEqual(current.recentContributors.first?.displayName, "Compiler")
        let compile = try? XCTUnwrap(current.recentContributors.first)
        XCTAssertGreaterThan(compile?.sustainedLoadPercent ?? 0, 50)
        let chat = current.recentContributors.first { $0.displayName == "Chat" }
        XCTAssertLessThan(chat?.sustainedLoadPercent ?? 0, 1)
        XCTAssertEqual(current.earlierContributor(at: later)?.displayName, "Compiler")

        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(84, at: later), activity: current, at: later)
        let insight = ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis, at: later)
        XCTAssertEqual(insight.kind, .recent)
        XCTAssertEqual(insight.title, "Recently active: Compiler")
        XCTAssertEqual(insight.evidenceStrength, .repeated)
        XCTAssertTrue(insight.evidence.contains("of CPU capacity over the last 3 min (recent readings weigh more)"),
                      insight.evidence)
    }

    func testOneAndFiveSecondCadencesAgree() throws {
        func load(cadence: Double) throws -> Double {
            var history = ThermalActivityHistory()
            var current = ThermalActivitySummary.empty
            for offset in stride(from: 0.0, through: 160, by: cadence) {
                let date = start.addingTimeInterval(offset)
                current = history.record(jobs(offset <= 150 ? [("Compiler", 80)] : [], at: date), at: date)
            }
            return try XCTUnwrap(current.recentContributors.first?.sustainedLoad(at: start.addingTimeInterval(160)))
        }
        let fine = try load(cadence: 1)
        let coarse = try load(cadence: 5)
        XCTAssertEqual(fine, coarse, accuracy: fine * 0.05)
        XCTAssertEqual(fine, 80 * (1 - exp(-151.0 / 60)) * exp(-10.0 / 60), accuracy: 1)
    }

    func testASingleSampleCannotReachFullWeight() throws {
        var history = ThermalActivityHistory()
        _ = history.record(jobs([], at: start), at: start)
        let date = start.addingTimeInterval(3)
        let current = history.record(jobs([("Compiler", 90)], at: date), at: date)
        let load = try XCTUnwrap(current.recentContributors.first?.sustainedLoadPercent)
        XCTAssertGreaterThan(load, 0)
        XCTAssertLessThan(load, 9)
    }

    func testUnmeasuredGapDecaysOnlyByTime() throws {
        var history = ThermalActivityHistory()
        var current = ThermalActivitySummary.empty
        for offset in stride(from: 0.0, through: 60, by: 3) {
            let date = start.addingTimeInterval(offset)
            current = history.record(jobs([("Compiler", 80)], at: date), at: date)
        }
        let before = try XCTUnwrap(current.recentContributors.first?.sustainedLoadPercent)
        for offset in stride(from: 63.0, through: 90, by: 3) {
            let date = start.addingTimeInterval(offset)
            current = history.record(jobs([("Compiler", 80)], at: date, measured: false), at: date)
        }
        let after = try XCTUnwrap(current.recentContributors.first?.sustainedLoadPercent)
        XCTAssertEqual(after, before * exp(-30.0 / 60), accuracy: 0.001)
    }

    func testFreshHeavyJobOutranksADecayedOldOne() {
        var history = ThermalActivityHistory()
        var current = ThermalActivitySummary.empty
        for offset in stride(from: 0.0, through: 250, by: 3) {
            let date = start.addingTimeInterval(offset)
            var work: [(String, Double)] = []
            if offset <= 150 { work.append(("Old build", 80)) }
            if offset >= 230 { work.append(("Fresh build", 90)) }
            current = history.record(jobs(work, at: date), at: date)
        }
        XCTAssertEqual(current.recentContributors.map(\.displayName), ["Fresh build", "Old build"])
    }

    func testRepublishingTheSameSampleDoesNotCountTwice() throws {
        var history = ThermalActivityHistory()
        var once = history
        for offset in [0.0, 3, 6] {
            let date = start.addingTimeInterval(offset)
            _ = history.record(jobs([("Compiler", 80)], at: date), at: date)
            _ = once.record(jobs([("Compiler", 80)], at: date), at: date)
        }
        let date = start.addingTimeInterval(6)
        let replayed = history.record(jobs([("Compiler", 80)], at: date), at: date.addingTimeInterval(1))
        let single = once.record(jobs([], at: date.addingTimeInterval(3)), at: date.addingTimeInterval(3))
        XCTAssertEqual(try XCTUnwrap(replayed.recentContributors.first?.sustainedLoad(at: date.addingTimeInterval(3))),
                       try XCTUnwrap(single.recentContributors.first?.sustainedLoadPercent), accuracy: 0.0001)
    }

    private func jobs(_ work: [(String, Double)], at date: Date, measured: Bool = true) -> ThermalActivitySummary {
        let samples = work.enumerated().map { index, item in
            ThermalActivitySample(
                identity: ProcessIdentity(pid: Int32(300 + index), startTimeSeconds: 2_000_099_000, startTimeMicroseconds: 0),
                familyKey: item.0.lowercased(), name: item.0, executablePath: "/usr/bin/\(item.0)",
                cpuPercent: item.1 * 10, gpuPercent: 0, measuredAt: measured ? date : nil)
        }
        return ThermalActivitySummary.build(samples: samples, now: date, processorCount: 10)
    }

    private func activity(cpu: Double, at date: Date) -> ThermalActivitySummary {
        let sample = ThermalActivitySample(
            identity: ProcessIdentity(pid: 42, startTimeSeconds: 2_000_099_000, startTimeMicroseconds: 0),
            familyKey: "editor", name: "Editor",
            executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
            cpuPercent: cpu, gpuPercent: 0, measuredAt: date)
        return ThermalActivitySummary.build(samples: [sample], now: date,
                                            processorCount: 10)
    }

    private func snapshot(_ temperature: Double, at date: Date) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date, cpuCelsius: temperature, gpuCelsius: nil,
                        sensorCount: 1, sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
    }
}
