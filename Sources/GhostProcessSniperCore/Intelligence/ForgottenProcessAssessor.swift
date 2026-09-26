import Foundation

/// How likely a family is work nobody is using any more, and the facts that
/// say so, in plain words.
public struct ForgottenAssessment: Equatable, Sendable {
    public let likelihood: Double
    public let facts: [String]
    public let launchContext: LaunchContext
    /// Seconds since any member last did work, when the ledger has watched it.
    public let idleSeconds: TimeInterval?

    public static let none = ForgottenAssessment(likelihood: 0, facts: [], launchContext: .childOfLiveProcess, idleSeconds: nil)

    public init(likelihood: Double, facts: [String], launchContext: LaunchContext, idleSeconds: TimeInterval?) {
        // Sums of tenths must compare as written: 0.45 + 0.25 + 0.1 is 0.8.
        self.likelihood = min(1, max(0, (likelihood * 100).rounded() / 100))
        self.facts = facts
        self.launchContext = launchContext
        self.idleSeconds = idleSeconds
    }
}

/// Weighs the real signs of a forgotten process: how it was launched, CPU
/// idleness from cumulative CPU-seconds, age, a deleted working directory
/// and a port still held while idle.
public enum ForgottenProcessAssessor {
    static let idleThreshold: TimeInterval = 30 * 60

    public static func assess(
        root: ProcessMetrics,
        context: LaunchContext,
        activity: FamilyCPUActivity,
        forensics: ProcessForensics,
        workingDirectoryMissing: Bool,
        now: Date
    ) -> ForgottenAssessment {
        var likelihood = 0.0
        var facts: [String] = []
        let idle = activity.idleSeconds(at: now)
        let isIdle = (idle ?? 0) >= idleThreshold

        if context == .abandonedTerminalJob || context == .reparentedOrphan {
            likelihood += 0.45
        } else if context == .detachedFromLauncher {
            likelihood += 0.3
        }
        if context.isUnattended, let fact = context.fact {
            facts.append(fact)
        }
        if let idle, isIdle {
            likelihood += 0.25
            facts.append("no CPU use for \(duration(idle))")
        }
        if context == .terminalBackground, let idle, idle >= 60 * 60 {
            likelihood += 0.15
            facts.append("\(context.fact ?? "backgrounded") and idle for \(duration(idle))")
        }
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(root.identity.startTimeSeconds)))
        if age >= 3 * 3_600 {
            likelihood += 0.15
            facts.append("running for \(duration(age))")
        }
        if workingDirectoryMissing, let directory = forensics.currentDirectory {
            likelihood += 0.2
            facts.append("its working directory \(directory) was deleted")
        }
        if isIdle, !forensics.listeningPorts.isEmpty {
            likelihood += 0.1
            let ports = forensics.listeningPorts.prefix(3).map(String.init).joined(separator: ", ")
            facts.append("still listening on port\(forensics.listeningPorts.count == 1 ? "" : "s") \(ports)")
        }
        // launchd keeps its jobs and apps alive on purpose.
        if (context == .appBundle || context == .launchdJob), !workingDirectoryMissing {
            likelihood = min(likelihood, 0.2)
        }
        return ForgottenAssessment(likelihood: likelihood, facts: facts, launchContext: context, idleSeconds: idle)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 {
            let tenths = Int((seconds / 360).rounded())
            return tenths % 10 == 0 || tenths >= 100 ? "\(tenths / 10) h" : "\(tenths / 10).\(tenths % 10) h"
        }
        return "\(max(1, Int(seconds / 60))) min"
    }
}

/// Whether a path still exists, remembered for a minute so a quiet family is
/// not a file-system call every tick.
final class DirectoryExistenceCache: @unchecked Sendable {
    static let timeToLive: TimeInterval = 60

    private let lock = NSLock()
    private var entries: [String: (exists: Bool, checkedAt: Date)] = [:]
    private let check: @Sendable (String) -> Bool

    init(check: @escaping @Sendable (String) -> Bool = { WorkingDirectoryProbe.exists($0) }) {
        self.check = check
    }

    func exists(_ path: String, now: Date) -> Bool {
        lock.lock()
        if let entry = entries[path], now.timeIntervalSince(entry.checkedAt) < Self.timeToLive {
            lock.unlock()
            return entry.exists
        }
        lock.unlock()
        let exists = check(path)
        lock.lock()
        if entries.count > 512 {
            entries = entries.filter { now.timeIntervalSince($0.value.checkedAt) < Self.timeToLive }
        }
        entries[path] = (exists, now)
        lock.unlock()
        return exists
    }
}

/// Whether a working directory is really gone. Only ENOENT and ENOTDIR say
/// so: without Full Disk Access a live project folder fails with EPERM or
/// EACCES, and that must not read as deleted. Folders macOS guards behind a
/// privacy prompt are never touched, so a background tick cannot raise one.
public enum WorkingDirectoryProbe {
    public static func exists(_ path: String) -> Bool {
        exists(path, home: home, statError: statError)
    }

    static func exists(_ path: String, home: String, statError: (String) -> Int32) -> Bool {
        if isPrivacyProtected(path, home: home) { return true }
        let error = statError(path)
        return error != ENOENT && error != ENOTDIR
    }

    static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 } + ["/Volumes"]
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static func statError(_ path: String) -> Int32 {
        var info = stat()
        return stat(path, &info) == 0 ? 0 : errno
    }
}
