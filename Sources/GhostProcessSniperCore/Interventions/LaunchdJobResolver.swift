import Foundation

/// The launchd job that runs a process. With KeepAlive, launchd starts it
/// again a second after any stop, so the job itself has to be stopped.
public struct LaunchdJob: Equatable, Sendable {
    public let label: String
    /// The job's live PID from `launchctl list`. Nil when the job was only
    /// matched by its program path: that is advice, never a bootout target.
    public let pid: Int32?
    /// "gui/501" for a user's agents, "system" for daemons.
    public let domain: String
    public let plistPath: String?
    public let keepAlive: Bool

    public init(label: String, pid: Int32?, domain: String, plistPath: String?, keepAlive: Bool) {
        self.label = label
        self.pid = pid
        self.domain = domain
        self.plistPath = plistPath
        self.keepAlive = keepAlive
    }

    public var domainTarget: String { "\(domain)/\(label)" }

    public var homebrewFormula: String? {
        let prefix = "homebrew.mxcl."
        guard label.hasPrefix(prefix), label.count > prefix.count else { return nil }
        return String(label.dropFirst(prefix.count))
    }

    public var plistName: String {
        plistPath.map { ($0 as NSString).lastPathComponent } ?? "\(label).plist"
    }

    /// Stops the running job until the next login.
    public var stopCommand: String {
        if let formula = homebrewFormula { return "\(sudo)brew services stop \(formula)" }
        return "\(sudo)launchctl bootout \(domainTarget)"
    }

    /// Keeps it from starting again at the next login.
    public var keepStoppedCommand: String {
        if let formula = homebrewFormula { return "\(sudo)brew services stop \(formula)" }
        return "\(sudo)launchctl disable \(domainTarget)"
    }

    public var undoCommand: String {
        if let formula = homebrewFormula { return "\(sudo)brew services start \(formula)" }
        let enable = "\(sudo)launchctl enable \(domainTarget)"
        guard let plistPath else { return enable }
        return "\(enable) && \(sudo)launchctl bootstrap \(domain) \(plistPath)"
    }

    private var sudo: String { domain == "system" ? "sudo " : "" }
}

/// How a confirmed stop treats the launchd job behind its root.
public enum KillLaunchdStop: String, Codable, Sendable {
    /// Signal the process like any other; launchd may restart it.
    case none
    /// Boot the job out of launchd: it stays stopped until the next login.
    case untilLogin
    /// Boot it out and disable it, so it stays stopped after a restart too.
    case keepOff
}

/// What `launchctl bootout` did for a stop.
public struct LaunchdBootout: Equatable, Sendable {
    public let job: LaunchdJob
    public let keepOff: Bool
    /// launchd took the request and is stopping the job itself.
    public let accepted: Bool
    public let disabled: Bool
    public let status: Int32
}

public protocol LaunchctlRunning: Sendable {
    func run(_ args: [String], timeout: Duration) async -> (status: Int32, stdout: String)
}

/// Runs /bin/launchctl on a background queue, terminating it after the timeout.
public struct SystemLaunchctl: LaunchctlRunning {
    public init() {}

    public func run(_ args: [String], timeout: Duration) async -> (status: Int32, stdout: String) {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(args, seconds: seconds))
            }
        }
    }

    private final class Launch: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var expired = false

        var timedOut: Bool { lock.withLock { expired } }

        func expire() {
            lock.withLock { expired = true }
            if process.isRunning { process.terminate() }
        }
    }

    private static func runBlocking(_ args: [String], seconds: Double) -> (status: Int32, stdout: String) {
        let launch = Launch()
        let pipe = Pipe()
        launch.process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launch.process.arguments = args
        launch.process.standardOutput = pipe
        launch.process.standardError = FileHandle.nullDevice
        do {
            try launch.process.run()
        } catch {
            return (LaunchdJobResolver.launchFailedStatus, "")
        }
        let deadline = DispatchWorkItem { launch.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: deadline)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        launch.process.waitUntilExit()
        deadline.cancel()
        let status = launch.timedOut ? LaunchdJobResolver.timedOutStatus : launch.process.terminationStatus
        return (status, String(decoding: output, as: UTF8.self))
    }
}

