import Foundation

/// One tick's process graph with each process's static facts, and the family
/// boundaries drawn over it: which parent a process climbs to, and which
/// descendants a root owns.
struct ProcessTree {
    let byPID: [Int32: ProcessMetrics]
    let children: [Int32: [ProcessMetrics]]
    let facts: [Int32: ProcessStaticFacts]
    let classifications: [Int32: DevClassification]

    init(processes: [ProcessMetrics], facts processFacts: [ProcessStaticFacts]) {
        var byPID: [Int32: ProcessMetrics] = [:]
        var children: [Int32: [ProcessMetrics]] = [:]
        var facts: [Int32: ProcessStaticFacts] = [:]
        var classifications: [Int32: DevClassification] = [:]
        byPID.reserveCapacity(processes.count)
        children.reserveCapacity(processes.count / 2)
        facts.reserveCapacity(processes.count)
        classifications.reserveCapacity(processes.count)
        for (process, processFacts) in zip(processes, processFacts) {
            byPID[process.pid] = process
            children[process.parentPID, default: []].append(process)
            facts[process.pid] = processFacts
            classifications[process.pid] = processFacts.classification
        }
        self.byPID = byPID
        self.children = children
        self.facts = facts
        self.classifications = classifications
    }

    func confidence(_ pid: Int32) -> Double {
        facts[pid]?.classification.confidence ?? 0
    }

    func root(for process: ProcessMetrics) -> ProcessMetrics {
        var current = process
        var visited = Set<Int32>()
        while let parent = byPID[current.parentPID], !visited.contains(parent.pid) {
            visited.insert(current.pid)
            guard parent.userID == current.userID else { break }
            if shouldClimb(from: current, to: parent) {
                current = parent
                continue
            }
            // A recipe shell is transparent: a compiler under make's `sh -c`
            // climbs to make exactly as it would without the shell.
            guard let launcher = byPID[parent.parentPID], !visited.contains(launcher.pid), launcher.userID == current.userID,
                  ShellRole.isRecipeShell(parent, launcher: launcher), shouldClimb(from: current, to: launcher)
            else {
                break
            }
            visited.insert(parent.pid)
            current = launcher
        }
        return current
    }

    /// The root and the descendants it owns, root first. Other candidate
    /// roots are exclusive boundaries.
    func members(of root: ProcessMetrics, rootIdentities: Set<ProcessIdentity>) -> [ProcessMetrics] {
        var result: [ProcessMetrics] = []
        var stack = [root]
        var seen = Set<Int32>()
        let rootIsDevFamily = confidence(root.pid) >= 0.35
        let rootFacts = facts[root.pid]

        while let process = stack.popLast() {
            guard seen.insert(process.pid).inserted else {
                continue
            }
            result.append(process)
            for child in children[process.pid, default: []] {
                guard child.userID == root.userID else {
                    continue
                }
                // Without this, one hot/helper root can repeatedly absorb and
                // traverse another family, producing overlapping trees and
                // O(n²)-like behavior on large process populations.
                guard child.identity == root.identity || !rootIdentities.contains(child.identity) else {
                    continue
                }
                let childFacts = facts[child.pid]
                let related = rootIsDevFamily ||
                    confidence(child.pid) >= 0.2 ||
                    Self.sameAppBundle(childFacts, rootFacts) ||
                    Self.samePathNeighborhood(childFacts, rootFacts)
                guard related else {
                    continue
                }
                stack.append(child)
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.identity == root.identity { return true }
            if rhs.identity == root.identity { return false }
            return lhs.pid < rhs.pid
        }
    }

    /// For each family whose root was launched by a member of another
    /// family (a language server started by an editor), that family's key.
    func parentFamilyKeys(_ memberships: [(familyKey: String, root: ProcessMetrics, members: [ProcessMetrics])]) -> [String: String] {
        var owner: [ProcessIdentity: String] = [:]
        owner.reserveCapacity(memberships.reduce(0) { $0 + $1.members.count })
        for membership in memberships {
            for member in membership.members {
                owner[member.identity] = membership.familyKey
            }
        }
        var result: [String: String] = [:]
        for membership in memberships {
            if let parent = byPID[membership.root.parentPID], let key = owner[parent.identity], key != membership.familyKey {
                result[membership.familyKey] = key
            }
        }
        return result
    }

    func commandHints(for members: [ProcessMetrics]) -> [String] {
        var hints: [String] = []
        for process in members {
            guard let hint = facts[process.pid]?.commandHint ?? nil, !hints.contains(hint) else {
                continue
            }
            hints.append(hint)
            if hints.count == 4 {
                break
            }
        }
        return hints
    }

    private func shouldClimb(from child: ProcessMetrics, to parent: ProcessMetrics) -> Bool {
        let childFacts = facts[child.pid]
        let parentFacts = facts[parent.pid]
        if Self.isOwnWorkload(childFacts), Self.isWorkloadHost(parentFacts), !Self.isSameApp(childFacts, parentFacts) {
            return false
        }
        if confidence(parent.pid) >= 0.35 {
            return true
        }
        if Self.sameAppBundle(childFacts, parentFacts) {
            return true
        }
        return parentFacts?.isHelperNamed == true && Self.samePathNeighborhood(childFacts, parentFacts)
    }

    /// Servers, kernels and test or build workers an editor launches are
    /// their own families: a leaking language server must not surface as the
    /// editor, nor make the editor its only stop. Kinds, not sizes, draw the
    /// line, so membership never flips between ticks.
    private static func isOwnWorkload(_ facts: ProcessStaticFacts?) -> Bool {
        guard let classification = facts?.classification else { return false }
        return classification.kind.isServiceKind ||
            !classification.traits.isDisjoint(with: [.devServer, .notebookKernel])
    }

    private static func isWorkloadHost(_ facts: ProcessStaticFacts?) -> Bool {
        guard let facts else { return false }
        switch facts.classification.kind {
        case .editorApp, .ideService, .electronApp:
            return true
        default:
            return facts.isAppMainBinary
        }
    }

    /// A helper of the app itself: same bundle and, because the catalog can
    /// name a whole bundle one kind, the same kind. A server the app runs
    /// from inside its bundle (an editor's bundled tsserver) differs in kind.
    private static func isSameApp(_ child: ProcessStaticFacts?, _ parent: ProcessStaticFacts?) -> Bool {
        sameAppBundle(child, parent) && child?.classification.kind == parent?.classification.kind
    }

    private static func sameAppBundle(_ lhs: ProcessStaticFacts?, _ rhs: ProcessStaticFacts?) -> Bool {
        guard let left = lhs?.appBundlePrefix, let right = rhs?.appBundlePrefix else {
            return false
        }
        return left == right
    }

    private static func samePathNeighborhood(_ lhs: ProcessStaticFacts?, _ rhs: ProcessStaticFacts?) -> Bool {
        guard let left = lhs?.parentDirectory, !left.isEmpty else { return false }
        return left == rhs?.parentDirectory
    }
}
