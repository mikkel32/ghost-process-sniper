import Foundation

/// How a family's root came to be running, from its parent, process group,
/// session and terminal.
public enum LaunchContext: String, Codable, Sendable {
    /// The main executable of an app bundle.
    case appBundle
    /// Started and supervised by launchd: a session leader with no terminal,
    /// or a launchd-managed path.
    case launchdJob
    /// Re-parented to launchd and its session leader (the login shell) is
    /// gone: a job that outlived the terminal it was started from.
    case abandonedTerminalJob
    /// Re-parented to launchd while not leading its own process group: the
    /// process that launched it exited.
    case reparentedOrphan
    /// Parented by launchd with no session evidence; the old path heuristic.
    case detachedFromLauncher
    case terminalForeground
    case terminalBackground
    case childOfLiveProcess

    /// Contexts in which nobody may be looking after the process.
    public var isUnattended: Bool {
        switch self {
        case .abandonedTerminalJob, .reparentedOrphan, .detachedFromLauncher: true
        default: false
        }
    }

    public var fact: String? {
        switch self {
        case .abandonedTerminalJob: "started from a terminal that has since closed"
        case .reparentedOrphan: "re-parented to launchd after its launcher exited"
        case .detachedFromLauncher: "detached from the process that started it"
        case .terminalBackground: "running in the background of a terminal"
        default: nil
        }
    }
}

public enum LaunchContextResolver {
    /// `livePIDs` are the pids alive in the same sample.
    public static func resolve(root: ProcessMetrics, livePIDs: Set<Int32>) -> LaunchContext {
        if LaunchOrigin.isAppMainBinary(path: root.executablePath, name: root.name) {
            return .appBundle
        }
        if root.parentPID == 1 {
            if LaunchOrigin.isLaunchdManaged(path: root.executablePath, commandLine: root.commandLine) {
                return .launchdJob
            }
            if let session = root.sessionID {
                if session == root.pid, root.controllingTerminal == nil {
                    return .launchdJob
                }
                if session != root.pid, !livePIDs.contains(session) {
                    return .abandonedTerminalJob
                }
            }
            if let group = root.processGroupID, group != root.pid {
                return .reparentedOrphan
            }
            if root.controllingTerminal == nil {
                return .detachedFromLauncher
            }
        }
        if root.controllingTerminal != nil {
            let foreground = root.terminalForegroundGroupID != nil && root.terminalForegroundGroupID == root.processGroupID
            return foreground ? .terminalForeground : .terminalBackground
        }
        return .childOfLiveProcess
    }
}
