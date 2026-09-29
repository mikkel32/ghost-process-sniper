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
        let words = shell.commandLine.split(whereSeparator: \.isCommandWhitespace)
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

    /// The script a shell runs, as typed: `bash ./build.sh --release` names ./build.sh. A login
    /// shell, `-c`, `-i` and a shell with no operand are a command string or a prompt, not a
    /// script. Options that take a word (`-o pipefail`, `--rcfile file`) do not hand it over,
    /// which `runsCommand` does not check. The command line joins argv with single spaces,
    /// so a script path that contains spaces reads short.
    static func scriptOperand(_ shell: ProcessMetrics) -> String? {
        guard isShell(shell.name), !shell.name.hasPrefix("-") else { return nil }
        var words = shell.commandLine.split(whereSeparator: \.isCommandWhitespace).dropFirst()
        while let word = words.popFirst() {
            if word == "--" { return words.first.map(String.init) }
            guard word.hasPrefix("-") || word.hasPrefix("+") else { return String(word) }
            if word == "--rcfile" || word == "--init-file" {
                _ = words.popFirst()
                continue
            }
            if word.hasPrefix("--") { continue }
            let flags = word.dropFirst()
            if flags.contains("c") || flags.contains("i") { return nil }
            if flags.last == "o" || flags.last == "O" { _ = words.popFirst() }
        }
        return nil
    }

    private static func bareName(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.hasPrefix("-") ? String(lower.dropFirst()) : lower
    }
}
