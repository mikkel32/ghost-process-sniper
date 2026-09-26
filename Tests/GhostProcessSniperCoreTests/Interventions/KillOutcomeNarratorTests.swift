import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A stop's result must say, by name, what happened and what is left.
final class KillOutcomeNarratorTests: XCTestCase {
    private struct Case {
        let name: String
        let report: KillReport
        let headline: String
        let nextStep: String?
    }

    func testHeadlinesAndNextSteps() {
        let cases = [
            Case(name: "all exited",
                 report: report(targets: [target(100, "Cursor", .terminated, root: true), target(101, "Cursor Helper", .terminated),
                                          target(102, "Cursor Helper (GPU)", .terminated)],
                                graceful: [100, 101], seconds: 2.4, freed: 1_610_612_736),
                 headline: "Stopped Cursor and 2 helpers in 2.4 s. Freed 1.5 GB.", nextStep: nil),
            Case(name: "app still open",
                 report: report(targets: [target(300, "Pages", .survived, root: true)], graceful: [300], survivors: [300],
                                skipForce: true, appStillOpen: true),
                 headline: "Pages is still open; it may be showing a save prompt. Answer it there, or force-stop it.", nextStep: nil),
            Case(name: "held survivor",
                 report: report(targets: [target(500, "node", .survived, root: true)], graceful: [500], survivors: [500], skipForce: true),
                 headline: "node (PID 500) is still running.",
                 nextStep: "It may be waiting on you, such as a save prompt; force-stop only if you are sure."),
            Case(name: "EPERM",
                 report: {
                     var report = report(targets: [target(700, "agent", .locked, root: true)], denied: [700])
                     report.signalDeniedPIDs = [700]
                     return report
                 }(),
                 headline: "macOS refused to stop Cursor (PID 700). It is protected by security software or a system policy; nothing else was tried.",
                 nextStep: nil),
            Case(name: "respawn",
                 report: {
                     var report = report(targets: [target(800, "node", .terminated, root: true)], graceful: [800])
                     report.respawnedPIDs = [812]
                     report.respawnedBy = "PM2"
                     return report
                 }(),
                 headline: "Stopped Cursor, but PM2 started it again (PID 812).", nextStep: "Stop PM2 instead."),
            Case(name: "launchd respawn",
                 report: {
                     var report = report(targets: [target(812, "postgres", .terminated, root: true)], graceful: [812])
                     report.respawnedPIDs = [830]
                     report.respawnedBy = "homebrew.mxcl.postgresql@16"
                     report.launchdJob = LaunchdJob(label: "homebrew.mxcl.postgresql@16", pid: 812, domain: "gui/501",
                                                    plistPath: nil, keepAlive: true)
                     return report
                 }(),
                 headline: "Stopped Cursor, but homebrew.mxcl.postgresql@16 started it again (PID 830).",
                 nextStep: "Run brew services stop postgresql@16 to keep it stopped."),
            Case(name: "forced",
                 report: report(targets: [target(900, "java", .forceKilled, root: true), target(901, "java", .terminated)],
                                graceful: [900, 901], forced: [900]),
                 headline: "Stopped Cursor; 1 process needed a force stop.", nextStep: nil),
            Case(name: "partial",
                 report: report(targets: [target(950, "make", .terminated, root: true), target(951, "cc", .survived),
                                          target(952, "ld", .survived)],
                                graceful: [950, 951, 952], forced: [951, 952], survivors: [951, 952]),
                 headline: "cc (PID 951), ld (PID 952) are still running, even after a force stop.",
                 nextStep: "If anything is still running in a minute, open a new preview to try again."),
            Case(name: "stuck exiting",
                 report: {
                     var report = report(targets: [target(960, "rsync", .survived, root: true)], graceful: [960], forced: [960],
                                         survivors: [960])
                     report.stuckExitingPIDs = [960]
                     return report
                 }(),
                 headline: "rsync (PID 960) is still running, even after a force stop.", nextStep: nil)
        ]
        for testCase in cases {
            let narrative = testCase.report.narrative
            XCTAssertEqual(narrative.headline, testCase.headline, testCase.name)
            XCTAssertEqual(narrative.nextStep, testCase.nextStep, testCase.name)
            XCTAssertTrue(testCase.report.summary.hasPrefix(testCase.headline), testCase.name)
        }
    }

