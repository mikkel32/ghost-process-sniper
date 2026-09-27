import Foundation

/// Background work people recognise by what it does, not by its process name.
/// These are explained and never offered as something to stop.
public enum ThermalKnownSource: String, CaseIterable, Equatable, Sendable {
    case virtualMachine, spotlight, photosAnalysis, timeMachine, windowServer

    public var label: String {
        switch self {
        case .virtualMachine: "Linux virtual machine — Docker Desktop, colima, OrbStack, Lima or UTM"
        case .spotlight: "Spotlight indexing"
        case .photosAnalysis: "Photos analysis"
        case .timeMachine: "Time Machine backup"
        case .windowServer: "Screen drawing — many windows, external displays or animations"
        }
    }

    /// The label without its explanation, short enough for a row title.
    public var displayName: String {
        label.components(separatedBy: " — ").first ?? label
    }

    public var cause: String {
        switch self {
        case .virtualMachine: "Containers, builds or services running inside a Linux VM appear as this one process."
        case .spotlight: "macOS is indexing files for search, often after large copies, installs, updates or builds."
        case .photosAnalysis: "Photos is analysing new images and videos for faces, objects and memories."
        case .timeMachine: "A Time Machine backup is copying changed files."
        case .windowServer: "macOS composites every window and display; many windows, external displays or animations raise its load."
        }
    }

    public var advice: String {
        switch self {
        case .virtualMachine:
            "Check which containers or VMs are busy in Docker Desktop, OrbStack, colima, Lima or UTM, stop the ones you don't need, or lower the VM's CPU limit. Stopping this process directly would kill the whole VM."
        case .spotlight:
            "Indexing usually settles on its own. Let it finish, or exclude build and cache folders in System Settings › Spotlight."
        case .photosAnalysis:
            "Analysis pauses by itself and runs best while the Mac is idle and charging. Let it finish while plugged in."
        case .timeMachine:
            "Let the backup finish, or skip it from the Time Machine menu if you need the performance right now."
        case .windowServer:
            "Close unused windows, turn on Reduce Motion or Reduce Transparency, or disconnect an unused display, then compare the next readings."
        }
    }

    static func matching(name: String, executablePath: String) -> Self? {
        let file = String(PathText.lastComponent(executablePath[...]))
        for candidate in [file, name] where !candidate.isEmpty {
            if let source = exactNames[candidate] { return source }
            // proc_name truncates long names; only accept a prefix long enough to be unambiguous.
            if candidate.count >= 30,
               candidate != virtualMachineName, virtualMachineName.hasPrefix(candidate) { return .virtualMachine }
        }
        return nil
    }

    private static let virtualMachineName = "com.apple.Virtualization.VirtualMachine"
    private static let exactNames: [String: Self] = [
        virtualMachineName: .virtualMachine,
        "mds_stores": .spotlight, "mdworker_shared": .spotlight, "mds": .spotlight,
        "photoanalysisd": .photosAnalysis, "mediaanalysisd": .photosAnalysis,
        "backupd": .timeMachine,
        "WindowServer": .windowServer
    ]
}

public enum ThermalWorkloadKind: Equatable, Sendable {
    /// Grouped under an application bundle, its own or its launching ancestor's.
    case app
    /// A command-line job grouped under the process that started it below a shell.
    case job
    case knownSource(ThermalKnownSource)
    /// A standalone process with no shell or app above it.
    case process
}

struct ThermalWorkloadAssignment: Equatable, Sendable {
    let groupKey: String
    let displayName: String
    let applicationPath: String?
    let hostAppName: String?
    let kind: ThermalWorkloadKind
}

