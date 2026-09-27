import Darwin
import Foundation

/// A process the spawn watcher read the moment it started or exec'd.
struct SpawnCapture: Sendable {
    let identity: ProcessIdentity
    let parentPID: Int32
    let userID: UInt32
    let name: String
    let executablePath: String
    let commandLine: String
    let at: Date
    /// The watched app at the top of the chain, for context and alerts.
    let rootRole: SpawnWatcher.RootRole
}

/// Watches browsers, mail, chat and document apps and terminals for the
/// processes they start, using kernel process events rather than polling.
///
/// A `curl` that lives for 200 ms falls between two scans; here the fork
/// wakes this queue, the child is followed to its `exec`, and its path and
/// arguments are read while it runs. Children are followed a few levels
/// down (Terminal › login › zsh › curl), so a pasted one-liner is seen whole.
/// With nothing starting, the watcher costs nothing.
final class SpawnWatcher: @unchecked Sendable {
    enum RootRole: Sendable {
        case contentApp
        case terminal
    }

    static let maxWatched = 192
    static let maxDepth = 5
    static let maxBuffered = 600

    private let queue = DispatchQueue(label: "GhostProcessSniper.sentinel.spawn-watch", qos: .utility)
    private let probe = NativeProcessProbeSource()
    private let onRunnerFromContentApp: @Sendable () -> Void

    // Confined to `queue`.
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private var watchInfo: [Int32: (depth: Int, role: RootRole, path: String)] = [:]
    private var knownChildren: [Int32: Set<Int32>] = [:]
    private var roots: [Int32: RootRole] = [:]
    private var buffered: [SpawnCapture] = []
    private var lastRecorded: [Int32: String] = [:]

    init(onRunnerFromContentApp: @escaping @Sendable () -> Void = {}) {
        self.onRunnerFromContentApp = onRunnerFromContentApp
    }

    deinit {
        for source in sources.values { source.cancel() }
    }

    /// The apps to watch now; apps that quit are dropped with their followers.
    func setRoots(_ pids: [Int32: RootRole]) {
        queue.async { [self] in
            for pid in roots.keys where pids[pid] == nil {
                stopWatching(pid)
            }
            for (pid, role) in pids where roots[pid] == nil {
                watch(pid, depth: 0, role: role, path: probe.executablePath(pid))
            }
            roots = pids
        }
    }

    /// Everything caught since the last call, oldest first.
    func drain() -> [SpawnCapture] {
        queue.sync {
            defer { buffered.removeAll(keepingCapacity: true) }
            return buffered
        }
    }

    var watchedCount: Int {
        queue.sync { sources.count }
    }

    // MARK: - Queue-confined

    private func watch(_ pid: Int32, depth: Int, role: RootRole, path: String) {
        guard sources[pid] == nil, sources.count < Self.maxWatched else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.fork, .exec, .exit], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if events.contains(.exit) {
                self.stopWatching(pid)
                return
            }
            if events.contains(.exec) {
                self.handleExec(pid)
            }
            if events.contains(.fork) {
                self.handleFork(of: pid)
            }
        }
        sources[pid] = source
        watchInfo[pid] = (depth, role, path)
        knownChildren[pid] = Set(childPIDs(of: pid))
        source.resume()
    }

    private func stopWatching(_ pid: Int32) {
        sources.removeValue(forKey: pid)?.cancel()
        watchInfo[pid] = nil
        knownChildren[pid] = nil
        lastRecorded[pid] = nil
    }

    private func handleFork(of parent: Int32) {
        guard let info = watchInfo[parent] else { return }
        let children = childPIDs(of: parent)
        let known = knownChildren[parent] ?? []
        knownChildren[parent] = Set(children)
        for child in children where !known.contains(child) {
            guard let capture = read(child, role: info.role) else { continue }
            let appHelper = isOwnHelper(capture.executablePath, parentPath: info.path)
            if capture.executablePath != info.path, !appHelper {
                record(capture)
            }
            // A fork still shows its parent's image until it execs; follow it
            // to see what it becomes. An app's own helper needs no following.
            if !appHelper, info.depth + 1 <= Self.maxDepth {
                watch(child, depth: info.depth + 1, role: info.role, path: capture.executablePath)
            }
        }
    }

    private func handleExec(_ pid: Int32) {
        guard var info = watchInfo[pid], info.depth > 0, let capture = read(pid, role: info.role) else { return }
        info.path = capture.executablePath
        watchInfo[pid] = info
        record(capture)
        // Keep following shells and runners (their children are the commands);
        // stop following a program that became an ordinary tool.
        let keeps = SentinelCatalog.isCommandRunner(capture.name, path: capture.executablePath)
            || ShellRole.isSessionHost(capture.name)
        if !keeps {
            stopWatching(pid)
        }
    }

    private func record(_ capture: SpawnCapture) {
        let pid = capture.identity.pid
        guard lastRecorded[pid] != capture.executablePath + capture.commandLine else { return }
        lastRecorded[pid] = capture.executablePath + capture.commandLine
        if buffered.count >= Self.maxBuffered { buffered.removeFirst(buffered.count - Self.maxBuffered + 1) }
        buffered.append(capture)
        if capture.rootRole == .contentApp, SentinelCatalog.isCommandRunner(capture.name, path: capture.executablePath) {
            onRunnerFromContentApp()
        }
    }

    private func isOwnHelper(_ path: String, parentPath: String) -> Bool {
        guard let bundle = CodeSignatureInspector.bundleRoot(of: parentPath) else { return false }
        return path.hasPrefix(bundle + "/")
    }

    private func read(_ pid: Int32, role: RootRole) -> SpawnCapture? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let path = probe.executablePath(pid)
        let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let identity = ProcessIdentity(pid: pid, startTimeSeconds: info.pbi_start_tvsec,
                                       startTimeMicroseconds: info.pbi_start_tvusec)
        return SpawnCapture(
            identity: identity,
            parentPID: Int32(info.pbi_ppid),
            userID: info.pbi_uid,
            name: name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name,
            executablePath: path,
            commandLine: probe.commandLine(pid) ?? path,
            at: Date(),
            rootRole: role
        )
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        var buffer = [pid_t](repeating: 0, count: 256)
        // libproc returns the number of pids (proc_listpids' bytes / sizeof(int));
        // unused slots stay zero, so the filter is exact either way.
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return buffer.prefix(min(buffer.count, Int(count))).filter { $0 > 0 }
    }
}
