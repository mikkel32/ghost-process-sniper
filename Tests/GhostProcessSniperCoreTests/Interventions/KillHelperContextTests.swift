import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A helper an app runs, or a macOS XPC service, is not an ordinary process:
/// stopping it costs the app a window or tab, and launchd is not what starts
/// it again.
final class KillHelperContextTests: XCTestCase {
    private let assessor = KillRiskAssessor()

    private let slack = "/Applications/Slack.app/Contents/MacOS/Slack"
    private let slackRenderer = "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
    private let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"

    // MARK: - XPC services

    func testAnXPCServiceIsNotRestartedByLaunchd() {
        let risk = assess(path: webContent, name: "com.apple.WebKit.WebContent", parentIsLaunchd: true)

        XCTAssertNil(risk.supervisor, "the app that uses it starts it on demand, not launchd")
        XCTAssertFalse(risk.risks.contains { $0.kind == .respawn })
        XCTAssertFalse(risk.risks.contains { $0.kind == .orphaned }, "it has an app, even though its parent is launchd")
    }

    func testAKeptAliveLaunchdJobStillRestartsAnXPCService() {
        let job = LaunchdJob(label: "com.apple.WebKit.WebContent", pid: 200, domain: "gui/501", plistPath: nil, keepAlive: true)
        let risk = assess(path: webContent, name: "com.apple.WebKit.WebContent", parentIsLaunchd: true, job: job)

        XCTAssertEqual(risk.supervisor?.kind, .launchd, "a resolved KeepAlive job is real evidence")
    }

    func testSystemDaemonsAreStillRestartedByLaunchd() {
        let risk = assess(path: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd", name: "cloudd",
                          parentIsLaunchd: true)

        XCTAssertEqual(risk.supervisor?.kind, .launchd)
        XCTAssertFalse(risk.risks.contains { $0.kind == .appHelper })
    }

    func testAWebContentServiceSaysTheTabMayNeedAReload() throws {
        let risk = assess(path: webContent, name: "com.apple.WebKit.WebContent", parentIsLaunchd: true)

        let card = try XCTUnwrap(risk.hazards.first { $0.kind == .appHelper })
        XCTAssertEqual(card.title, "Service used by an app")
        XCTAssertEqual(card.severity, .caution)
        XCTAssertEqual(card.detail, "An app started this service for one of its windows or tabs. If that app is open, that window or tab may go blank or need a reload.")
    }

    func testAnXPCServiceInsideAnAppNamesTheApp() throws {
        let risk = assess(path: "/Applications/Pages.app/Contents/XPCServices/Pages Helper.xpc/Contents/MacOS/Pages Helper",
                          name: "Pages Helper", parentIsLaunchd: true)

        let card = try XCTUnwrap(risk.hazards.first { $0.kind == .appHelper })
        XCTAssertEqual(card.title, "Service used by Pages")
        XCTAssertEqual(card.severity, .info)
        XCTAssertTrue(card.detail.hasPrefix("Pages uses this service. If Pages is open"), card.detail)
        XCTAssertNil(risk.appQuitPID)
    }

    // MARK: - Helpers of an app

    func testARendererHelperSaysTheWindowMayNeedAReload() throws {
        let risk = assess(path: slackRenderer, name: "Slack Helper (Renderer)", ancestors: [slackAncestor])

        let card = try XCTUnwrap(risk.hazards.first { $0.kind == .appHelper })
        XCTAssertEqual(card.title, "Part of Slack")
        XCTAssertEqual(card.severity, .caution)
        XCTAssertEqual(card.detail, "Slack stays open, but the window or tab this process draws may go blank or need a reload.")
        XCTAssertNil(risk.appQuitPID, "a helper is not asked to quit like the app")
    }

