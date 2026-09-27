import Darwin
import Foundation

/// Something macOS starts automatically: a launch agent or daemon.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable {
        case userAgent
        case systemAgent
        case systemDaemon

        public var label: String {
            switch self {
            case .userAgent: "Starts when you log in"
            case .systemAgent: "Starts for every user"
            case .systemDaemon: "Runs as root at startup"
            }
        }
    }

    public let id: String
    public let plistPath: String
    public let label: String
    public let scope: Scope
    public let programPath: String
    public let arguments: [String]
    public let runsAtLoad: Bool
    public let keepsAlive: Bool
    public let modified: Date?
    /// Appeared while Ghost was running, as opposed to found at launch.
    public let isNew: Bool
    public var signals: [SentinelSignal]
    public var signing: CodeSigningSummary?

    public var severity: SentinelSeverity { signals.map(\.severity).max() ?? .info }

    public var commandLine: String {
        ([programPath] + arguments.dropFirst()).joined(separator: " ")
    }
}

/// Reads every launch agent and daemon, and watches their folders so a new
/// one is seen the moment it is written. A new startup item is how most Mac
/// malware survives a restart; installers add them too, so each is judged by
/// what it runs and from where.
final class PersistenceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GhostProcessSniper.sentinel.persistence", qos: .utility)
    private let onNewItem: @Sendable () -> Void
    private let folders: [(path: String, scope: LaunchItem.Scope)]

    // Confined to `queue`.
    private var sources: [DispatchSourceFileSystemObject] = []
    private var items: [String: LaunchItem] = [:]
    private var knownAtStart: Set<String>?
    private var generation: UInt64 = 0
    private var lastFullScan = Date.distantPast

    static func standardFolders(home: String = NSHomeDirectory()) -> [(path: String, scope: LaunchItem.Scope)] {
        [
            (home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .systemAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
    }

    init(folders: [(path: String, scope: LaunchItem.Scope)] = PersistenceMonitor.standardFolders(),
         onNewItem: @escaping @Sendable () -> Void = {}) {
        self.folders = folders
        self.onNewItem = onNewItem
    }

    deinit {
        for source in sources { source.cancel() }
    }

    func start() {
        queue.async { [self] in
            scanAll()
            for folder in folders { watch(folder) }
        }
    }

    /// The current items and a number that changes whenever they do.
    func snapshot() -> (items: [LaunchItem], generation: UInt64) {
        queue.sync {
            // A missed event (a folder created later) is caught by a slow rescan.
            if Date().timeIntervalSince(lastFullScan) > 600 { scanAll() }
            return (items.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }, generation)
        }
    }

    // MARK: - Queue-confined

    private func watch(_ folder: (path: String, scope: LaunchItem.Scope)) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                              queue: queue)
        source.setEventHandler { [weak self] in
            // Writers often create then rename; let the folder settle first.
            self?.queue.asyncAfter(deadline: .now() + 0.4) { self?.scan(folder) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    private func scanAll() {
        lastFullScan = Date()
        for folder in folders { scan(folder) }
        if knownAtStart == nil { knownAtStart = Set(items.keys) }
    }

    private func scan(_ folder: (path: String, scope: LaunchItem.Scope)) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var present = Set<String>()
        var changed = false
        var sawNew = false
        for name in names where name.hasSuffix(".plist") {
            let path = folder.path + "/" + name
            present.insert(path)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if let existing = items[path], existing.modified == modified { continue }
            let isNew = knownAtStart.map { !$0.contains(path) } ?? false
            guard let item = Self.read(path, scope: folder.scope, modified: modified, isNew: isNew) else { continue }
            items[path] = item
            changed = true
            sawNew = sawNew || isNew
        }
        for path in items.keys where path.hasPrefix(folder.path + "/") && !present.contains(path) {
            items[path] = nil
            changed = true
        }
        if changed { generation &+= 1 }
        if sawNew { onNewItem() }
    }

    static func read(_ path: String, scope: LaunchItem.Scope, modified: Date?, isNew: Bool) -> LaunchItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let label = plist["Label"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? arguments.first ?? ""
        let keepAlive: Bool = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        var item = LaunchItem(
            id: path, plistPath: path, label: label, scope: scope, programPath: program,
            arguments: arguments.isEmpty ? [program] : arguments, runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepsAlive: keepAlive, modified: modified, isNew: isNew, signals: [], signing: nil)
        item.signals = judge(item)
        return item
    }

    /// What the item runs and from where, in the same terms as a process.
    static func judge(_ item: LaunchItem) -> [SentinelSignal] {
        var signals: [SentinelSignal] = []
        let program = item.programPath
        let subject = SentinelSubject(
            identity: ProcessIdentity(pid: 0, startTimeSeconds: 0, startTimeMicroseconds: 0), parentPID: 1, userID: 0,
            name: URL(fileURLWithPath: program).lastPathComponent, executablePath: program,
            commandLine: item.commandLine, isSystemProcess: SentinelCatalog.isSystemLocation(program))
        signals += SentinelRules.locationSignals(subject) { FileManager.default.fileExists(atPath: $0) }
            .map { signal in
                signal.kind == .deletedExecutable
                    ? SentinelSignal(.deletedExecutable, .notable, "Points at a program that does not exist; an uninstall probably left it behind.",
                                     evidence: program)
                    : signal
            }
        if subject.commandIsWorthReading {
            signals += CommandPatterns.signals(commandLine: item.commandLine, program: subject.program)
        }
        let inlineScript = subject.isCommandRunner && item.arguments.dropFirst().contains { ["-c", "-e"].contains($0) }
        if inlineScript {
            signals.append(SentinelSignal(.persistence, .suspicious,
                "Runs an inline \(subject.program) script at startup instead of an installed program.",
                evidence: String(item.commandLine.prefix(200))))
        }
        if item.scope == .userAgent, item.label.lowercased().hasPrefix("com.apple.") {
            signals.append(SentinelSignal(.masquerade, .suspicious,
                "Uses an Apple-style name, but Apple never installs agents in your Library folder.", evidence: item.label))
        }
        if item.isNew {
            signals.append(SentinelSignal(.persistence, .notable,
                "Was added while Ghost was running; it will start \(item.scope == .userAgent ? "at every login" : "at every startup").",
                evidence: item.plistPath))
        }
        return signals
    }
}
