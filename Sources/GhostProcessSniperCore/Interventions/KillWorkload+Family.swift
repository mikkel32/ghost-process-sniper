import Foundation

public extension KillWorkloadProfile {
    /// Captures a family's members and, from the full sample, the chain of
    /// processes above its root, where supervisors such as nodemon live.
    init(family: ProcessFamily, sample: [ProcessMetrics]) {
        self.init(root: family.root, sampleIndex: Dictionary(grouping: sample, by: \.parentPID), family: family)
    }

    /// What a stop of `root` will actually hit: every same-user descendant
    /// in the radar sample, not only the family's members. Another family's
    /// database under a task runner still goes down with the runner, so its
    /// risk counts. Like the stop, it does not reach below a process owned
    /// by someone else. `sampleIndex` maps a parent PID to its children.
    init(root: ProcessMetrics, sampleIndex: [Int32: [ProcessMetrics]], family: ProcessFamily) {
        var members = [root]
        var seen: Set<ProcessIdentity> = [root.identity]
        var stack = [root.pid]
        while let pid = stack.popLast(), members.count < 256 {
            for child in sampleIndex[pid] ?? [] where child.userID == root.userID && seen.insert(child.identity).inserted {
                members.append(child)
                stack.append(child.pid)
            }
        }
        for member in family.members where members.count < 256 && seen.insert(member.identity).inserted {
            members.append(member)
        }
        let processes = members.prefix(256).map { process in
            KillWorkloadProcess(
                pid: process.pid,
                parentPID: process.parentPID,
                name: process.name,
                executablePath: process.executablePath,
                commandLine: process.commandLine,
                listeningPorts: process.forensics.listeningPorts,
                isRoot: process.identity == root.identity,
                identity: process.identity,
                cpuPercent: process.cpuPercent,
                memoryBytes: process.memoryForScoringBytes
            )
        }
        let byPID = Dictionary(sampleIndex.values.joined().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var ancestors: [KillWorkloadAncestor] = []
        var cursor = root.parentPID
        var visited: Set<Int32> = [root.pid]
        while cursor > 1, ancestors.count < 8, let parent = byPID[cursor], visited.insert(parent.pid).inserted {
            ancestors.append(KillWorkloadAncestor(pid: parent.pid, name: parent.name,
                                                  executablePath: parent.executablePath, commandLine: parent.commandLine))
            cursor = parent.parentPID
        }
        self.init(processes: processes, ancestors: ancestors, parentIsLaunchd: root.parentPID == 1)
    }
}
