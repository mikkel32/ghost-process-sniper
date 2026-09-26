import Foundation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class ThermalDashboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testInventoryIncludesAppsWithNoMonitoredFamily() {
        let result = projection([process(1, cpu: 180)])
        XCTAssertEqual(result.coverage, .processInventory)
        XCTAssertEqual(result.observedProcessCount, 1)
        XCTAssertEqual(result.contributors.first?.displayName, "Example")
        XCTAssertEqual(result.contributors.first?.cpuCapacityPercent, 18)
        XCTAssertEqual(result.contributors.first?.canInspectFamily, false)
        XCTAssertEqual(result.contributors.first?.processes.first?.identity.pid, 1)
    }

    func testAllHelpersRemainVisibleWithoutFamilyMembership() {
        let result = projection([
            process(1, cpu: 100),
            process(2, cpu: 80, path: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        ])
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(result.contributors.first?.processCount, 2)
        XCTAssertEqual(result.contributors.first?.cpuPercent, 180)
        XCTAssertEqual(result.contributors.first?.processes.count, 2)
    }

    func testEvidenceIsBoundedButTotalsIncludeEverySampledHelper() {
        let result = projection((1...30).map { process(Int32($0), cpu: Double($0)) })
        XCTAssertEqual(result.contributors.first?.processes.count, 6)
        XCTAssertEqual(result.contributors.first?.processCount, 30)
        XCTAssertEqual(result.contributors.first?.cpuPercent, 465)
        XCTAssertEqual(result.contributors.first?.processes.first?.identity.pid, 30)
    }

    func testAlternateRankingsUseTheirOwnMetric() {
        let result = projection([
            process(1, cpu: 700),
            process(2, cpu: 5, gpu: 90, path: "/Applications/Renderer.app/Contents/MacOS/Renderer")
        ])
        XCTAssertEqual(result.visibleContributors(at: now).first?.displayName, "Renderer")
        XCTAssertEqual(result.visibleContributors(at: now, sort: .cpu).first?.displayName, "Example")
        XCTAssertEqual(result.visibleContributors(at: now, sort: .gpu).first?.displayName, "Renderer")
        XCTAssertTrue(result.visibleContributors(at: now.addingTimeInterval(13), sort: .cpu).isEmpty)
    }

    func testSystemServicesAreExplainedWithoutAStopRecommendation() {
        let result = projection([process(1, cpu: 400, path: "/usr/libexec/syspolicyd", system: true)])
        XCTAssertEqual(result.contributors.first?.isSystemProcess, true)
        XCTAssertTrue(result.contributors.first?.suggestedAction.contains("does not recommend stopping") == true)
    }

    func testUnknownReadingsAreExcludedFromInventoryCoverage() {
        let result = projection([
            process(1, cpu: 400, status: .unavailable),
            process(2, cpu: 50, path: "/Applications/Other.app/Contents/MacOS/Other")
        ])
        XCTAssertEqual(result.observedProcessCount, 2)
        XCTAssertEqual(result.unavailableProcessCount, 1)
        XCTAssertEqual(result.contributors.map(\.displayName), ["Other"])
        XCTAssertTrue(ThermalDiagnosis.evaluate(snapshot: snapshot(), activity: result, at: now)
            .coverageText.contains("1 of 2"))
    }

    func testNormalPressureDoesNotClaimHardwareIsCold() {
        let activity = projection([process(1, cpu: 500)])
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(celsius: 89), activity: activity, at: now)
        XCTAssertEqual(diagnosis.state, .normal)
        XCTAssertEqual(diagnosis.pressureText, "macOS pressure: Normal")
        XCTAssertEqual(diagnosis.reviewStatus, "Hot")
        let insight = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: now)
        XCTAssertEqual(insight.title, "Start with Example")
    }

    func testThermalStateDrivesGuidanceWithoutUniversalCelsiusThresholds() {
        let cases: [(String, ThermalDiagnosis.State)] = [
            ("Nominal", .normal), ("Normal", .normal), ("Fair", .warm),
            ("Serious", .serious), ("Critical", .critical), ("Waiting", .checking)
        ]
        for (reported, expected) in cases {
            let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(state: reported, celsius: nil),
                activity: projection([]), at: now)
            XCTAssertEqual(diagnosis.state, expected, reported)
        }
    }

    func testStaleAndFutureThermalStatesCannotClaimNormal() {
        for date in [now.addingTimeInterval(-16), now.addingTimeInterval(1)] {
            XCTAssertEqual(ThermalDiagnosis.evaluate(snapshot: snapshot(date: date),
                activity: projection([]), at: now).state, .checking)
        }
    }

    func testExpiredContributorCannotRemainTheSuggestedApp() {
        let activity = projection([process(1, cpu: 400)])
        let later = now.addingTimeInterval(13)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(date: later), activity: activity, at: later)
        XCTAssertFalse(diagnosis.isActivityFresh)
        let insight = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: later)
        XCTAssertEqual(insight.kind, .checking)
        XCTAssertNil(insight.contributor)
        XCTAssertTrue(insight.action.contains("Scan now"))
    }

    func testQuietSampleDoesNotClaimToExplainTemperature() {
        let activity = projection([process(1, cpu: 0)])
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(state: "Serious"), activity: activity, at: now)
        let insight = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: now)
        XCTAssertEqual(insight.kind, .unexplained)
        XCTAssertEqual(insight.title, "No clear app contributor yet")
        XCTAssertNil(insight.contributor)
    }

    func testSmallActivityIsNotDisplayedAsZero() {
        XCTAssertNotEqual(ThermalActivityFormat.percent(0.2), "0%")
        XCTAssertEqual(ThermalActivityFormat.percent(0.01), "<0.1%")
        XCTAssertEqual(ThermalActivityFormat.percent(0), "0%")
        XCTAssertEqual(ThermalActivityFormat.percent(.nan), "Unavailable")
    }

    func testPartialQuietSampleDoesNotClaimThatAppsAreQuiet() {
        let activity = projection([process(1, cpu: 0), process(2, cpu: 100, status: .unavailable)])
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(), activity: activity, at: now)
        let insight = ThermalAppInsight.evaluate(activity: activity, diagnosis: diagnosis, at: now)
        XCTAssertTrue(insight.evidence.contains("could not be measured"))
        XCTAssertFalse(insight.evidence.contains("little activity"))
    }

    func testWorkerPublishesRawActivityWhenThereAreNoCandidateFamilies() async {
        var settings = ThresholdSettings.smart
        settings.radarMode = .dev
        let processes = [process(1, cpu: 18)]
        let worker = RadarRefreshWorker(store: nil, builder: ProcessFamilyBuilder(currentUserID: 501))
        let request = RefreshRequest(settings: settings, currentFamilies: [], currentIncidents: [],
            currentStoreHealth: .empty, previousRefresh: .empty, popoverVisible: true,
            focusedSignatureIDs: [], now: now, startedAt: now)
        let outcome = await worker.ingest(batch: ProcessSampleBatch(processes: processes, sampledAt: now, stats: .empty),
            request: request)
        XCTAssertEqual(outcome.thermalActivity.coverage, .processInventory)
        XCTAssertEqual(outcome.thermalActivity.contributors.first?.displayName, "Example")
        XCTAssertTrue(outcome.families.isEmpty, "The fixture must exercise a process omitted by the family filter")
    }

    func testMonitorIngestPublishesActivityIndependentlyOfDisplayedFamilies() {
        var settings = ThresholdSettings.smart
        settings.radarMode = .dev
        let monitor = ProcessMonitor(settings: settings, store: nil)
        monitor.ingest([process(1, cpu: 18)], now: now)
        XCTAssertEqual(monitor.thermalActivity.coverage, .processInventory)
        XCTAssertEqual(monitor.thermalActivity.contributors.first?.displayName, "Example")
    }

    private func projection(_ processes: [ProcessMetrics]) -> ThermalActivitySummary {
        ThermalActivityAnalyzer.project(processes: processes, families: [], now: now, processorCount: 10)
    }

    private func snapshot(state: String = "Nominal", celsius: Double? = 65, date: Date? = nil) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date ?? now, cpuCelsius: celsius, gpuCelsius: celsius,
            sensorCount: celsius == nil ? 0 : 2, sensorKeys: [], systemState: state, unavailableReason: nil)
    }

    private func process(_ pid: Int32, cpu: Double, gpu: Double = 0,
                         path: String = "/Applications/Example.app/Contents/MacOS/Example",
                         system: Bool = false, status: ProcessMeasurementStatus = .fresh) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_999_999_000, startTimeMicroseconds: 0),
            parentPID: 1, userID: system ? 0 : 501, ownerName: system ? "root" : "fixture", name: "Example",
            executablePath: path, commandLine: "Example", residentMemoryBytes: 32 * 1_048_576,
            physicalFootprintBytes: 32 * 1_048_576, virtualMemoryBytes: 64 * 1_048_576,
            cpuPercent: cpu, gpuUsagePercent: gpu, totalProcessorSeconds: 10, threadCount: 2,
            isSystemProcess: system, sampledAt: now, measurementStatus: status)
    }
}
