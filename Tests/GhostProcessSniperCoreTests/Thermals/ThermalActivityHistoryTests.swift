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
            processorCount: 10, coverage: .processInventory), at: later)
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

    private func activity(cpu: Double, at date: Date) -> ThermalActivitySummary {
        let sample = ThermalActivitySample(
            identity: ProcessIdentity(pid: 42, startTimeSeconds: 2_000_099_000, startTimeMicroseconds: 0),
            familyKey: "editor", name: "Editor",
            executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
            cpuPercent: cpu, gpuPercent: 0, measuredAt: date)
        return ThermalActivitySummary.build(samples: [sample], now: date,
                                            processorCount: 10, coverage: .processInventory)
    }

    private func snapshot(_ temperature: Double, at date: Date) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date, cpuCelsius: temperature, gpuCelsius: nil,
                        sensorCount: 1, sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
    }
}
