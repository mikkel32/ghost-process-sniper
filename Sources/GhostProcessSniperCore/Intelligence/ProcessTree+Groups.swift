import Foundation

extension ProcessTree {
    /// Roots of apps whose processes add up to the gate although none does
    /// alone: a browser or chat app spread over many mid-size helpers. The
    /// per-process gate never sees such an app, yet the score reads the whole
    /// of it, so the two would disagree about the biggest things on the Mac.
    ///
    /// Only processes no family holds yet are looked at, so a group never
    /// takes members from a family, and each group is checked against the
    /// membership it would really get. There is no hysteresis: an app that
    /// hovers at the gate enters and leaves as it opens and closes tabs,
    /// exactly as a single process hovering at the per-process gate does.
    ///
    /// - Parameters:
    ///   - covered: pids of the processes already in a family.
    ///   - rootIdentities: the roots of those families.
    func groupRoots(
        of processes: [ProcessMetrics],
        userID: UInt32,
        memoryGate: UInt64,
        covered: Set<Int32>,
        rootIdentities: Set<ProcessIdentity>
    ) -> [ProcessMetrics] {
        // Same user and not a zombie, as a family's stop plan needs.
        func eligible(_ process: ProcessMetrics) -> Bool {
            process.userID == userID && !process.isSystemProcess && !process.isZombie && !covered.contains(process.pid)
        }

        var sums: [Int32: (root: ProcessMetrics, bytes: UInt64, count: Int)] = [:]
        for process in processes where eligible(process) {
            // With no parent to climb to a process is its own root: it joins
            // a sum below when a child reaches it, and adds nothing alone.
            guard helperOwners[process.pid] != nil || process.parentPID > 1 else { continue }
            let root = self.root(for: process)
            guard root.pid != process.pid, eligible(root) else { continue }
            var group = sums[root.pid] ?? (root, root.memoryForScoringBytes, 1)
            group.bytes += process.memoryForScoringBytes
            group.count += 1
            sums[root.pid] = group
        }

        let candidates = sums.values.filter { $0.count >= 2 && $0.bytes >= memoryGate }.map(\.root)
        guard !candidates.isEmpty else { return [] }
        // Climbing and owning can differ for a child that is a workload of
        // its own, so the gate is judged on what the family would hold.
        let boundaries = rootIdentities.union(candidates.map(\.identity))
        return candidates.filter { root in
            let live = members(of: root, rootIdentities: boundaries).filter { !$0.isZombie }
            return live.count >= 2 && live.reduce(UInt64(0)) { $0 + $1.memoryForScoringBytes } >= memoryGate
        }
    }
}
