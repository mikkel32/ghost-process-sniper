import Foundation
@testable import GhostProcessSniperCore

/// A process table whose processes react to what the kill engine does, so
/// races can be scripted as cause and effect: "exits two ticks after
/// SIGTERM", "quits three ticks after the quit request", "ignores SIGTERM".
/// Every call to `sleeper` advances one tick and moves `now` forward by the
/// requested time, so grace loops wait on the table instead of on the wall.
final class FakeProcessTable: KillSnapshotProviding, ProcessSignaling, @unchecked Sendable {
    enum Reaction: Sendable {
        case exit(afterTicks: Int)
        case ignore
        /// Starts `child` after the delay; the process itself keeps running.
        case forkChild(KillProcessLite, afterTicks: Int, behaviour: Behaviour = Behaviour())
        /// Exits now; a supervisor starts `replacement` after the delay.
        case respawn(KillProcessLite, afterTicks: Int, behaviour: Behaviour = Behaviour())
    }

    struct Behaviour: Sendable {
        /// Reactions per signal. Unlisted signals get the kernel default:
        /// SIGINT, SIGTERM, SIGHUP and SIGQUIT exit at once, others are ignored.
        /// SIGKILL always exits at once, whatever is listed here.
        var onSignal: [Int32: [Reaction]] = [:]
        /// Every signal fails with EPERM, like a process owned by someone else.
        var deniesSignals = false
        /// Ticks until the app exits after a quit request; nil for non-apps.
        var quitsOnRequest: Int?
        /// Stays listed with status 5 until its parent exits.
        var zombieOnExit = false
        /// Exits when its parent exits, like an app's helpers.
        var exitsWithParent = false

        init(
            onSignal: [Int32: [Reaction]] = [:],
            deniesSignals: Bool = false,
            quitsOnRequest: Int? = nil,
            zombieOnExit: Bool = false,
            exitsWithParent: Bool = false
        ) {
            self.onSignal = onSignal
            self.deniesSignals = deniesSignals
            self.quitsOnRequest = quitsOnRequest
            self.zombieOnExit = zombieOnExit
            self.exitsWithParent = exitsWithParent
        }

        static let ignoresTermination = Behaviour(onSignal: [SIGINT: [.ignore], SIGTERM: [.ignore]])

        static func exits(on signal: Int32, afterTicks ticks: Int) -> Behaviour {
            Behaviour(onSignal: [signal: [.exit(afterTicks: ticks)]])
        }
    }

    struct Sent: Equatable, Sendable {
        let tick: Int
        let pid: Int32
        let signal: Int32
    }

    static let stoppedStatus: UInt32 = 4
    static let zombieStatus: UInt32 = 5
    private static let runningStatus: UInt32 = 2

    private struct Entry {
        var lite: KillProcessLite
        var behaviour: Behaviour
        var stopped: Bool
        var zombie = false
        var pendingSignals: [Int32] = []
    }

    private enum Event {
        case exit(ProcessIdentity)
        case spawn(KillProcessLite, Behaviour)
    }

