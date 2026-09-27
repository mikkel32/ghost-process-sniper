import Darwin
import Foundation

/// One PROC_PIDTBSDINFO read: the identity graph every tick is built from.
struct ProbeBSD: Equatable, Sendable {
    let pid: pid_t
    let parentPID: Int32
    let userID: UInt32
    let processGroupID: Int32
    let status: UInt32
    let flags: UInt32
    let openFileCount: Int
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
    /// Raw `pbi_name`; empty when the kernel has none.
    let name: String
    /// e_tdev; nil when the process has no controlling terminal (NODEV).
    var controllingTerminal: UInt32?
    /// e_tpgid: the terminal's foreground process group.
    var terminalForegroundGroupID: Int32?
}

enum ProbeBSDRead: Equatable, Sendable {
    case record(ProbeBSD)
    /// The kernel refused the read (EPERM): another user's process without privilege.
    case denied
    /// Exited, or a short read.
    case missing
}

/// The per-tick CPU, memory and energy reading (`proc_pid_rusage`, RUSAGE_INFO_V6).
struct ProbeUsage: Equatable, Sendable {
    var cpuSeconds: TimeInterval
    var physicalFootprintBytes: UInt64
    var residentBytes: UInt64
    /// `ri_pkg_idle_wkups`: the wake-ups Activity Monitor calls "Idle Wake Ups".
    var idleWakeups: UInt64
    var diskBytesWritten: UInt64
    /// `ri_energy_nj`; zero where the kernel does not account energy per task.
    var energyNanojoules: UInt64 = 0
    /// `ri_proc_start_abstime`: stable for one process, so a change means the pid was reused.
    var processStartAbsoluteTime: UInt64
    /// Uptime clock at the moment of the read, set by the probe reader.
    var sampledAtUptimeNanoseconds: UInt64 = 0
}

/// Display and kill-snapshot data from PROC_PIDTASKINFO.
struct ProbeTask: Equatable, Sendable {
    var threadCount: Int
    var virtualBytes: UInt64
}

/// Every kernel read the sampler makes, so the whole tick can run against a
/// scripted process table in tests.
protocol ProcessProbeSource: Sendable {
    func listPIDs(into buffer: inout [pid_t]) throws -> Int
    func bsd(_ pid: pid_t) -> ProbeBSDRead
    func usage(_ pid: pid_t) -> ProbeUsage?
    func taskInfo(_ pid: pid_t) -> ProbeTask?
    /// getsid(); nil when the kernel refused.
    func sessionID(_ pid: pid_t) -> Int32?
    func executablePath(_ pid: pid_t) -> String
    func commandLine(_ pid: pid_t) -> String?
    func forensics(_ pid: pid_t) -> (forensics: ProcessForensics, expensiveCallCount: Int)
    func listeningPorts(_ pid: pid_t) -> Set<Int>?
    /// Monotonic nanoseconds that exclude sleep, for CPU deltas and tick deadlines.
    func now() -> UInt64
    var effectiveUserID: UInt32 { get }
}
