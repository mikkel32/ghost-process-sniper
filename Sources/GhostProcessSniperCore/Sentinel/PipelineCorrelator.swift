import Foundation

/// Puts a pasted pipeline back together. `curl -fsSL https://x | sh` typed
/// into a terminal becomes two processes whose arguments never contain the
/// `|`: curl, and a bare `sh` reading its standard input. The shell starts
/// both as siblings in one process group within a moment of each other,
/// which is how they are recognised as one command again.
struct PipelineCorrelator: Sendable {
    enum Role: Sendable {
        /// curl or wget writing the download to standard output.
        case downloader
        /// A decoder or decompressor between the download and the runner.
        case filter
        /// A shell or interpreter running whatever arrives on standard input.
        case stdinRunner
    }

    struct Member: Sendable {
        let identity: ProcessIdentity
        let parentPID: Int32
        let processGroupID: Int32
        let commandLine: String
        let role: Role
        let seen: Date

        var started: Double {
            Double(identity.startTimeSeconds) + Double(identity.startTimeMicroseconds) / 1_000_000
        }
    }

    /// The runner of a completed pipeline, and the pipeline as one command.
    struct Pipeline: Equatable, Sendable {
        let runner: ProcessIdentity
        let text: String
        let processCount: Int
    }

    /// A pipeline's processes start within this many seconds of each other.
    static let startWindow: TimeInterval = 2
    static let retention: TimeInterval = 60
    static let capacity = 256

    private var members: [Member] = []

    /// Notes a process; returns every pipeline it completes.
    mutating func observe(_ subject: SentinelSubject, now: Date) -> [Pipeline] {
        guard let group = subject.processGroupID, group > 0, let role = Self.role(of: subject) else { return [] }
        members.removeAll { $0.identity == subject.identity }
        members.append(Member(identity: subject.identity, parentPID: subject.parentPID, processGroupID: group,
                              commandLine: subject.commandLine, role: role, seen: now))
        if members.count > Self.capacity { members.removeFirst(members.count - Self.capacity) }
        let newest = members[members.count - 1]
        let siblings = members
            .filter { $0.parentPID == newest.parentPID && $0.processGroupID == group &&
                abs($0.started - newest.started) <= Self.startWindow }
            .sorted { $0.started == $1.started ? $0.identity.pid < $1.identity.pid : $0.started < $1.started }
        guard let first = siblings.first(where: { $0.role == .downloader }) else { return [] }
        let text = siblings.filter { $0.started >= first.started }.map(\.commandLine).joined(separator: " | ")
        let count = siblings.filter { $0.started >= first.started }.count
        return siblings
            .filter { $0.role == .stdinRunner && $0.started >= first.started }
            .map { Pipeline(runner: $0.identity, text: text, processCount: count) }
    }

    mutating func prune(now: Date) {
        members.removeAll { now.timeIntervalSince($0.seen) > Self.retention }
    }

    // MARK: - Roles

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh"]
    static let interpreters: Set<String> = ["python", "python2", "python3", "perl", "ruby", "node", "php", "osascript", "bun", "deno"]

    static func role(of subject: SentinelSubject) -> Role? {
        role(words: subject.commandLine.split(separator: " ").map(String.init), program: subject.program.lowercased())
    }

    static func role(words: [String], program: String) -> Role? {
        let arguments = Array(words.dropFirst())
        switch program {
        case "curl":
            return curlWritesToStdout(arguments) ? .downloader : nil
        case "wget":
            return wgetWritesToStdout(arguments) ? .downloader : nil
        case "base64", "b64":
            return arguments.contains { ["-d", "-D", "--decode"].contains($0) } ? .filter : nil
        case "openssl":
            return arguments.contains("-d") ? .filter : nil
        case "xxd":
            return arguments.contains { $0.hasPrefix("-r") } ? .filter : nil
        case "gunzip", "zcat", "bunzip2", "unxz":
            return .filter
        case "gzip", "bzip2", "xz":
            return arguments.contains { $0 == "-d" || $0 == "-dc" || $0 == "--decompress" } ? .filter : nil
        case "sudo", "env":
            // Transparent wrappers: what they run decides.
            let rest = unwrapped(arguments, wrapper: program)
            guard let next = rest.first else { return nil }
            let name = (next as NSString).lastPathComponent.lowercased()
            return role(words: rest, program: name) == .stdinRunner ? .stdinRunner : nil
        default:
            if shells.contains(program) { return shellReadsStdin(arguments) ? .stdinRunner : nil }
            if interpreters.contains(program) || program.hasPrefix("python") {
                return interpreterReadsStdin(arguments) ? .stdinRunner : nil
            }
            return nil
        }
    }

    /// No `-o file`, `-O` or `--output file`; `-o -` still writes to stdout.
    static func curlWritesToStdout(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            let toStdout = arguments.indices.contains(index + 1) && arguments[index + 1] == "-"
            if argument == "-o" || argument == "--output" {
                if toStdout { continue }
                return false
            }
            if argument.hasPrefix("--output=") { return argument == "--output=-" }
            if argument == "-O" || argument.hasPrefix("--remote-name") { return false }
            // Clustered short flags such as -fsSLo or -sO.
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 {
                if argument.contains("O") || (argument.hasSuffix("o") && !toStdout) { return false }
            }
        }
        return true
    }

    /// wget saves to a file unless told `-O -` (often written `-qO-`).
    static func wgetWritesToStdout(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if argument == "--output-document=-" || (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.hasSuffix("O-")) {
                return true
            }
            if argument == "-O" || argument == "--output-document" || (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.hasSuffix("O")) {
                return arguments.indices.contains(index + 1) && arguments[index + 1] == "-"
            }
        }
        return false
    }

    /// A shell with no script and no `-c`: it runs what arrives on stdin.
    /// Words after `-s` or `--` are arguments for that script.
    static func shellReadsStdin(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-s" || argument == "--" || argument == "-" { return true }
            if argument.hasPrefix("--") { continue }
            // `-o pipefail`, `+O extglob`: the next word is the option's name.
            if ["-o", "+o", "-O", "+O"].contains(argument) {
                index += 1
                continue
            }
            if argument.hasPrefix("-") || argument.hasPrefix("+") {
                if argument.dropFirst().contains("c") { return false }
                continue
            }
            return false
        }
        return true
    }

    /// An interpreter with no script, `-c`, `-e` or `-m`, or with `-`.
    static func interpreterReadsStdin(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "-" { return true }
            if ["-c", "-e", "-E", "-m", "-r", "--eval", "--print", "-p"].contains(argument) { return false }
            if argument.hasPrefix("-") { continue }
            return false
        }
        return true
    }

    /// What `sudo` or `env` runs: options, `-u user` and `NAME=value` skipped.
    static func unwrapped(_ arguments: [String], wrapper: String) -> [String] {
        let takesValue: Set<String> = wrapper == "sudo" ? ["-u", "-g", "-C", "-h", "-p", "-U", "-D", "-r", "-t"] : ["-u", "-P"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if wrapper == "env", argument.contains("="), !argument.hasPrefix("-") {
                index += 1
            } else if argument.hasPrefix("-") {
                index += takesValue.contains(argument) ? 2 : 1
            } else {
                break
            }
        }
        return Array(arguments[min(index, arguments.count)...])
    }
}