    func testPortsAreClaimedOnlyAsVerified() {
        var stopped = report(targets: [target(100, "vite", .terminated, root: true)], graceful: [100])
        stopped.portOutcomes = [.freed(5173), .unverified(3000), .heldBy(port: 9229, pid: 812, name: "node", startedDuringStop: true)]

        XCTAssertEqual(stopped.narrative.details, [
            "Port 5173 is free.",
            "Port 3000 should now be free.",
            "Port 9229 is still held by node (PID 812), started during the stop."
        ])
    }

    func testCopiedReportLeadsWithTheStoryThenEachProcess() {
        let lines = report(targets: [target(100, "vite", .terminated, root: true), target(101, "esbuild", .survived)],
                           graceful: [100, 101], survivors: [101], skipForce: true)
            .diagnosticText.components(separatedBy: "\n")

        XCTAssertEqual(lines[1], "esbuild (PID 101) is still running.")
        XCTAssertEqual(lines[3], "Processes:")
        XCTAssertEqual(lines[4], "- esbuild (PID 101) \u{2192} Survived, test")
        XCTAssertEqual(lines[6], "Diagnostics:")
    }

    func testOutcomeRowsKeepOneRowPerProcessProblemsFirst() {
        var result = report(targets: [target(100, "vite", .terminated, root: true), target(101, "esbuild", .survived),
                                      target(102, "watcher", .ready)])
        result.lateTargets = [target(102, "watcher", .forceKilled), target(103, "late", .locked)]

        let rows = KillOutcomeRows.make(report: result)

        XCTAssertEqual(rows.map(\.pid), [101, 103, 102, 100])
        XCTAssertEqual(rows.map(\.state), [.survived, .locked, .forceKilled, .terminated])
    }

    func testTargetRowIdentityIgnoresItsState() {
        let ready = target(100, "vite", .ready, root: true)
        let stopping = ready.updating(state: .stopping, reason: "Asked to stop")

        XCTAssertEqual(ready.id, stopping.id, "a state change updates the row instead of replacing it")
        XCTAssertNotEqual(ready.id, target(101, "vite", .ready).id)
    }

    // MARK: - Fixtures

    private func target(_ pid: Int32, _ name: String, _ state: KillTargetState, root: Bool = false) -> KillTarget {
        KillTarget(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0), parentPID: 1,
                   name: name, ownerName: "me", depth: root ? 0 : 1, memoryBytes: 0, cpuPercent: 0, state: state,
                   reason: "test", isRoot: root)
    }

    private func report(
        targets: [KillTarget],
        graceful: [Int32] = [],
        forced: [Int32] = [],
        survivors: [Int32] = [],
        denied: [Int32] = [],
        skipForce: Bool = false,
        appStillOpen: Bool = false,
        seconds: Double = 0.2,
        freed: UInt64 = 0
    ) -> KillReport {
        var report = KillReport(
            displayName: targets.first(where: \.isRoot)?.name == "Pages" ? "Pages" : "Cursor",
            rootPID: targets.first(where: \.isRoot)?.pid ?? 0,
            gracefulPIDs: graceful,
            forcedPIDs: forced,
            deniedPIDs: denied,
            targetResults: targets,
            survivorPIDs: survivors,
            timeline: KillExecutionTimeline(preflightMilliseconds: 0, signalMilliseconds: 0, verificationMilliseconds: 0,
                                            totalMilliseconds: seconds * 1_000),
            realizedMemoryReclaimBytes: freed,
            skipForceRequested: skipForce
        )
        report.appStillOpen = appStillOpen
        return report
    }
}
