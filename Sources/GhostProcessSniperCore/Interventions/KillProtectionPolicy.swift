import Darwin
import Foundation

public enum KillProtection: Equatable, Sendable {
    /// Never a target, whatever the plan says.
    case never(String)
    /// A valid target whose stop has a consequence worth saying first.
    case caution(KillRisk)
}

/// The floor under every stop, below ownership: Ghost itself, the processes
/// it runs inside, and the ones whose stop ends the login session. Ownership
/// alone does not cover them, because they all run as the user.
public struct KillProtectionPolicy: Sendable {
    public let selfPID: Int32

    public init(selfPID: Int32 = getpid()) {
        self.selfPID = selfPID
    }

    private static let sessionProcesses: [String: String] = [
        "loginwindow": "Stopping loginwindow logs you out and closes every app without saving. Log out from the Apple menu instead.",
        "WindowServer": "Stopping WindowServer ends the login session and closes every app without saving.",
        "launchd": "launchd starts and supervises everything else; macOS does not survive without it.",
        "kernel_task": "kernel_task is the macOS kernel; it cannot be stopped."
    ]
    private static let relaunchedByMacOS: Set<String> = [
        "Dock", "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter", "WindowManager"
    ]
    private static let terminalBundles = ["/Terminal.app/", "/iTerm.app/", "/Ghostty.app/", "/WezTerm.app/", "/kitty.app/",
                                          "/Alacritty.app/", "/Warp.app/"]
    private static let terminalNames: Set<String> = ["terminal", "iterm2", "ghostty", "wezterm-gui", "kitty", "alacritty", "warp"]
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "dash", "nu", "xonsh", "elvish"]

    public func verdict(
        for process: KillProcessLite,
        executablePath: String?,
        commandLine: String? = nil,
        arena: KillGraphArena
    ) -> KillProtection? {
        verdict(for: process, executablePath: executablePath, commandLine: commandLine, arena: arena,
                selfAndAncestors: selfAndAncestors { arena.processes(for: $0).first?.parentPID })
    }

    /// For the family page, which has a sample rather than an arena: why
    /// the family's root can never be stopped, or nil.
    public func neverReason(forRoot root: ProcessMetrics, in sample: [ProcessMetrics]) -> String? {
        let parents = Dictionary(sample.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        return neverReason(pid: root.pid, name: root.name, isSystemProcess: root.isSystemProcess,
                           selfAndAncestors: selfAndAncestors { parents[$0] })
    }

    /// Ghost's PID and every process above it, which a stop of any of
    /// them would take down mid-way.
    func selfAndAncestors(parentOf: (Int32) -> Int32?) -> Set<Int32> {
        var chain: Set<Int32> = [selfPID]
        var cursor = parentOf(selfPID)
        while let pid = cursor, pid > 1, chain.insert(pid).inserted {
            cursor = parentOf(pid)
        }
        return chain
    }

    func verdict(
        for process: KillProcessLite,
        executablePath: String?,
        commandLine: String?,
        arena: KillGraphArena,
        selfAndAncestors: Set<Int32>
    ) -> KillProtection? {
        if let reason = neverReason(pid: process.pid, name: process.name, isSystemProcess: process.isSystemProcess,
                                    selfAndAncestors: selfAndAncestors) {
            return .never(reason)
        }
        let path = executablePath ?? ""
        if Self.relaunchedByMacOS.contains(process.name) || path.hasPrefix("/System/Library/CoreServices/") {
            return .caution(KillRisk(kind: .respawn, severity: .info, title: "macOS restarts it",
                                     detail: "macOS restarts \(process.name) within a second; the Dock or menu bar may blink."))
        }
        if let what = sessionHost(process, path: path, commandLine: commandLine) {
            let sessions = sessionCount(under: process, arena: arena)
            let them = sessions == 1 ? "it" : "them"
            return .caution(KillRisk(kind: .unsavedWork, severity: .caution, title: "Every session closes",
                                     detail: "Stopping \(what) closes \(sessions) terminal session\(sessions == 1 ? "" : "s") and everything running in \(them)."))
        }
        return nil
    }

    private func neverReason(pid: Int32, name: String, isSystemProcess: Bool, selfAndAncestors: Set<Int32>) -> String? {
        if pid <= 1 {
            return "PID \(pid) belongs to the kernel or launchd; it can never be stopped."
        }
        if pid == selfPID {
            return "This is Ghost Process Sniper itself. Quit it from its menu instead."
        }
        if selfAndAncestors.contains(pid) {
            return "Ghost runs inside \(name); stopping it would stop Ghost mid-way."
        }
        if let reason = Self.sessionProcesses[name] {
            return reason
        }
        return isSystemProcess ? "macOS marks \(name) as a system process." : nil
    }

    /// A terminal app, a tmux or screen server, or a login shell: stopping
    /// it closes every session inside.
    private func sessionHost(_ process: KillProcessLite, path: String, commandLine: String?) -> String? {
        let name = process.name.lowercased()
        if Self.terminalBundles.contains(where: path.contains) || Self.terminalNames.contains(name) {
            return process.name
        }
        if (name == "tmux" || name == "screen") && process.parentPID == 1 {
            return "the \(name) server"
        }
        let argv0 = commandLine?.split(separator: " ").first.map(String.init) ?? process.name
        if argv0.hasPrefix("-"), Self.shells.contains(String(argv0.dropFirst())) {
            return "this login shell"
        }
        return nil
    }

    /// Top-level shells at or under `process`: one per window, tab or pane.
    private func sessionCount(under process: KillProcessLite, arena: KillGraphArena) -> Int {
        let members = arena.descendants(of: process.identity).map(\.process)
        let shellPIDs = Set(members.filter { Self.isShell($0.name) }.map(\.pid))
        let topLevel = members.filter { shellPIDs.contains($0.pid) && !shellPIDs.contains($0.parentPID) }
        return max(1, topLevel.count)
    }

    private static func isShell(_ name: String) -> Bool {
        shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }
}

extension KillRiskAssessment {
    /// The same assessment with protection warnings merged in. A warning
    /// replaces a general one of the same kind, since risks are keyed by kind.
    func merging(_ extra: [KillRisk], headline override: String? = nil) -> KillRiskAssessment {
        guard !extra.isEmpty || override != nil else { return self }
        var merged = risks
        for risk in extra {
            merged.removeAll { $0.kind == risk.kind }
            merged.append(risk)
        }
        return KillRiskAssessment(kind: kind, risks: merged, supervisor: supervisor, appQuitPID: appQuitPID,
                                  graceSeconds: graceSeconds, forceNeedsConfirmation: forceNeedsConfirmation,
                                  freedPorts: freedPorts, headline: override ?? headline,
                                  shutsDownThroughRoot: shutsDownThroughRoot, rootShutdownSignal: rootShutdownSignal)
    }
}
