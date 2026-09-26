import Foundation

/// The scheduler state the kernel reports for a process (pbi_status).
public enum ProcessRunState: String, Codable, Sendable {
    case running
    case sleeping
    case stopped
    case zombie
    case unknown

    /// SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5.
    public init(bsdStatus: UInt32) {
        switch bsdStatus {
        case 2: self = .running
        case 3: self = .sleeping
        case 4: self = .stopped
        case 5: self = .zombie
        default: self = .unknown
        }
    }
}

/// How a process hangs off its launcher: process group, session and
/// controlling terminal. Shell job control makes every job a group leader,
/// so the session (not the group) tells a terminal job from a launchd job.
public struct ProcessSessionInfo: Equatable, Hashable, Sendable {
    public let processGroupID: Int32?
    /// From getsid(); nil when the kernel refused.
    public let sessionID: Int32?
    /// The tty device; nil without a controlling terminal.
    public let controllingTerminal: UInt32?
    /// The terminal's foreground process group.
    public let terminalForegroundGroupID: Int32?
    public let runState: ProcessRunState

    public static let unknown = ProcessSessionInfo(
        processGroupID: nil,
        sessionID: nil,
        controllingTerminal: nil,
        terminalForegroundGroupID: nil,
        runState: .unknown
    )

    public init(
        processGroupID: Int32?,
        sessionID: Int32?,
        controllingTerminal: UInt32?,
        terminalForegroundGroupID: Int32?,
        runState: ProcessRunState
    ) {
        self.processGroupID = processGroupID
        self.sessionID = sessionID
        self.controllingTerminal = controllingTerminal
        self.terminalForegroundGroupID = terminalForegroundGroupID
        self.runState = runState
    }
}