    func testOtherHelpersAreOnlyANote() throws {
        let gpu = assess(path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (GPU).app/Contents/MacOS/Slack Helper (GPU)",
                         name: "Slack Helper (GPU)", ancestors: [slackAncestor])
        XCTAssertEqual(gpu.hazards.first { $0.kind == .appHelper }?.severity, .info)
        XCTAssertEqual(gpu.hazards.first { $0.kind == .appHelper }?.detail,
                       "Slack stays open, but its windows may flicker while it starts its graphics process again.")

        let network = assess(path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper",
                             name: "Slack Helper", command: "Slack Helper --type=utility --utility-sub-type=network.mojom.NetworkService",
                             ancestors: [slackAncestor])
        XCTAssertEqual(network.hazards.first { $0.kind == .appHelper }?.severity, .info)

        let plugin = assess(path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Plugin).app/Contents/MacOS/Slack Helper (Plugin)",
                            name: "Slack Helper (Plugin)", ancestors: [slackAncestor])
        XCTAssertEqual(plugin.hazards.first { $0.kind == .appHelper }?.severity, .info)
        XCTAssertEqual(plugin.hazards.first { $0.kind == .appHelper }?.detail,
                       "Slack stays open, but the feature this process provides may stop working for a moment.")
    }

    func testABrowserHelperIsNamedAfterTheOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/126.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let chrome = KillWorkloadAncestor(pid: 300, name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                                          commandLine: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

        let risk = assess(path: path, name: "Google Chrome Helper (Renderer)", ancestors: [chrome])

        XCTAssertEqual(risk.hazards.first { $0.kind == .appHelper }?.title, "Part of Google Chrome")
    }

    func testAnOrphanedHelperIsStillJustAnOrphan() {
        // The app is gone: nothing draws a window for it, and nothing restarts it.
        let risk = assess(path: slackRenderer, name: "Slack Helper (Renderer)", parentIsLaunchd: true)

        XCTAssertFalse(risk.risks.contains { $0.kind == .appHelper })
        XCTAssertTrue(risk.benefits.contains { $0.kind == .orphaned })
    }

    func testAHelperOfAnotherAppIsNotThisApps() {
        let other = KillWorkloadAncestor(pid: 301, name: "Notes", executablePath: "/System/Applications/Notes.app/Contents/MacOS/Notes",
                                         commandLine: "/System/Applications/Notes.app/Contents/MacOS/Notes")

        let risk = assess(path: slackRenderer, name: "Slack Helper (Renderer)", ancestors: [other])

        XCTAssertFalse(risk.risks.contains { $0.kind == .appHelper })
    }

    func testLoginItemsAreBackgroundAgentsWithNoWindow() {
        let risk = assess(path: "/Applications/Slack.app/Contents/Library/LoginItems/Slack Login Helper.app/Contents/MacOS/Slack Login Helper",
                          name: "Slack Login Helper", ancestors: [slackAncestor])

        XCTAssertFalse(risk.risks.contains { $0.kind == .appHelper })
    }

    func testTheAppItselfIsNotAHelper() {
        let risk = assess(path: slack, name: "Slack")

        XCTAssertFalse(risk.risks.contains { $0.kind == .appHelper })
        XCTAssertEqual(risk.appQuitPID, 100)
    }

    func testAPlainToolInsideAnAppBundleIsNotAHelper() {
        let risk = assess(path: "/Applications/Slack.app/Contents/MacOS/crashpad_handler", name: "crashpad_handler",
                          ancestors: [slackAncestor])

        XCTAssertFalse(risk.risks.contains { $0.kind == .appHelper })
    }

    // MARK: - The stop itself

    func testStoppingOnlyARendererHelperReadsAsACaution() async {
        let table = FakeProcessTable()
        let app = KillProcessLite.fake(pid: 960, name: "Slack")
        let renderer = KillProcessLite.fake(pid: 961, parent: 960, name: "Slack Helper (Renderer)")
        [app, renderer].forEach { table.add($0) }
        let plan = KillPlan.fixture(app, members: [app, renderer], paths: [960: slack, 961: slackRenderer])
            .targetingOnly(renderer.identity, name: renderer.name)

        let preview = await table.killer().preview(plan: plan, forceKillDelay: 2)

        XCTAssertEqual(preview.targetPIDs, [961])
        XCTAssertTrue(preview.riskAssessment.hazards.contains { $0.kind == .appHelper && $0.title == "Part of Slack" })
        XCTAssertEqual(preview.readiness, .caution)
        XCTAssertNotEqual(preview.strategyRecommendation.strategy, .quitApp, "a helper is not asked to quit like the app")
    }

    func testAReloadedTabIsNotCalledALaunchdRestart() async {
        let table = FakeProcessTable()
        // Safari reloads the tab in a new WebContent process, also under launchd.
        let tab = KillProcessLite.fake(pid: 950, parent: 1, name: "com.apple.WebKit.WebContent", start: 999_000)
        let reloaded = KillProcessLite.fake(pid: 951, parent: 1, name: "com.apple.WebKit.WebContent", start: 1_000_000)
        table.add(tab, FakeProcessTable.Behaviour(onSignal: [SIGTERM: [.respawn(reloaded, afterTicks: 1)]]))
        let plan = KillPlan.fixture(tab, paths: [950: webContent])

        let report = await table.killer().kill(plan: plan, forceKillDelay: 2)

        XCTAssertTrue(report.respawnedPIDs.isEmpty, "no launchd job restarted it")
        XCTAssertFalse(report.summary.contains("started it again"), report.summary)
    }

    // MARK: - Fixtures

    private var slackAncestor: KillWorkloadAncestor {
        KillWorkloadAncestor(pid: 99, name: "Slack", executablePath: slack, commandLine: slack)
    }

    private func assess(
        path: String,
        name: String,
        command: String? = nil,
        ancestors: [KillWorkloadAncestor] = [],
        parentIsLaunchd: Bool = false,
        job: LaunchdJob? = nil
    ) -> KillRiskAssessment {
        let root = KillWorkloadProcess(pid: 100, parentPID: parentIsLaunchd ? 1 : 99, name: name, executablePath: path,
                                       commandLine: command ?? path, isRoot: true)
        return assessor.assess(KillWorkloadProfile(processes: [root], ancestors: ancestors, parentIsLaunchd: parentIsLaunchd,
                                                   launchdJob: job))
    }
}
