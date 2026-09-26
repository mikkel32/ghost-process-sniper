import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalStopTargetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_200_000)

    func testRepeatedUserJobWhileHotOffersTheStopShortcut() throws {
        let (insight, diagnosis) = evaluate(temperature: 85)
        let contributor = try XCTUnwrap(insight.stopCandidate(diagnosis: diagnosis))
        XCTAssertEqual(insight.evidenceStrength, .repeated)
        let target = try XCTUnwrap(ThermalStopTarget.resolve(for: contributor, family: family(named: "Compiler"), ownPID: 1))
        XCTAssertEqual(target.title, "Stop Compiler…")
        XCTAssertEqual(target.familyKey, family(named: "Compiler").familyKey)
    }

    func testCoolMacOrSingleReadingKeepsInspectOnly() {
        let cool = evaluate(temperature: 55)
        XCTAssertNil(cool.insight.stopCandidate(diagnosis: cool.diagnosis))
        let single = evaluate(temperature: 85, readings: 1)
        XCTAssertEqual(single.insight.evidenceStrength, .singleSample)
        XCTAssertNil(single.insight.stopCandidate(diagnosis: single.diagnosis))
    }

    func testSystemAndKnownSourcesNeverYieldTheShortcut() {
        let system = evaluate(temperature: 85, system: true)
        XCTAssertNil(system.insight.stopCandidate(diagnosis: system.diagnosis))
        let known = contributor(kind: .knownSource(.virtualMachine))
        XCTAssertNil(ThermalStopTarget.resolve(for: known, family: family(named: "Compiler"), ownPID: 1))
        let service = contributor(isSystemProcess: true)
        XCTAssertNil(ThermalStopTarget.resolve(for: service, family: family(named: "Compiler"), ownPID: 1))
    }

    func testTitleNamesTheFamilyThePreviewWillStop() throws {
        let xcode = contributor(name: "Xcode", familyKey: family(named: "SourceKitService").familyKey)
        let target = try XCTUnwrap(ThermalStopTarget.resolve(for: xcode, family: family(named: "SourceKitService"), ownPID: 1))
        XCTAssertEqual(target.title, "Stop SourceKitService (Xcode)…")
    }

    func testShortcutFollowsTheFamilysQuickStop() throws {
        let plain = try XCTUnwrap(ThermalStopTarget.resolve(for: contributor(), family: family(named: "Compiler"), ownPID: 1))
        XCTAssertEqual(plain.action.targetFamilyKey, family(named: "Compiler").familyKey)
        XCTAssertNotEqual(plain.action.emphasis, .recommended, "not red unless the radar recommends the stop")

        let app = KillRiskAssessment(kind: .editor, risks: [], supervisor: nil, appQuitPID: 700, graceSeconds: nil,
                                     forceNeedsConfirmation: false, freedPorts: [], headline: nil,
                                     shutsDownThroughRoot: false, rootShutdownSignal: nil)
        let quit = try XCTUnwrap(ThermalStopTarget.resolve(for: contributor(), family: family(named: "Compiler"), risk: app, ownPID: 1))
        XCTAssertEqual(quit.title, "Quit Compiler…")
        XCTAssertEqual(quit.action.systemImage, "xmark.app")
    }

    func testMissingProtectedOrOwnFamilyGetsNoShortcut() {
        XCTAssertNil(ThermalStopTarget.resolve(for: contributor(), family: nil, ownPID: 1))
        XCTAssertNil(ThermalStopTarget.resolve(for: contributor(), family: family(named: "Compiler", owned: false), ownPID: 1))
        XCTAssertNil(ThermalStopTarget.resolve(for: contributor(), family: family(named: "Compiler"), ownPID: 700))
        XCTAssertNil(ThermalStopTarget.resolve(for: contributor(canInspect: false), family: family(named: "Compiler"), ownPID: 1))
        let other = contributor(familyKey: "someone-else")
        XCTAssertNil(ThermalStopTarget.resolve(for: other, family: family(named: "Compiler"), ownPID: 1))
    }

    private func evaluate(temperature: Double, readings: Int = 4,
                          system: Bool = false) -> (insight: ThermalAppInsight, diagnosis: ThermalDiagnosis) {
        var history = ThermalActivityHistory()
        var current = ThermalActivitySummary.empty
        var date = start
        for index in 0..<readings {
            date = start.addingTimeInterval(Double(index) * 10)
            let sample = ThermalActivitySample(
                identity: ProcessIdentity(pid: 700, startTimeSeconds: 2_000_199_000, startTimeMicroseconds: 0),
                familyKey: family(named: "Compiler").familyKey, name: "Compiler",
                executablePath: system ? "/System/Library/Compiler" : "/usr/local/bin/Compiler",
                cpuPercent: 400, gpuPercent: 0, measuredAt: date, isSystemProcess: system)
            current = history.record(ThermalActivitySummary.build(samples: [sample], now: date, processorCount: 10), at: date)
        }
        let snapshot = ThermalSnapshot(sampledAt: date, cpuCelsius: temperature, gpuCelsius: nil, sensorCount: 1,
                                       sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot, activity: current, at: date)
        return (ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis, at: date), diagnosis)
    }

    private func contributor(name: String = "Compiler", familyKey: String? = nil, canInspect: Bool = true,
                             isSystemProcess: Bool = false, kind: ThermalWorkloadKind = .job) -> ThermalContributor {
        ThermalContributor(id: "job:\(name)", displayName: name,
            familyKey: familyKey ?? family(named: "Compiler").familyKey,
            cpuPercent: 400, gpuPercent: 0, processCount: 1, measuredAt: start, applicationPath: nil,
            canInspectFamily: canInspect, isSystemProcess: isSystemProcess, cpuCapacityPercent: 40,
            cpuMeasuredAt: start, gpuMeasuredAt: nil, cpuMeasuredProcessCount: 1, gpuMeasuredProcessCount: 0,
            processes: [], kind: kind, hostAppName: nil)
    }

    private func family(named name: String, owned: Bool = true) -> ProcessFamily {
        let root = ProcessMetrics(
            identity: ProcessIdentity(pid: 700, startTimeSeconds: 2_000_199_000, startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "dev", name: name, executablePath: "/usr/local/bin/\(name)",
            commandLine: name, residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1,
            cpuPercent: 400, totalProcessorSeconds: 1, threadCount: 1, isSystemProcess: false, sampledAt: start)
        let family = RefreshPerformanceFixture.family(root)
        guard !owned else { return family }
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: 1, totalPhysicalFootprintBytes: 1,
            totalCPUPercent: 400, devConfidence: 0, commandHints: [], trend: .empty, score: family.score,
            ownedIdentities: [], protectedPIDs: [700])
    }
}
