import Darwin
import Foundation

/// How long the force stage keeps looking for processes born while it
/// freezes the tree.
struct KillSweepBudget: Sendable {
    var maxRounds = 3
    var maxTotal = 256
}

/// Finds processes a stop did not know about because they started after
/// it was approved: children forked during the grace, or left behind when
/// their parent exited.
enum KillTreeSweeper {
    /// Same-user processes, not in `known` and not below the protection
    /// floor, born at or after `bornAfter`, that descend from an anchor
    /// through other such newborns only. A child of an already exited
    /// anchor has been handed to launchd, so an orphan in a process group
    /// an anchor leads counts too.
    static func lateMembers(
        arena: KillGraphArena,
        anchors: [KillTarget],
        known: Set<ProcessIdentity>,
        bornAfter: Date,
        currentUserID: UInt32,
        protection: KillProtectionPolicy,
        rootIdentity: ProcessIdentity,
        startedWhen: String = "during the stop"
    ) -> [KillTarget] {
        let anchorDepths = Dictionary(anchors.map { ($0.identity, $0.depth) }, uniquingKeysWith: min)
        let anchorPIDs = Set(anchors.map(\.pid))
        let ledGroups = Set(anchors.map(\.processGroupID).filter { $0 > 1 && anchorPIDs.contains($0) })
        let floor = protection.selfAndAncestors { arena.processes(for: $0).first?.parentPID }
        let threshold = bornAfter.timeIntervalSince1970
        let isNewborn = { (process: KillProcessLite) in
            !known.contains(process.identity) && process.userID == currentUserID && !process.isZombie &&
                Self.startTime(of: process) >= threshold
        }

        var output: [KillTarget] = []
        for process in arena.processes where isNewborn(process) && !anchorDepths.keys.contains(process.identity) {
            if case .never = protection.verdict(for: process, executablePath: nil, commandLine: nil, arena: arena,
                                                selfAndAncestors: floor) {
                continue
            }
            let parent = arena.processes(for: process.parentPID).first
            let origin = parent.map { "\($0.name) (PID \($0.pid))" } ?? "a process that has since exited"
            let reason = "Started \(startedWhen) by \(origin)"
            if let depth = depth(of: process, arena: arena, anchorDepths: anchorDepths, isNewborn: isNewborn) {
                output.append(KillTarget(process: process, depth: depth, state: .ready, reason: reason, rootIdentity: rootIdentity))
            } else if process.parentPID == 1, ledGroups.contains(process.processGroupID) {
                output.append(KillTarget(process: process, depth: 1, state: .ready,
                                         reason: "Started \(startedWhen); its parent has already exited", rootIdentity: rootIdentity))
            }
        }
        return output
    }

    /// Hops to the nearest anchor, through newborns only: a child of a
    /// process the stop leaves alone is not the stop's to take.
    private static func depth(
        of process: KillProcessLite,
        arena: KillGraphArena,
        anchorDepths: [ProcessIdentity: Int],
        isNewborn: (KillProcessLite) -> Bool
    ) -> Int? {
        var cursor = process
        for hops in 1...64 {
            guard cursor.parentPID > 1, let parent = arena.processes(for: cursor.parentPID).first else { return nil }
            if let depth = anchorDepths[parent.identity] { return depth + hops }
            guard isNewborn(parent) else { return nil }
            cursor = parent
        }
        return nil
    }

    static func startTime(of process: KillProcessLite) -> TimeInterval {
        Double(process.identity.startTimeSeconds) + Double(process.identity.startTimeMicroseconds) / 1_000_000
    }
}
