import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The launchd of a booted simulated device is one process that is a whole
/// operating system: stopping it kills every app inside at once, and
/// `simctl shutdown` is the way that lets them wind down.
final class KillSimulatorRiskTests: XCTestCase {
    private let assessor = KillRiskAssessor()

    private let udid = "4F1C2A9E-8B7D-4C55-9B1E-0A6D2E7F3C11"
    private let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_23A344/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot"

    func testTheLaunchdOfASimulatedDeviceNamesTheCleanShutdown() throws {
        let risk = assessLaunchd(command: "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist")

        XCTAssertEqual(risk.kind, .simulator)
        XCTAssertEqual(risk.kind.label, "Simulator")
        let card = try XCTUnwrap(risk.hazards.first { $0.kind == .unsavedWork })
        XCTAssertEqual(card.title, "Simulated device stops abruptly")
        XCTAssertEqual(card.severity, .caution)
        XCTAssertEqual(card.detail, "Apps running in it lose their state at once. Shut it down cleanly with xcrun simctl shutdown \(udid) or Device > Shut Down in Simulator.")
        XCTAssertEqual(risk.headline, "Stops the simulated device and every app in it at once. To shut it down cleanly, run xcrun simctl shutdown \(udid).")
        XCTAssertFalse(risk.risks.contains { $0.kind == .orphaned }, "it is not a forgotten leftover")
        XCTAssertEqual(risk.graceSeconds, 6)
        XCTAssertFalse(risk.forceNeedsConfirmation)
        XCTAssertNil(risk.appQuitPID)
    }

    func testWithoutADeviceInItsArgumentsItPointsAtSimulator() throws {
        let risk = assessLaunchd(command: "launchd_sim")

        let card = try XCTUnwrap(risk.hazards.first { $0.kind == .unsavedWork })
        XCTAssertEqual(card.detail, "Apps running in it lose their state at once. Shut it down cleanly from Simulator (Device > Shut Down); xcrun simctl list devices booted shows which one this is.")
        XCTAssertFalse(card.detail.contains("shutdown all"), "that would shut down every simulator, not this one")
        XCTAssertFalse((risk.headline ?? "").contains("shutdown"))
    }

    func testOnlyAWellFormedDeviceIDIsPastedIntoTheCommand() throws {
        for bad in ["$(rm -rf ~)", "4F1C2A9E-8B7D-4C55-9B1E-0A6D2E7F3C1", "4F1C2A9E-8B7D-4C55-9B1E-0A6D2E7F3C11Z", "4F1C2A9E-8B7D-4C55-9B1E-0A6D2E7F3CXX"] {
            let risk = assessLaunchd(command: "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(bad)/data/var/run/launchd_bootstrap.plist")
            let card = try XCTUnwrap(risk.hazards.first { $0.kind == .unsavedWork })
            XCTAssertFalse(card.detail.contains("shutdown"), bad)
            XCTAssertFalse(card.detail.contains(bad), bad)
        }
    }

    func testTheDeviceCanBeFoundInAFamilyStopToo() {
        let workload = KillWorkloadProfile(
            processes: [
                KillWorkloadProcess(pid: 500, parentPID: 1, name: "launchd_sim", executablePath: "\(runtime)/sbin/launchd_sim",
                                    commandLine: "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist",
                                    isRoot: true),
                KillWorkloadProcess(pid: 501, parentPID: 500, name: "SpringBoard",
                                    executablePath: "\(runtime)/System/Library/CoreServices/SpringBoard.app/SpringBoard", commandLine: "SpringBoard")
            ],
            ancestors: [], parentIsLaunchd: true
        )

        XCTAssertEqual(assessor.assess(workload).kind, .simulator)
    }

    // MARK: - What stays as it was

    func testTheSimulatorAppIsStillAnApp() {
        let risk = assess(name: "Simulator", path: "/Applications/Simulator.app/Contents/MacOS/Simulator", command: "Simulator")

        XCTAssertEqual(risk.kind, .app)
        XCTAssertEqual(risk.appQuitPID, 600)
    }

