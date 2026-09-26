import Foundation
import Darwin

extension ProcessFamily {
    /// Largest tree an ad-hoc stop may cover; the stop preview still checks
    /// every member, this only bounds the work for a runaway fork bomb.
    public static let adHocMemberLimit = 256

    /// A family for any live process, tracked or not, so everything search
    /// finds can go through the same stop preview. Returns nil unless the
    /// sample still holds exactly that identity, which guards against a
    /// recycled PID.
    public static func adHoc(
        rootedAt identity: ProcessIdentity,
        in sample: [ProcessMetrics],
        currentUserID: uid_t
    ) -> ProcessFamily? {
        guard let root = sample.first(where: { $0.identity == identity }) else { return nil }
        var childrenByParent: [Int32: [ProcessMetrics]] = [:]
        for process in sample where process.pid != process.parentPID {
            childrenByParent[process.parentPID, default: []].append(process)
        }

        var members = [root]
        var seen: Set<ProcessIdentity> = [root.identity]
        var cursor = 0
        while cursor < members.count, members.count < adHocMemberLimit {
            let parent = members[cursor]
            cursor += 1
            for child in childrenByParent[parent.pid] ?? [] where members.count < adHocMemberLimit {
                // A child cannot start before its parent; older ones hold a recycled parent PID.
                guard child.identity.startTimeSeconds >= parent.identity.startTimeSeconds,
                      seen.insert(child.identity).inserted else { continue }
                members.append(child)
            }
        }

        let userID = UInt32(currentUserID)
        let isOwned: (ProcessMetrics) -> Bool = { $0.userID == userID && !$0.isSystemProcess }
        // Children before their parents, the root last, as tracked families order it.
        let owned = members.dropFirst().reversed().filter(isOwned).map(\.identity) + (isOwned(root) ? [root.identity] : [])
        return ProcessFamily(
            root: root,
            members: members,
            totalResidentMemoryBytes: members.reduce(0) { $0 + $1.residentMemoryBytes },
            totalPhysicalFootprintBytes: members.reduce(0) { $0 + $1.memoryForScoringBytes },
            totalCPUPercent: members.reduce(0) { $0 + $1.cpuPercent },
            totalGPUPercent: members.reduce(0) { $0 + $1.gpuUsagePercent },
            devConfidence: 0,
            commandHints: [root.commandLine].filter { !$0.isEmpty },
            trend: .empty,
            score: GhostScore(value: 0, level: .quiet, reasons: []),
            ownedIdentities: owned,
            protectedPIDs: members.filter { !isOwned($0) }.map(\.pid).sorted(),
            forecast: .quiet
        )
    }
}
