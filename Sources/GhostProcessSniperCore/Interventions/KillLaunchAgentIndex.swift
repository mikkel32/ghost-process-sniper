import Foundation

/// One launchd job definition read from a plist on disk.
public struct KillLaunchAgent: Equatable, Sendable {
    public let label: String
    public let plistPath: String
    /// The canonical path of Program or ProgramArguments[0], if absolute.
    public let program: String?
    /// KeepAlive is true or a dictionary of conditions: launchd starts the
    /// job again after it exits.
    public let keepAlive: Bool
    public let runAtLoad: Bool
    /// From a LaunchDaemons folder: a system-domain job.
    public let isDaemon: Bool

    public init(label: String, plistPath: String, program: String?, keepAlive: Bool, runAtLoad: Bool, isDaemon: Bool) {
        self.label = label
        self.plistPath = plistPath
        self.program = program
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.isDaemon = isDaemon
    }
}

/// The LaunchAgents and LaunchDaemons plists, by label and by the program
/// they run. `brew services` jobs live here, so a database that launchd
/// restarts can be told apart from an orphan. Parsed once and reparsed only
/// when a plist is added, removed or rewritten.
public final class KillLaunchAgentIndex: @unchecked Sendable {
    public struct Directory: Equatable, Sendable {
        public let path: String
        public let isDaemon: Bool

        public init(path: String, isDaemon: Bool) {
            self.path = path
            self.isDaemon = isDaemon
        }
    }

    public static let shared = KillLaunchAgentIndex(directories: defaultDirectories)

    public static var defaultDirectories: [Directory] {
        [
            Directory(path: NSHomeDirectory() + "/Library/LaunchAgents", isDaemon: false),
            Directory(path: "/Library/LaunchAgents", isDaemon: false),
            Directory(path: "/Library/LaunchDaemons", isDaemon: true)
        ]
    }

    /// Launchers whose path says nothing about the job they start.
    private static let genericPrograms: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "env", "open", "osascript", "python", "python3", "node", "ruby", "perl", "java"
    ]

    private struct Contents {
        let stamp: [String: Date]
        let byLabel: [String: KillLaunchAgent]
        let byProgram: [String: KillLaunchAgent]
    }

    private let directories: [Directory]
    private let lock = NSLock()
    private var contents: Contents?

    public init(directories: [Directory]) {
        self.directories = directories
    }

    public func agent(label: String) -> KillLaunchAgent? {
        current().byLabel[label]
    }

    /// The job whose program is this executable, following symlinks on
    /// both sides: the plist names /opt/homebrew/opt/<formula>/bin/<daemon>
    /// while the process reports its Cellar path.
    public func agent(forExecutable path: String) -> KillLaunchAgent? {
        guard path.hasPrefix("/") else { return nil }
        return current().byProgram[Self.canonicalPath(path)]
    }

    private func current() -> Contents {
        let files = plistFiles()
        let stamp = Dictionary(files.map { ($0.path, $0.modified) }, uniquingKeysWith: { first, _ in first })
        if let cached = lock.withLock({ contents }), cached.stamp == stamp {
            return cached
        }
        let fresh = Self.parse(files)
        let built = Contents(stamp: stamp, byLabel: fresh.byLabel, byProgram: fresh.byProgram)
        lock.withLock { contents = built }
        return built
    }

    private func plistFiles() -> [(path: String, modified: Date, isDaemon: Bool)] {
        let manager = FileManager.default
        return directories.flatMap { directory -> [(path: String, modified: Date, isDaemon: Bool)] in
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
            return names.filter { $0.hasSuffix(".plist") }.map { name in
                let path = directory.path + "/" + name
                let modified = (try? manager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                return (path, modified, directory.isDaemon)
            }
        }
    }

    private static func parse(
        _ files: [(path: String, modified: Date, isDaemon: Bool)]
    ) -> (byLabel: [String: KillLaunchAgent], byProgram: [String: KillLaunchAgent]) {
        var byLabel: [String: KillLaunchAgent] = [:]
        var byProgram: [String: KillLaunchAgent] = [:]
        var ambiguous: Set<String> = []
        for file in files {
            guard let agent = agent(atPath: file.path, isDaemon: file.isDaemon) else { continue }
            // A user agent overrides a system one with the same label.
            if byLabel[agent.label] == nil { byLabel[agent.label] = agent }
            guard let program = agent.program else { continue }
            if byProgram[program] != nil {
                ambiguous.insert(program)
            } else {
                byProgram[program] = agent
            }
        }
        // Two jobs running the same binary cannot tell which one owns a process.
        for program in ambiguous { byProgram[program] = nil }
        return (byLabel, byProgram)
    }

    static func agent(atPath path: String, isDaemon: Bool) -> KillLaunchAgent? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else {
            return nil
        }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let canonical = program.flatMap { path -> String? in
            guard path.hasPrefix("/") else { return nil }
            let resolved = canonicalPath(path)
            let name = (resolved as NSString).lastPathComponent
            return genericPrograms.contains(name) || name.hasPrefix("python") ? nil : resolved
        }
        let keepAlive: Bool = switch plist["KeepAlive"] {
        case let flag as Bool: flag
        case is [String: Any]: true
        default: false
        }
        return KillLaunchAgent(label: label, plistPath: path, program: canonical, keepAlive: keepAlive,
                               runAtLoad: plist["RunAtLoad"] as? Bool ?? false, isDaemon: isDaemon)
    }

    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
