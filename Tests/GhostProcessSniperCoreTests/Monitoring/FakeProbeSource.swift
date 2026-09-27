import Foundation
@testable import GhostProcessSniperCore

/// A scripted process table and uptime clock for driving NativeProcessSampler
/// tick by tick without touching the real kernel.
final class FakeProbeSource: ProcessProbeSource, @unchecked Sendable {
    struct Process {
        var pid: Int32
        var name: String
        var start: UInt64 = 1_700_000_000
        var userID: UInt32 = 501
        var parentPID: Int32 = 1
        var openFiles = 8
        var path: String?
        var arguments: String?
        var cpuSeconds: Double = 0
        var footprint: UInt64 = 64 << 20
        var energyNanojoules: UInt64 = 0
        var wakeups: UInt64 = 0
        var diskBytesWritten: UInt64 = 0
        var threads = 4
        var ports: Set<Int> = []
        var sessionID: Int32?
        var terminal: UInt32?
        var terminalForegroundGroup: Int32?
        var startStamp: UInt64 = 0
        var usageDenied = false
        var bsdDenied = false
        var gone = false
    }

    struct Calls: Equatable {
        var bsd = 0
        var usage = 0
        var taskInfo = 0
        var path = 0
        var arguments = 0
        var forensics = 0
        var ports = 0
        var sessionID = 0
    }

    private let lock = NSLock()
    private var order: [Int32] = []
    private var table: [Int32: Process] = [:]
    private var clock: UInt64 = 1_000_000_000_000
    private var calls = Calls()
    private var clockJump: (afterBSDReads: Int, nanoseconds: UInt64)?
    /// Simulated syscall cost: each path or argv read advances the clock.
    private var readCost: (path: UInt64, arguments: UInt64) = (0, 0)
    /// A pid's usage read reports this process instead, as if the pid were
    /// reused between the BSD and usage reads.
    private var usageImpostors: [Int32: Process] = [:]
    let effectiveUserID: UInt32 = 501

    init(_ processes: [Process] = []) {
        for process in processes { insert(process) }
    }

    static func table(count: Int, firstPID: Int32 = 1_000, name: (Int) -> String = { "app-\($0)" }) -> FakeProbeSource {
        FakeProbeSource((0..<count).map { Process(pid: firstPID + Int32($0), name: name($0)) })
    }

    var recordedCalls: Calls { locked { calls } }

    func resetCalls() { locked { calls = Calls() } }

    func advance(seconds: Double) {
        locked { clock += UInt64(seconds * 1_000_000_000) }
    }

    /// Jumps the clock once the given number of BSD reads have happened, to
    /// expire a tick's deadline mid-pass.
    func jumpClock(afterBSDReads reads: Int, by seconds: Double) {
        locked { clockJump = (reads, UInt64(seconds * 1_000_000_000)) }
    }

    func setReadCost(pathMicroseconds: UInt64, argumentsMicroseconds: UInt64) {
        locked { readCost = (pathMicroseconds * 1_000, argumentsMicroseconds * 1_000) }
    }

    func update(pid: Int32, _ change: (inout Process) -> Void) {
        locked {
            guard var process = table[pid] else { return }
            change(&process)
            table[pid] = process
        }
    }

    func add(_ process: Process) {
        locked { insert(process) }
    }

    func impersonateUsage(of pid: Int32, with process: Process?) {
        locked { usageImpostors[pid] = process }
    }

    func listPIDs(into buffer: inout [pid_t]) throws -> Int {
        let pids = locked { order.filter { table[$0]?.gone == false } }
        if buffer.count < pids.count { buffer = [pid_t](repeating: 0, count: pids.count) }
        for (index, pid) in pids.enumerated() { buffer[index] = pid }
        return pids.count
    }

    func bsd(_ pid: pid_t) -> ProbeBSDRead {
        locked {
            calls.bsd += 1
            if let jump = clockJump, calls.bsd == jump.afterBSDReads { clock += jump.nanoseconds }
            guard let process = find(pid) else { return .missing }
            if process.bsdDenied { return .denied }
            return .record(ProbeBSD(pid: pid, parentPID: process.parentPID, userID: process.userID,
                processGroupID: pid, status: 2, flags: 0, openFileCount: process.openFiles,
                startTimeSeconds: process.start, startTimeMicroseconds: 0, name: process.name,
                controllingTerminal: process.terminal, terminalForegroundGroupID: process.terminalForegroundGroup))
        }
    }

    func usage(_ pid: pid_t) -> ProbeUsage? {
        locked {
            calls.usage += 1
            guard let process = usageImpostors[pid] ?? find(pid), !process.usageDenied else { return nil }
            return ProbeUsage(cpuSeconds: process.cpuSeconds, physicalFootprintBytes: process.footprint,
                residentBytes: process.footprint, wakeups: process.wakeups,
                diskBytesWritten: process.diskBytesWritten, energyNanojoules: process.energyNanojoules,
                processStartAbsoluteTime: process.startStamp != 0 ? process.startStamp : UInt64(process.start) &* 7)
        }
    }

    func taskInfo(_ pid: pid_t) -> ProbeTask? {
        locked {
            calls.taskInfo += 1
            return find(pid).map { ProbeTask(threadCount: $0.threads, virtualBytes: $0.footprint * 4) }
        }
    }

    func sessionID(_ pid: pid_t) -> Int32? {
        locked {
            calls.sessionID += 1
            return find(pid)?.sessionID
        }
    }

    func executablePath(_ pid: pid_t) -> String {
        locked {
            calls.path += 1
            clock += readCost.path
            guard let process = find(pid) else { return "" }
            return process.path ?? "/usr/local/bin/\(process.name)"
        }
    }

    func commandLine(_ pid: pid_t) -> String? {
        locked {
            calls.arguments += 1
            clock += readCost.arguments
            guard let process = find(pid) else { return nil }
            return process.arguments ?? "\(process.name) --serve"
        }
    }

    func forensics(_ pid: pid_t) -> (forensics: ProcessForensics, expensiveCallCount: Int) {
        locked {
            calls.forensics += 1
            let ports = find(pid)?.ports ?? []
            return (ProcessForensics(currentDirectory: "/work", rootDirectory: "/", openFileCount: 8,
                socketCount: ports.count, listeningPorts: ports.sorted(), isPartial: false, notes: []), 3)
        }
    }

    func listeningPorts(_ pid: pid_t) -> Set<Int>? {
        locked {
            calls.ports += 1
            return find(pid)?.ports
        }
    }

    func now() -> UInt64 {
        locked { clock }
    }

    private func find(_ pid: pid_t) -> Process? {
        table[pid].flatMap { $0.gone ? nil : $0 }
    }

    private func insert(_ process: Process) {
        if table[process.pid] == nil { order.append(process.pid) }
        table[process.pid] = process
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

extension SamplingPlan {
    /// A hidden balanced plan at a fixed wall-clock second.
    static func fixture(at second: Double, uiVisible: Bool = false, mutate: (inout SamplingPlan) -> Void = { _ in }) -> SamplingPlan {
        var plan = SamplingPlan.balanced(now: Date(timeIntervalSince1970: 1_000_000 + second))
        plan.uiVisible = uiVisible
        mutate(&plan)
        return plan
    }
}
