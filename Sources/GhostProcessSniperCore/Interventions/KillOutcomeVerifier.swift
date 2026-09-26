import Foundation

public protocol ListeningPortProbing: Sendable {
    /// The TCP ports the process listens on; nil when its descriptors
    /// cannot be read.
    func ports(pid: Int32) -> Set<Int>?
}

/// What became of a port the stopped workload was listening on.
public enum KillPortOutcome: Equatable, Sendable {
    case freed(Int)
    /// Still listened on by a process outside the stop, typically a child
    /// that escaped the tree with the inherited socket.
    case heldBy(port: Int, pid: Int32, name: String, startedDuringStop: Bool)
    /// No holder was found, but not every likely holder could be checked.
    case unverified(Int)

    public var port: Int {
        switch self {
        case .freed(let port), .unverified(let port), .heldBy(let port, _, _, _): port
        }
    }

    public var holderPID: Int32? {
        if case .heldBy(_, let pid, _, _) = self { return pid }
        return nil
    }

    public var text: String {
        switch self {
        case .freed(let port):
            "Port \(port) is free."
        case .heldBy(let port, let pid, let name, let startedDuringStop):
            "Port \(port) is still held by \(name) (PID \(pid))\(startedDuringStop ? ", started during the stop" : "")."
        case .unverified(let port):
            "Port \(port) should now be free."
        }
    }
}

/// Checks that a stop achieved what it promised. Once every target exited
/// their sockets are closed, so a port can only still be held by a process
/// outside the stop. Scanning every process's descriptors is too slow, so
/// only the likely holders are read, most likely first, within a budget.
public struct KillOutcomeVerifier: Sendable {
    public init() {}

    public func verifyPorts(
        _ ports: [Int],
        arena: KillGraphArena,
        stopped: Set<ProcessIdentity>,
        stoppedNames: Set<String>,
        targetGroups: Set<Int32>,
        operationStart: Date,
        currentUserID: UInt32,
        probe: ListeningPortProbing,
        maxProcesses: Int = 64,
        budget: TimeInterval = 0.03
    ) -> [KillPortOutcome] {
        let wanted = Array(Set(ports)).sorted()
        guard !wanted.isEmpty else { return [] }
        let candidates = Self.candidates(arena: arena, stopped: stopped, stoppedNames: stoppedNames,
                                         targetGroups: targetGroups, operationStart: operationStart,
                                         currentUserID: currentUserID)
        let started = Self.startSeconds(operationStart)
        let clock = Date()
        var holders: [Int: KillPortOutcome] = [:]
        var complete = true
        for (scanned, process) in candidates.enumerated() {
            guard holders.count < wanted.count else { break }
            guard scanned < maxProcesses, Date().timeIntervalSince(clock) < budget else {
                complete = false
                break
            }
            guard let listening = probe.ports(pid: process.pid) else {
                complete = false
                continue
            }
            for port in wanted where holders[port] == nil && listening.contains(port) {
                holders[port] = .heldBy(port: port, pid: process.pid, name: process.name,
                                        startedDuringStop: process.identity.startTimeSeconds >= started)
            }
        }
        return wanted.map { port in
            holders[port] ?? (complete ? .freed(port) : .unverified(port))
        }
    }

    /// Escaped members of the stopped process groups (orphans first), then
    /// anything started during the stop (newest first), then namesakes of a
    /// stopped target. Only the user's own: those are the ones this stop
    /// could have left behind, and the only ones that can be read.
    static func candidates(
        arena: KillGraphArena,
        stopped: Set<ProcessIdentity>,
        stoppedNames: Set<String>,
        targetGroups: Set<Int32>,
        operationStart: Date,
        currentUserID: UInt32
    ) -> [KillProcessLite] {
        let started = startSeconds(operationStart)
        let groups = targetGroups.filter { $0 > 1 }
        let pool = arena.processes.filter { process in
            process.pid > 1 && process.userID == currentUserID && !stopped.contains(process.identity)
        }
        let inGroup = pool.filter { groups.contains($0.processGroupID) }
            .sorted { ($0.parentPID == 1 ? 0 : 1, -$0.pid) < ($1.parentPID == 1 ? 0 : 1, -$1.pid) }
        let fresh = pool.filter { $0.identity.startTimeSeconds >= started }
            .sorted { $0.identity.startTimeSeconds > $1.identity.startTimeSeconds }
        let namesakes = pool.filter { stoppedNames.contains($0.name) }
            .sorted { $0.pid > $1.pid }
        var seen: Set<ProcessIdentity> = []
        return (inGroup + fresh + namesakes).filter { seen.insert($0.identity).inserted }
    }

    private static func startSeconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970.rounded(.down)))
    }
}
