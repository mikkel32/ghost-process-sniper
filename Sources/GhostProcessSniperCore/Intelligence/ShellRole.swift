import Foundation

/// Tells a shell someone types into from the `sh -c` a build tool runs each
/// recipe through. make, ninja and npm start every command that way, so a
/// shell is a job or copy boundary only when it is interactive; a recipe
/// shell belongs to whatever ran it.
enum ShellRole {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "xonsh"]
    /// Processes that start interactive sessions: whatever shell they run
    /// is someone's prompt.
    static let sessionHosts: Set<String> = ["login", "sshd", "sshd-session", "tmux", "screen"]

    static func isShell(_ name: String) -> Bool {
        shells.contains(bareName(name))
    }

    static func isSessionHost(_ name: String) -> Bool {
        sessionHosts.contains(bareName(name))
    }

    /// A shell running a command string or script for a launcher above it.
    /// Process group and terminal cannot tell this: ninja puts each recipe
    /// in its own group, and make's recipes share its foreground terminal.
    static func isRecipeShell(_ shell: ProcessMetrics, launcher: ProcessMetrics?) -> Bool {
        guard isShell(shell.name), runsCommand(shell), let launcher, shell.parentPID > 1 else { return false }
        return !isShell(launcher.name) && !isSessionHost(launcher.name) && !launcher.executablePath.contains(".app/")
    }

    /// `-c` or a script operand, and neither a login shell nor `-i`.
    static func runsCommand(_ shell: ProcessMetrics) -> Bool {
        guard !shell.name.hasPrefix("-") else { return false }
        let words = shell.commandLine.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, !first.hasPrefix("-") else { return false }
        for word in words.dropFirst() {
            if word == "--" { return true }
            guard word.hasPrefix("-") || word.hasPrefix("+") else { return true }
            if word.hasPrefix("--") { continue }
            let flags = word.dropFirst()
            if flags.contains("i") { return false }
            if flags.contains("c") { return true }
        }
        return false
    }

    private static func bareName(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.hasPrefix("-") ? String(lower.dropFirst()) : lower
    }
}
