import Foundation

/// One process a stop would touch, captured when the plan is made. The kill
/// snapshot deliberately skips paths and command lines to stay fast; the
/// risk assessor needs them to know what the process actually is.
public struct KillWorkloadProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let executablePath: String
    public let commandLine: String
    public let listeningPorts: [Int]
    public let isRoot: Bool
    /// Pins the radar's numbers to this exact process, not a PID reused since.
    public let identity: ProcessIdentity?
    /// CPU over the last radar scan; the kill snapshot cannot measure it.
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public init(
        pid: Int32,
        parentPID: Int32 = 0,
        name: String,
        executablePath: String,
        commandLine: String,
        listeningPorts: [Int] = [],
        isRoot: Bool = false,
        identity: ProcessIdentity? = nil,
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.listeningPorts = listeningPorts
        self.isRoot = isRoot
        self.identity = identity
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// A process above the root, nearest first: the place a supervisor such as
/// nodemon or pm2 hides.
public struct KillWorkloadAncestor: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let executablePath: String
    public let commandLine: String

    public init(pid: Int32, name: String, executablePath: String, commandLine: String) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine
    }
}

public struct KillWorkloadProfile: Equatable, Sendable {
    /// Root first, then helpers.
    public let processes: [KillWorkloadProcess]
    /// Nearest parent first, stopping before launchd.
    public let ancestors: [KillWorkloadAncestor]
    public let parentIsLaunchd: Bool

    public static let empty = KillWorkloadProfile(processes: [], ancestors: [], parentIsLaunchd: false)

    public init(processes: [KillWorkloadProcess], ancestors: [KillWorkloadAncestor], parentIsLaunchd: Bool) {
        self.processes = processes
        self.ancestors = ancestors
        self.parentIsLaunchd = parentIsLaunchd
    }

    public var root: KillWorkloadProcess? {
        processes.first(where: \.isRoot) ?? processes.first
    }

    /// The same context narrowed to one process, for single-process stops.
    /// Family members above it become ancestors, so stopping the `node`
    /// child of `nodemon` still sees the supervisor that will restart it.
    public func restricted(to pid: Int32) -> KillWorkloadProfile {
        guard let process = processes.first(where: { $0.pid == pid }) else { return self }
        let single = KillWorkloadProcess(
            pid: process.pid,
            parentPID: process.parentPID,
            name: process.name,
            executablePath: process.executablePath,
            commandLine: process.commandLine,
            listeningPorts: process.listeningPorts,
            isRoot: true,
            identity: process.identity,
            cpuPercent: process.cpuPercent,
            memoryBytes: process.memoryBytes
        )
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [KillWorkloadAncestor] = []
        var cursor = process.parentPID
        var visited: Set<Int32> = [process.pid]
        while let parent = byPID[cursor], visited.insert(parent.pid).inserted {
            chain.append(KillWorkloadAncestor(pid: parent.pid, name: parent.name,
                                              executablePath: parent.executablePath, commandLine: parent.commandLine))
            cursor = parent.parentPID
        }
        let isRootOfFamily = process.pid == root?.pid
        return KillWorkloadProfile(
            processes: [single],
            ancestors: chain + ancestors,
            parentIsLaunchd: isRootOfFamily ? parentIsLaunchd : process.parentPID == 1
        )
    }
}
