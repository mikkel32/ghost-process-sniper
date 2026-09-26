import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A refreshed preview names what changed only when Confirm would do
/// something different.
final class KillPreviewChangeTests: XCTestCase {
    func testSameTargetsAndStrategyIsNoChange() {
        let old = preview([target(100, "vite", root: true), target(101, "esbuild")], memory: 10)
        XCTAssertNil(preview([target(100, "vite", root: true), target(101, "esbuild")], memory: 900).materialChange(from: old))
    }

    func testRootGone() {
        let old = preview([target(400, "postgres", root: true)])
        let change = preview([]).materialChange(from: old)
        XCTAssertEqual(change?.kind, .rootGone)
        XCTAssertEqual(change?.text, "postgres exited on its own; nothing to stop.")
    }

    func testTargetsExited() {
        let old = preview([target(100, "vite", root: true), target(101, "esbuild"), target(102, "tsc")])
        let change = preview([target(100, "vite", root: true)]).materialChange(from: old)
        XCTAssertEqual(change?.kind, .targetsExited([101, 102]))
        XCTAssertEqual(change?.text, "esbuild (PID 101) and tsc (PID 102) exited on their own.")
    }

    func testTargetsJoined() {
        let old = preview([target(100, "vite", root: true)])
        let change = preview([target(100, "vite", root: true), target(105, "node")]).materialChange(from: old)
        XCTAssertEqual(change?.kind, .targetsJoined([105]))
        XCTAssertEqual(change?.text, "node (PID 105) started since you opened this; it stops too.")
    }

    func testStrategyChanged() {
        let old = preview([target(100, "vite", root: true)])
        let new = preview([target(100, "vite", root: true)], strategy: .inspectOnly, reason: "It is writing a lock file.")
        let change = new.materialChange(from: old)
        XCTAssertEqual(change?.kind, .strategyChanged(from: .standard, to: .inspectOnly))
        XCTAssertEqual(change?.text, "The plan changed from \(KillStrategy.standard.label) to \(KillStrategy.inspectOnly.label): It is writing a lock file.")
    }

    func testRecycledPIDIsAnExitAndAJoin() {
        let old = preview([target(100, "vite", root: true), target(101, "esbuild")])
        let reused = KillTarget(identity: ProcessIdentity(pid: 101, startTimeSeconds: 9_000, startTimeMicroseconds: 0), parentPID: 100,
                                name: "esbuild", ownerName: "me", depth: 1, memoryBytes: 0, cpuPercent: 0, state: .ready,
                                reason: "", isRoot: false)
        XCTAssertEqual(preview([target(100, "vite", root: true), reused]).materialChange(from: old)?.kind, .targetsJoined([101]),
                       "a new process behind an old PID is a new target")
    }

    private func target(_ pid: Int32, _ name: String, root: Bool = false) -> KillTarget {
        KillTarget(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0), parentPID: root ? 1 : 100,
                   name: name, ownerName: "me", depth: root ? 0 : 1, memoryBytes: 0, cpuPercent: 0, state: .ready,
                   reason: "", isRoot: root)
    }

    private func preview(
        _ targets: [KillTarget],
        memory: UInt64 = 0,
        strategy: KillStrategy = .standard,
        reason: String = "Standard stop."
    ) -> KillPreview {
        KillPreview(
            displayName: "vite", rootPID: 100, protectedPIDs: [], forceKillDelay: 2,
            targets: targets,
            reclaimEstimate: KillReclaimEstimate(memoryBytes: memory, cpuPercent: 0, confidence: 1, sourceText: ""),
            strategyRecommendation: KillStrategyRecommendation(strategy: strategy, confidence: 0.8, reasons: [reason], previewText: "")
        )
    }
}
