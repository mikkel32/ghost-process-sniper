import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalAppInsightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testWarmBusyAppIsNamedWithWorkloadEvidence() {
        let result = insight(activity: activity(cpu: 200), temperature: 85)
        XCTAssertEqual(result.kind, .active)
        XCTAssertEqual(result.title, "Start with Editor")
        XCTAssertEqual(result.badge, "Current workload observed")
        XCTAssertTrue(result.evidence.contains("CPU capacity"))
    }

    func testCoolActiveAppDoesNotReceiveAnOverheatingWarning() {
        let result = insight(activity: activity(cpu: 200), temperature: 60)
        XCTAssertEqual(result.title, "Most active: Editor")
        // The badge describes evidence strength; only the title depends on temperature.
        XCTAssertEqual(result.badge, "Current workload observed")
    }

    func testOneBusyCoreRemainsSignificantOnManyCoreMac() {
        let result = insight(activity: activity(cpu: 100, processors: 32), temperature: 82)
        XCTAssertEqual(result.kind, .active)
        XCTAssertTrue(result.title.contains("Editor"))
    }

    func testModestLeaderIsNotBlamedForHeat() {
        let result = insight(activity: activity(cpu: 20), temperature: 85)
        XCTAssertEqual(result.kind, .modest)
        XCTAssertEqual(result.badge, "Light workload observed")
        XCTAssertTrue(result.title.contains("Editor"))
    }

    func testModestGPURankDoesNotConcealABusyCPUApp() {
        let samples = [
            ThermalActivitySample(identity: ProcessIdentity(pid: 1, startTimeSeconds: 1,
                startTimeMicroseconds: 0), familyKey: "browser", name: "Browser",
                executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                cpuPercent: 2, gpuPercent: 13, measuredAt: now, gpuMeasuredAt: now),
            ThermalActivitySample(identity: ProcessIdentity(pid: 2, startTimeSeconds: 1,
                startTimeMicroseconds: 0), familyKey: "compiler", name: "Compiler",
                executablePath: "/Applications/Compiler.app/Contents/MacOS/Compiler",
                cpuPercent: 100, gpuPercent: 0, measuredAt: now)
        ]
        let measured = ThermalActivitySummary.build(samples: samples, now: now, processorCount: 10)
        XCTAssertEqual(measured.visibleContributors(at: now).first?.displayName, "Browser")
        let result = insight(activity: measured, temperature: 85)
        XCTAssertEqual(result.kind, .active)
        XCTAssertEqual(result.contributor?.displayName, "Compiler")
    }

    func testMissingAndQuietEvidenceStayDifferent() {
        let quiet = insight(activity: activity(cpu: 0), temperature: 85)
        XCTAssertEqual(quiet.kind, .unexplained)
        XCTAssertEqual(quiet.title, "No clear app contributor yet")
        let expired = insight(activity: activity(cpu: 300, at: now.addingTimeInterval(-20)), temperature: 85)
        XCTAssertEqual(expired.kind, .checking)
        XCTAssertNil(expired.contributor)
    }

    func testExpiredCPUDoesNotStayAHeatSuspectWhileGPUReadingIsFresh() {
        let sample = ThermalActivitySample(identity: ProcessIdentity(pid: 88, startTimeSeconds: 1,
            startTimeMicroseconds: 0), familyKey: "editor", name: "Editor",
            executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
            cpuPercent: 150, gpuPercent: 5, measuredAt: now.addingTimeInterval(-11),
            gpuMeasuredAt: now)
        let activity = ThermalActivitySummary.build(samples: [sample], now: now, processorCount: 10)
        let later = now.addingTimeInterval(2)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(85, at: later), activity: activity, at: later)
        let result = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: later)
        XCTAssertEqual(result.kind, .modest)
        XCTAssertTrue(result.evidence.contains("CPU activity is unmeasured"))
        XCTAssertFalse(result.evidence.contains("15% of total CPU capacity"))
    }

    func testSystemServiceKeepsSystemSpecificAdvice() {
        let result = insight(activity: activity(cpu: 300, system: true), temperature: 85)
        XCTAssertTrue(result.action.contains("does not recommend stopping"))
    }

    func testCompareDoesNotCreateNewEvidenceFromTimerTicks() throws {
        let baseline = try XCTUnwrap(activity(cpu: 200).contributors.first)
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: snapshot(85), at: now)
        let result = check.evaluate(activity: activity(cpu: 200), snapshot: snapshot(85), at: now.addingTimeInterval(20))
        XCTAssertTrue(result.title.contains("Baseline saved"))
        XCTAssertFalse(result.detail.contains("temperature: down"))
    }

    func testCompareUsesNewMeasuredLoadAndSameSensorDeltas() throws {
        let baseline = try XCTUnwrap(activity(cpu: 200).contributors.first)
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: snapshot(85), at: now)
        let later = now.addingTimeInterval(20)
        let result = check.evaluate(activity: activity(cpu: 50, at: later), snapshot: snapshot(80, at: later), at: later)
        XCTAssertTrue(result.title.contains("Reading comparison"))
        XCTAssertTrue(result.detail.contains("CPU temperature: down"))
        XCTAssertTrue(result.detail.contains("App CPU capacity"))
        XCTAssertTrue(result.note.contains("not proof of causation"))
    }

    func testMissingAppIsNotZeroLoadInComparison() throws {
        let baseline = try XCTUnwrap(activity(cpu: 200).contributors.first)
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: snapshot(85), at: now)
        let later = now.addingTimeInterval(20)
        let result = check.evaluate(activity: .empty, snapshot: snapshot(80, at: later), at: later)
        XCTAssertEqual(result.title, "Waiting for new app readings")
        XCTAssertTrue(result.detail.contains("not treated as zero"))
    }

    func testComparisonExpiresAndRejectsFutureClock() throws {
        let baseline = try XCTUnwrap(activity(cpu: 200).contributors.first)
        let check = ThermalCoolingCheck(contributor: baseline, snapshot: snapshot(85), at: now)
        for date in [now.addingTimeInterval(181), now.addingTimeInterval(-1)] {
            XCTAssertEqual(check.evaluate(activity: activity(cpu: 100, at: date),
                snapshot: snapshot(70, at: date), at: date).title, "Comparison expired")
        }
    }

    private func insight(activity: ThermalActivitySummary, temperature: Double) -> ThermalAppInsight {
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(temperature), activity: activity, at: now)
        return .evaluate(activity: activity, diagnosis: diagnosis, at: now)
    }

    private func snapshot(_ temperature: Double, at date: Date? = nil) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date ?? now, cpuCelsius: temperature, gpuCelsius: temperature - 2,
            sensorCount: 2, sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
    }

    private func activity(cpu: Double, processors: Int = 10, at date: Date? = nil,
                          system: Bool = false) -> ThermalActivitySummary {
        let sampledAt = date ?? now
        let sample = ThermalActivitySample(identity: ProcessIdentity(pid: 123, startTimeSeconds: 1_999_000_000,
            startTimeMicroseconds: 0), familyKey: "editor", name: "Editor",
            executablePath: system ? "/System/Library/Service" : "/Applications/Editor.app/Contents/MacOS/Editor",
            cpuPercent: cpu, gpuPercent: 0, measuredAt: sampledAt, isSystemProcess: system)
        return ThermalActivitySummary.build(samples: [sample], now: sampledAt, processorCount: processors)
    }
}