/// Attributes each process to the whole job or app that owns it by walking the
/// process tree, so ten compiler children read as one build and helpers with a
/// not-yet-resolved path still join their app. Radar family filters play no part.
struct ThermalWorkloadResolver {
    static let maximumHops = 16
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "login", "tmux", "screen", "nu"]
    private static let terminals: Set<String> = ["terminal", "iterm", "iterm2", "warp", "ghostty", "kitty",
                                                 "alacritty", "wezterm", "hyper"]

    private let processesByPID: [Int32: ProcessMetrics]
    /// The app macOS holds responsible for a launchd-started helper, by identity.
    private let responsiblePIDs: [ProcessIdentity: Int32]
    private var assignments: [ProcessIdentity: ThermalWorkloadAssignment] = [:]
    private var appAssignments: [String: ThermalWorkloadAssignment] = [:]
    /// Parent links followed so far; bounded by maximumHops per resolved process.
    private(set) var visitedHops = 0

    init(processes: [ProcessMetrics], responsiblePIDs: [ProcessIdentity: Int32] = [:]) {
        self.responsiblePIDs = responsiblePIDs
        var byPID: [Int32: ProcessMetrics] = [:]
        byPID.reserveCapacity(processes.count)
        for process in processes {
            // A reused PID can appear twice in one sample; the newer process is the live one.
            if let existing = byPID[process.pid], !Self.isPreferred(process, over: existing) { continue }
            byPID[process.pid] = process
        }
        processesByPID = byPID
    }

    mutating func assignment(for process: ProcessMetrics) -> ThermalWorkloadAssignment {
        if let known = assignments[process.identity] { return known }
        let resolved = resolve(process)
        assignments[process.identity] = resolved
        return resolved
    }

    private mutating func resolve(_ process: ProcessMetrics) -> ThermalWorkloadAssignment {
        if let source = ThermalKnownSource.matching(name: process.name, executablePath: process.executablePath) {
            return ThermalWorkloadAssignment(groupKey: "known:\(source.rawValue)", displayName: source.displayName,
                                             applicationPath: nil, hostAppName: nil, kind: .knownSource(source))
        }
        if let app = Self.applicationPath(process.executablePath) { return appAssignment(app) }
        var visited: Set<Int32> = [process.pid]
        var hops = 0
        var root = process
        while let parent = parent(of: root, visited: &visited, hops: &hops) {
            // make and ninja run each recipe through `sh -c`: the build, not the shell, is the job.
            if ShellRole.isRecipeShell(parent, launcher: processesByPID[parent.parentPID]) {
                root = parent
                continue
            }
            if Self.isShell(parent.name) {
                let host = terminalHost(above: parent, visited: &visited, hops: &hops)
                return Self.job(root: root, host: host, kind: .job)
            }
            if let app = Self.applicationPath(parent.executablePath) {
                if let terminal = Self.terminalName(app) { return Self.job(root: root, host: terminal, kind: .job) }
                return appAssignment(app)
            }
            root = parent
        }
        // An XPC service or helper launchd started for an app, such as a
        // Safari tab's WebContent process, belongs to that app.
        if let responsible = responsiblePIDs[root.identity] ?? responsiblePIDs[process.identity],
           let owner = processesByPID[responsible],
           let app = Self.applicationPath(owner.executablePath) {
            return appAssignment(app)
        }
        return Self.job(root: root, host: nil, kind: root.identity == process.identity ? .process : .job)
    }

    /// Names the terminal a shell runs in; an editor's integrated terminal is not a host.
    private mutating func terminalHost(above shell: ProcessMetrics, visited: inout Set<Int32>,
                                       hops: inout Int) -> String? {
        var current = shell
        while let parent = parent(of: current, visited: &visited, hops: &hops) {
            if let app = Self.applicationPath(parent.executablePath) { return Self.terminalName(app) }
            current = parent
        }
        return nil
    }

    private mutating func parent(of child: ProcessMetrics, visited: inout Set<Int32>,
                                 hops: inout Int) -> ProcessMetrics? {
        guard hops < Self.maximumHops, child.parentPID > 1,
              let parent = processesByPID[child.parentPID], !visited.contains(parent.pid),
              Self.startedNoLater(parent.identity, than: child.identity) else { return nil }
        hops += 1
        visitedHops += 1
        visited.insert(parent.pid)
        return parent
    }

    /// Every helper of an app shares one assignment, named once per projection.
    private mutating func appAssignment(_ path: String) -> ThermalWorkloadAssignment {
        if let known = appAssignments[path] { return known }
        let assignment = ThermalWorkloadAssignment(groupKey: path, displayName: PathText.displayName(path),
                                                   applicationPath: path, hostAppName: nil, kind: .app)
        appAssignments[path] = assignment
        return assignment
    }

    private static func job(root: ProcessMetrics, host: String?, kind: ThermalWorkloadKind) -> ThermalWorkloadAssignment {
        let identity = root.identity
        return ThermalWorkloadAssignment(
            groupKey: "job:\(identity.pid):\(identity.startTimeSeconds).\(identity.startTimeMicroseconds)",
            displayName: root.name, applicationPath: nil, hostAppName: host, kind: kind)
    }

    /// A parent that started after its child is a recycled PID, not the real parent.
    private static func startedNoLater(_ parent: ProcessIdentity, than child: ProcessIdentity) -> Bool {
        (parent.startTimeSeconds, parent.startTimeMicroseconds) <= (child.startTimeSeconds, child.startTimeMicroseconds)
    }

    private static func isPreferred(_ candidate: ProcessMetrics, over existing: ProcessMetrics) -> Bool {
        let left = (candidate.identity.startTimeSeconds, candidate.identity.startTimeMicroseconds)
        let right = (existing.identity.startTimeSeconds, existing.identity.startTimeMicroseconds)
        if left != right { return left > right }
        return candidate.executablePath > existing.executablePath
    }

    private static func isShell(_ name: String) -> Bool {
        // Login shells report "-zsh".
        shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    private static func terminalName(_ appPath: String) -> String? {
        let name = PathText.displayName(appPath)
        return terminals.contains(name.lowercased()) ? name : nil
    }

    /// The outermost bundle, so nested helper apps join their host application.
    static func applicationPath(_ executable: String) -> String? {
        guard let range = executable.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(executable[..<executable.index(before: range.upperBound)])
    }
}