/// Finds the launchd job behind a process and boots it out. `launchctl list`
/// maps live PIDs to labels; the plist index says whether the job is kept
/// alive, and names the job by its program when launchctl cannot be asked.
public struct LaunchdJobResolver: Sendable {
    public static let launchFailedStatus: Int32 = -1
    public static let timedOutStatus: Int32 = -2

    public struct ListEntry: Equatable, Sendable {
        public let pid: Int32?
        public let label: String
    }

    /// A process belongs to the job that launched it for its whole life,
    /// so an answer launchctl gave holds for that identity: a preview that
    /// refreshes, and the confirm after it, run launchctl only once.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [ProcessIdentity: LaunchdJob?] = [:]

        func job(for identity: ProcessIdentity) -> LaunchdJob?? {
            lock.withLock { jobs[identity] }
        }

        func remember(_ job: LaunchdJob?, for identity: ProcessIdentity) {
            lock.withLock {
                if jobs.count >= 64 { jobs.removeAll() }
                jobs[identity] = .some(job)
            }
        }
    }

    private let launchctl: LaunchctlRunning
    private let index: KillLaunchAgentIndex
    private let userID: UInt32
    private let timeout: Duration
    private let memo = Memo()

    public init(
        launchctl: LaunchctlRunning = SystemLaunchctl(),
        index: KillLaunchAgentIndex = .shared,
        userID: UInt32 = UInt32(getuid()),
        timeout: Duration = .seconds(2)
    ) {
        self.launchctl = launchctl
        self.index = index
        self.userID = userID
        self.timeout = timeout
    }

    public func job(forPID pid: Int32, executablePath: String) async -> LaunchdJob? {
        await resolve(pid: pid, executablePath: executablePath).job
    }

    /// The same lookup, remembered for the process's identity.
    public func job(for identity: ProcessIdentity, executablePath: String) async -> LaunchdJob? {
        if let known = memo.job(for: identity) { return known }
        let resolved = await resolve(pid: identity.pid, executablePath: executablePath)
        if resolved.fromLaunchctl { memo.remember(resolved.job, for: identity) }
        return resolved.job
    }

    private func resolve(pid: Int32, executablePath: String) async -> (job: LaunchdJob?, fromLaunchctl: Bool) {
        let listing = await launchctl.run(["list"], timeout: timeout)
        if listing.status == 0 {
            // launchctl answered: a PID it does not list is not a job's
            // process, even if it runs the same program as one.
            guard let entry = Self.parseList(listing.stdout).first(where: { $0.pid == pid }) else { return (nil, true) }
            let agent = index.agent(label: entry.label)
            let job = LaunchdJob(label: entry.label, pid: pid, domain: "gui/\(userID)",
                                 plistPath: agent?.plistPath, keepAlive: agent?.keepAlive ?? false)
            return (job, true)
        }
        guard let agent = index.agent(forExecutable: executablePath) else { return (nil, false) }
        let job = LaunchdJob(label: agent.label, pid: nil, domain: agent.isDaemon ? "system" : "gui/\(userID)",
                             plistPath: agent.plistPath, keepAlive: agent.keepAlive)
        return (job, false)
    }

    /// Asks launchd to stop the job; it sends SIGTERM and honours the job's
    /// ExitTimeOut. A timed-out launchctl still delivered the request.
    public func bootout(_ job: LaunchdJob, keepOff: Bool) async -> LaunchdBootout {
        let result = await launchctl.run(["bootout", job.domainTarget], timeout: timeout)
        let accepted = result.status == 0 || result.status == Self.timedOutStatus
        var disabled = false
        if accepted, keepOff {
            disabled = await launchctl.run(["disable", job.domainTarget], timeout: timeout).status == 0
        }
        return LaunchdBootout(job: job, keepOff: keepOff, accepted: accepted, disabled: disabled, status: result.status)
    }

    /// Rows of `launchctl list`: PID, last exit status and label, tab
    /// separated, with "-" for a job that is not running. Apps that
    /// LaunchServices started are listed as application.* and are skipped.
    public static func parseList(_ output: String) -> [ListEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            var columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if columns.count < 3 {
                columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            }
            guard columns.count == 3, columns[0] != "PID" else { return nil }
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !label.hasPrefix("application.") else { return nil }
            return ListEntry(pid: Int32(columns[0].trimmingCharacters(in: .whitespaces)), label: label)
        }
    }
}