    func testOtherPartsOfTheSimulatorAreNotTheDeviceItself() {
        let parts: [(name: String, path: String, command: String)] = [
            ("simctl", "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl", "simctl boot \(udid)"),
            ("com.apple.CoreSimulator.CoreSimulatorService",
             "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService",
             "com.apple.CoreSimulator.CoreSimulatorService"),
            ("SimulatorTrampoline", "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/SimulatorTrampoline",
             "SimulatorTrampoline"),
            ("SpringBoard", "\(runtime)/System/Library/CoreServices/SpringBoard.app/SpringBoard", "SpringBoard"),
            ("MobileSafari", "\(runtime)/Applications/MobileSafari.app/MobileSafari", "MobileSafari")
        ]
        for part in parts {
            let risk = assess(name: part.name, path: part.path, command: part.command)
            XCTAssertNotEqual(risk.kind, .simulator, part.name)
            XCTAssertFalse(risk.hazards.contains { $0.title == "Simulated device stops abruptly" }, part.name)
        }
    }

    func testStoppingOnlySpringBoardShowsNoDeviceCard() {
        let workload = KillWorkloadProfile(
            processes: [
                KillWorkloadProcess(pid: 500, parentPID: 1, name: "launchd_sim", executablePath: "\(runtime)/sbin/launchd_sim",
                                    commandLine: "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist",
                                    isRoot: true),
                KillWorkloadProcess(pid: 501, parentPID: 500, name: "SpringBoard",
                                    executablePath: "\(runtime)/System/Library/CoreServices/SpringBoard.app/SpringBoard", commandLine: "SpringBoard")
            ],
            ancestors: [], parentIsLaunchd: true
        )

        let risk = assessor.assess(workload.restricted(to: 501))

        XCTAssertNotEqual(risk.kind, .simulator)
        XCTAssertFalse(risk.hazards.contains { $0.title == "Simulated device stops abruptly" })
    }

    func testThePreviewGivesTheSimulatedSystemTimeToWindDown() async {
        let table = FakeProcessTable()
        let device = KillProcessLite.fake(pid: 700, name: "launchd_sim")
        table.add(device)
        let command = "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"
        let plan = KillPlan.fixture(device, paths: [700: "\(runtime)/sbin/launchd_sim"], commands: [700: command])

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.riskAssessment.kind, .simulator)
        XCTAssertEqual(preview.strategyRecommendation.strategy, .standard)
        XCTAssertEqual(preview.recommendedGraceSeconds, 6, "the force delay alone would be 2 s")
    }

    func testARecordOfIgnoredTerminationNeverMakesADeviceStubborn() {
        let record = KillOutcomeModelTests.history(Array(repeating: KillOutcomeModelTests.forced(), count: 8))
        let command = "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"

        let device = PolicyFixture.evaluate(command: command, name: "launchd_sim", outcomes: record, parent: 1,
                                            path: "\(runtime)/sbin/launchd_sim")
        let plain = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: record)

        XCTAssertEqual(plain.recommendation.strategy, .stubbornRunaway, "the same record does make an ordinary process stubborn")
        XCTAssertEqual(device.risk.kind, .simulator)
        XCTAssertEqual(device.recommendation.strategy, .standard, "an ended simulated system is not one to force quickly")
        XCTAssertEqual(device.profile.graceSeconds, 6)
    }

    // MARK: - Fixtures

    private func assessLaunchd(command: String) -> KillRiskAssessment {
        assess(name: "launchd_sim", path: "\(runtime)/sbin/launchd_sim", command: command)
    }

    private func assess(name: String, path: String, command: String) -> KillRiskAssessment {
        let root = KillWorkloadProcess(pid: 600, parentPID: 1, name: name, executablePath: path, commandLine: command, isRoot: true)
        return assessor.assess(KillWorkloadProfile(processes: [root], ancestors: [], parentIsLaunchd: true))
    }
}
