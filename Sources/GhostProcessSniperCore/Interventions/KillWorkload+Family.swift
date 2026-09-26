import Foundation

public extension KillWorkloadProfile {
    /// Captures a family's members and, from the full sample, the chain of
    /// processes above its root, where supervisors such as nodemon live.
    init(family: ProcessFamily, sample: [ProcessMetrics]) {
        let members = [family.root] + family.members.filter { $0.identity != family.root.identity }
        let processes = members.map { process in
            KillWorkloadProcess(
                pid: process.pid,
                parentPID: process.parentPID,
                name: process.name,
                executablePath: process.executablePath,
                commandLine: process.commandLine,
                listeningPorts: process.forensics.listeningPorts,
                isRoot: process.identity == family.root.identity
            )
        }
        let byPID = Dictionary(sample.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var ancestors: [KillWorkloadAncestor] = []
        var cursor = family.root.parentPID
        var visited: Set<Int32> = [family.root.pid]
        while cursor > 1, ancestors.count < 8, let parent = byPID[cursor], visited.insert(parent.pid).inserted {
            ancestors.append(KillWorkloadAncestor(pid: parent.pid, name: parent.name,
                                                  executablePath: parent.executablePath, commandLine: parent.commandLine))
            cursor = parent.parentPID
        }
        self.init(processes: processes, ancestors: ancestors, parentIsLaunchd: family.root.parentPID == 1)
    }
}
