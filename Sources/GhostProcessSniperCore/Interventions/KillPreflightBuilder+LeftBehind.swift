import Foundation

/// The children of a process stopped on its own. The stop does not touch
/// them, and they lose their parent.
struct KillLeftBehind {
    /// Most children listed and checked afterwards, like the late-member cap.
    static let maxListed = 32

    /// The children to list, nearest first.
    let targets: [KillTarget]
    /// Every child, listed or not, by name in the order first met.
    let groups: [(name: String, count: Int)]

    static let none = KillLeftBehind(targets: [], groups: [])

    var total: Int { groups.reduce(0) { $0 + $1.count } }
}

extension KillPreflightBuilder {
    /// What stopping only the plan's root leaves running: every descendant
    /// of a `singleRoot` plan. A family stop takes them along, and its
    /// deselected children are already `locked`. Zombies have already
    /// exited, and nothing below the protection floor is Ghost's to talk about.
    func leftBehind(plan: KillPlan, arena: KillGraphArena, appQuits: Bool) -> KillLeftBehind {
        guard plan.scope == .singleRoot else { return .none }
        let chain = protection.selfAndAncestors { arena.processes(for: $0).first?.parentPID }
        let children = arena.descendants(of: plan.rootIdentity).dropFirst().filter { member in
            guard !member.process.isZombie else { return false }
            if case .never = protection.verdict(for: member.process, executablePath: nil, commandLine: nil,
                                                arena: arena, selfAndAncestors: chain) { return false }
            return true
        }
        .sorted { ($0.depth, $0.process.pid) < ($1.depth, $1.process.pid) }
        // A quitting app closes its own helpers; the check afterwards still looks.
        let reason = appQuits
            ? "Not signalled; an app's helpers normally exit when it quits"
            : "Not part of this stop; may keep running without its parent"
        var groups: [(name: String, count: Int)] = []
        for child in children {
            if let index = groups.firstIndex(where: { $0.name == child.process.name }) {
                groups[index].count += 1
            } else {
                groups.append((child.process.name, 1))
            }
        }
        return KillLeftBehind(
            targets: children.prefix(KillLeftBehind.maxListed).map {
                KillTarget(process: $0.process, depth: $0.depth, state: .locked, reason: reason, rootIdentity: plan.rootIdentity)
            },
            groups: groups
        )
    }

    /// The card for a stop that leaves children running, or nil when it
    /// leaves none. A note for one helper; a caution when the stopped
    /// process is its family's root and every other process of the family
    /// is left behind.
    func leavesChildrenRisk(_ children: KillLeftBehind, plan: KillPlan) -> KillRisk? {
        let total = children.total
        guard total > 0 else { return nil }
        let wholeFamily = plan.familyMetadata.map { $0.childCount > 0 && total >= $0.childCount } ?? false
        let names = children.groups.prefix(3).map { $0.count > 1 ? "\($0.name) (\($0.count))" : $0.name }
        let more = children.groups.count - names.count
        let parts = more > 0 ? names + ["\(more) more"] : names
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1] : parts.joined()
        return KillRisk(
            kind: .leavesChildren,
            severity: wholeFamily ? .caution : .info,
            title: total == 1 ? "1 child process is not stopped" : "\(total) child processes are not stopped",
            detail: "\(list) \(total == 1 ? "loses its" : "lose their") parent and may keep running, still holding memory and ports."
        )
    }
}