    private let lock = NSLock()
    private let start: Date
    private var entries: [ProcessIdentity: Entry] = [:]
    private var scheduled: [(due: Int, event: Event)] = []
    private var currentTick = 0
    private var elapsed: TimeInterval = 0
    private var sentLog: [Sent] = []
    private var quitLog: [Sent] = []
    private var seenRequests: [KillSnapshotRequest] = []
    private var snapshotSpawner: (@Sendable (Int) -> [KillProcessLite])?
    private var failingFromSnapshot: Int?

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.start = start
    }

    func add(_ lite: KillProcessLite, _ behaviour: Behaviour = Behaviour()) {
        lock.withLock {
            entries[lite.identity] = Entry(lite: lite, behaviour: behaviour, stopped: lite.status == Self.stoppedStatus)
        }
    }

    /// Starts the processes `spawn` returns right before snapshot number
    /// `index` (the first is 0) is taken, like a fork racing the listing.
    func onSnapshot(_ spawn: @escaping @Sendable (_ index: Int) -> [KillProcessLite]) {
        lock.withLock { snapshotSpawner = spawn }
    }

    /// Every snapshot from number `index` on throws.
    func failSnapshots(from index: Int) {
        lock.withLock { failingFromSnapshot = index }
    }

    // MARK: - Clock

    var sleeper: @Sendable (UInt64) async -> Void {
        { [self] nanoseconds in advance(seconds: Double(nanoseconds) / 1_000_000_000) }
    }

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { start.addingTimeInterval(elapsed) } }
    }

    var tick: Int { lock.withLock { currentTick } }

    func advance(ticks: Int = 1, seconds: TimeInterval = 0) {
        lock.withLock {
            for _ in 0..<max(0, ticks) {
                currentTick += 1
                elapsed += seconds
                runDueEvents()
            }
        }
    }

    // MARK: - Inspection

    /// Every signal the engine sent, in order; quit requests are not signals
    /// and are logged apart, with signal 0.
    var log: [Sent] { lock.withLock { sentLog } }
    var quitRequests: [Sent] { lock.withLock { quitLog } }
    var requests: [KillSnapshotRequest] { lock.withLock { seenRequests } }

    func signals(to pid: Int32) -> [Int32] {
        log.filter { $0.pid == pid }.map(\.signal)
    }

    /// Processes the kernel would list now, zombies included.
    var listed: [KillProcessLite] {
        lock.withLock { listedLocked() }
    }

    func isListed(_ pid: Int32) -> Bool {
        listed.contains { $0.pid == pid }
    }

    func status(of pid: Int32) -> UInt32? {
        listed.first { $0.pid == pid }?.status
    }

    // MARK: - KillSnapshotProviding

    func snapshot(request: KillSnapshotRequest) async throws -> KillProcessSnapshot {
        try lock.withLock {
            let index = seenRequests.count
            seenRequests.append(request)
            if let failing = failingFromSnapshot, index >= failing {
                throw ProcessSamplerError.listFailed
            }
            for lite in snapshotSpawner?(index) ?? [] {
                entries[lite.identity] = Entry(lite: lite, behaviour: Behaviour(), stopped: false)
            }
            var processes = listedLocked()
            if request.policy == .verify,
               request.verificationMode == .targetOnly,
               !request.requiresCompleteGraph,
               !request.targetIdentities.isEmpty {
                // Like the native provider: read each requested PID, whoever holds it now.
                let pids = Set(request.targetIdentities.map(\.pid))
                processes = processes.filter { pids.contains($0.pid) }
            }
            let sampledAt = start.addingTimeInterval(elapsed)
            return KillProcessSnapshot(
                processes: [],
                sampledAt: sampledAt,
                policy: request.policy,
                usedCheapPath: true,
                request: request,
                arena: KillGraphArena(processes: processes, sampledAt: sampledAt),
                graphReadCount: processes.count,
                targetConversionCount: 0
            )
        }
    }

    // MARK: - ProcessSignaling

    func send(signal: Int32, to pid: Int32) throws {
        try lock.withLock {
            sentLog.append(Sent(tick: currentTick, pid: pid, signal: signal))
            guard let identity = listedIdentity(for: pid) else {
                throw SignalFailure(pid: pid, signal: signal, errnoCode: ESRCH, message: "No such process")
            }
            guard let entry = entries[identity], !entry.behaviour.deniesSignals else {
                throw SignalFailure(pid: pid, signal: signal, errnoCode: EPERM, message: "Operation not permitted")
            }
            deliver(signal, to: identity)
        }
    }

    func exists(pid: Int32) -> Bool {
        lock.withLock { listedIdentity(for: pid) != nil }
    }

    func isZombieOrGone(pid: Int32) -> Bool {
        lock.withLock { listedIdentity(for: pid).flatMap { entries[$0]?.zombie } ?? true }
    }

    func requestQuit(pid: Int32) async -> Bool {
        lock.withLock {
            guard let identity = listedIdentity(for: pid),
                  let entry = entries[identity], !entry.zombie,
                  let ticks = entry.behaviour.quitsOnRequest else {
                return false
            }
            quitLog.append(Sent(tick: currentTick, pid: pid, signal: 0))
            schedule(.exit(identity), afterTicks: ticks)
            return true
        }
    }

    // MARK: - Kernel model (call with the lock held)

    private func listedLocked() -> [KillProcessLite] {
        entries.values
            .map { entry in
                let status = entry.zombie ? Self.zombieStatus : entry.stopped ? Self.stoppedStatus : entry.lite.status
                return Self.lite(entry.lite, parentPID: entry.lite.parentPID, status: status)
            }
            .sorted { $0.pid < $1.pid }
    }

    private func listedIdentity(for pid: Int32) -> ProcessIdentity? {
        entries.first { $0.key.pid == pid }?.key
    }

    private func deliver(_ signal: Int32, to identity: ProcessIdentity) {
        guard var entry = entries[identity], !entry.zombie else { return }
        switch signal {
        case SIGKILL:
            exit(identity)
            return
        case SIGCONT:
            entry.stopped = false
            let pending = entry.pendingSignals
            entry.pendingSignals = []
            entry.lite = Self.lite(entry.lite, parentPID: entry.lite.parentPID, status: Self.runningStatus)
            entries[identity] = entry
            for held in pending {
                deliver(held, to: identity)
            }
            return
        case SIGSTOP, SIGTSTP:
            entry.stopped = true
            entries[identity] = entry
            return
        default:
            break
        }
        if entry.stopped {
            entry.pendingSignals.append(signal)
            entries[identity] = entry
            return
        }
        for reaction in reactions(to: signal, behaviour: entry.behaviour) {
            switch reaction {
            case .exit(let ticks):
                schedule(.exit(identity), afterTicks: ticks)
            case .ignore:
                break
            case .forkChild(let child, let ticks, let behaviour):
                schedule(.spawn(child, behaviour), afterTicks: ticks)
            case .respawn(let replacement, let ticks, let behaviour):
                exit(identity)
                schedule(.spawn(replacement, behaviour), afterTicks: ticks)
            }
        }
    }

    private func reactions(to signal: Int32, behaviour: Behaviour) -> [Reaction] {
        if let listed = behaviour.onSignal[signal] {
            return listed
        }
        switch signal {
        case SIGINT, SIGTERM, SIGHUP, SIGQUIT: return [.exit(afterTicks: 0)]
        default: return [.ignore]
        }
    }

    private func schedule(_ event: Event, afterTicks ticks: Int) {
        if ticks <= 0 {
            run(event)
        } else {
            scheduled.append((currentTick + ticks, event))
        }
    }

    private func runDueEvents() {
        let due = scheduled.filter { $0.due <= currentTick }
        scheduled.removeAll { $0.due <= currentTick }
        for item in due {
            run(item.event)
        }
    }

    private func run(_ event: Event) {
        switch event {
        case .exit(let identity):
            exit(identity)
        case .spawn(let lite, let behaviour):
            entries[lite.identity] = Entry(lite: lite, behaviour: behaviour, stopped: lite.status == Self.stoppedStatus)
        }
    }

    private func exit(_ identity: ProcessIdentity) {
        guard var entry = entries[identity], !entry.zombie else { return }
        if entry.behaviour.zombieOnExit, isRunning(entry.lite.parentPID) {
            entry.zombie = true
            entry.stopped = false
            entry.pendingSignals = []
            entries[identity] = entry
        } else {
            entries.removeValue(forKey: identity)
        }
        // The parent is gone: its zombies are reaped, helpers that follow it
        // exit, and the rest are adopted by launchd.
        for (childIdentity, child) in entries where child.lite.parentPID == identity.pid {
            if child.zombie {
                entries.removeValue(forKey: childIdentity)
            } else if child.behaviour.exitsWithParent {
                exit(childIdentity)
            } else {
                var adopted = child
                adopted.lite = Self.lite(child.lite, parentPID: 1, status: child.lite.status)
                entries[childIdentity] = adopted
            }
        }
    }

    private func isRunning(_ pid: Int32) -> Bool {
        entries.contains { $0.key.pid == pid && !$0.value.zombie }
    }

    private static func lite(_ lite: KillProcessLite, parentPID: Int32, status: UInt32) -> KillProcessLite {
        KillProcessLite(
            identity: lite.identity,
            parentPID: parentPID,
            userID: lite.userID,
            ownerName: lite.ownerName,
            name: lite.name,
            status: status,
            flags: lite.flags,
            processGroupID: lite.processGroupID,
            openFileCount: lite.openFileCount,
            residentMemoryBytes: lite.residentMemoryBytes,
            physicalFootprintBytes: lite.physicalFootprintBytes,
            virtualMemoryBytes: lite.virtualMemoryBytes,
            cpuPercent: lite.cpuPercent,
            totalProcessorSeconds: lite.totalProcessorSeconds,
            threadCount: lite.threadCount,
            isSystemProcess: lite.isSystemProcess,
            didReadHeavyMetrics: lite.didReadHeavyMetrics,
            sampledAt: lite.sampledAt
        )
    }
}

extension KillProcessLite {
    /// A same-user process for FakeProcessTable scenarios.
    static func fake(
        pid: Int32,
        parent: Int32 = 1,
        name: String = "worker",
        userID: UInt32 = 501,
        start: UInt64 = 1_000,
        status: UInt32 = 2,
        flags: UInt32 = 0,
        group: Int32? = nil,
        memory: UInt64 = 64 * 1_048_576
    ) -> KillProcessLite {
        KillProcessLite(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
            parentPID: parent,
            userID: userID,
            ownerName: userID == 501 ? "me" : "root",
            name: name,
            status: status,
            flags: flags,
            processGroupID: group ?? pid,
            openFileCount: 4,
            residentMemoryBytes: memory,
            physicalFootprintBytes: memory,
            sampledAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }
}
