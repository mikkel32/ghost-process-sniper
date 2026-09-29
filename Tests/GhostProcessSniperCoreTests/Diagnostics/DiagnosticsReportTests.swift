import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class DiagnosticsReportTests: XCTestCase {
    func testIdentityNamesTheBuildTheMacAndItsMode() {
        let identity = DiagnosticsIdentity(
            appVersion: "2.1.0", appBuild: "12", systemVersion: "Version 26.0 (Build 25A354)",
            hardwareModel: "MacBookPro18,3", chip: "Apple M1 Pro", memoryBytes: 16 * 1_073_741_824,
            coreCount: 10, lowPowerMode: true, thermalState: "nominal", localeIdentifier: "da_DK"
        )
        XCTAssertEqual(identity.lines, [
            "App: Ghost Process Sniper 2.1.0 (build 12)",
            "macOS: Version 26.0 (Build 25A354)",
            "Mac: MacBookPro18,3, Apple M1 Pro, 16.0 GB, 10 cores",
            "Power: Low Power Mode on, thermal state nominal",
            "Locale: da_DK"
        ])
    }

    func testAMissingVersionSaysSoInsteadOfGuessing() {
        var identity = DiagnosticsIdentity.current(bundle: nil)
        XCTAssertEqual(identity.lines.first, "App: unbundled build (no version)", "a `swift run` binary has no Info.plist")
        identity.appVersion = "2.1.0"
        XCTAssertEqual(identity.lines.first, "App: Ghost Process Sniper 2.1.0")
        // The Mac is always readable, bundled or not.
        let current = DiagnosticsIdentity.current(bundle: nil)
        XCTAssertFalse(current.systemVersion.isEmpty)
        XCTAssertFalse(current.hardwareModel.isEmpty)
        XCTAssertGreaterThan(current.memoryBytes, 0)
        XCTAssertGreaterThan(current.coreCount, 0)
        XCTAssertEqual(current.lines.count, 5)
    }

    func testTheLiveReportLeadsWithTheIdentityAndTheLimitsInEffect() {
        let smart = ThresholdSettings.smart.resolvedProfile(systemPressure: .unknown, physicalMemoryBytes: 16 * 1_073_741_824)
        let lines = report(profile: smart)
        XCTAssertEqual(Array(lines.prefix(2)), ["Ghost Process Sniper Diagnostics", "Generated: \(Date(timeIntervalSince1970: 2).formatted())"])
        for prefix in ["App: ", "macOS: ", "Mac: ", "Power: ", "Locale: "] {
            XCTAssertTrue(lines.dropFirst(2).prefix(6).contains { $0.hasPrefix(prefix) }, "\(prefix) follows the header")
        }
        XCTAssertTrue(lines.contains(
            "Detection: Automatic, Balanced sensitivity; limits: memory \(smart.memoryThresholdText), CPU \(smart.cpuThresholdText), growth \(smart.leakThresholdText)"
        ), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("Modes: Dev radar, Balanced performance, adaptive performance on, family grouping on"))
        XCTAssertTrue(lines.contains("State: Quiet"), "the existing report is still all there")

        let custom = ThresholdSettings.aggressive.resolvedProfile()
        XCTAssertTrue(report(profile: custom).contains(
            "Detection: Custom; limits: memory \(custom.memoryThresholdText), CPU \(custom.cpuThresholdText), growth \(custom.leakThresholdText)"
        ), "sensitivity only matters to automatic detection")
        XCTAssertFalse(report(profile: nil).contains { $0.hasPrefix("Detection: ") }, "without settings the report says nothing about them")
    }

    func testRedactionKeepsTheAccountNameOutOfAReport() {
        let home = "/Users/alice"
        let text = "URL: /Users/alice/Library/Application Support/Ghost Process Sniper/Radar.sqlite\nLast kill: Stopped /Users/alice/dev/app"
        XCTAssertEqual(
            DiagnosticsIdentity.redactingHome(in: text, home: home),
            "URL: ~/Library/Application Support/Ghost Process Sniper/Radar.sqlite\nLast kill: Stopped ~/dev/app"
        )
        XCTAssertEqual(DiagnosticsIdentity.redactingHome(in: "Home is /Users/alice", home: home), "Home is ~")
        XCTAssertEqual(DiagnosticsIdentity.redactingHome(in: "/Users/alicex/Library", home: home), "/Users/alicex/Library",
                       "another account whose name starts the same is not this home")
        XCTAssertEqual(DiagnosticsIdentity.redactingHome(in: "/opt/tool", home: home), "/opt/tool")
        XCTAssertEqual(DiagnosticsIdentity.redactingHome(in: "/opt/tool", home: "/"), "/opt/tool", "a root home would rewrite every path")
        XCTAssertEqual(DiagnosticsIdentity.redactingHome(in: "/opt/tool", home: ""), "/opt/tool")
    }

    private func report(profile: ResolvedThresholdProfile?) -> [String] {
        EngineDiagnosticsViewModel.diagnosticsReport(
            metrics: .empty,
            health: .starting,
            storeHealth: .empty,
            storeError: nil,
            summary: RadarSummary(statusText: "Quiet", level: .quiet, familyCount: 0, hotCount: 0, totalMemoryBytes: 0, topFamilyName: nil),
            generatedAt: Date(timeIntervalSince1970: 2),
            profile: profile
        ).components(separatedBy: "\n")
    }
}
