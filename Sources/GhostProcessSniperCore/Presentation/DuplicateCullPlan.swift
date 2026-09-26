import Darwin
import Foundation

/// "Stop the extras" for one duplicate cluster: which copies to stop, which
/// to keep, and why. Only a plan: every stop still goes through its own stop
/// preview, so the preview's safety checks have the last word.
public struct DuplicateCullPlan: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        case keep, stop
    }

    public enum Rule: String, CaseIterable, Sendable {
        case notYours, busy, busyChild, unmeasured, launchdService, openedApp, lightWork,
             usedByParent, parentOutsideScan, keptNewest, recommendedKeep, overLimit, orphaned, stopsWithCopy
    }

    public struct Decision: Identifiable, Equatable, Sendable {
        public var id: ProcessIdentity { identity }
        public let identity: ProcessIdentity
        public let name: String
        public let verdict: Verdict
        public let rule: Rule
        public let reason: String
        public let memoryBytes: UInt64
        public let cpuPercent: Double
        public let memoryText: String
        public let cpuText: String
        /// The stopped copy that started this one; it goes down with that
        /// copy's tree instead of getting a stop of its own.
        public let stopsWith: ProcessIdentity?

        public var pid: Int32 { identity.pid }

        public init(
            process: ProcessMetrics,
            verdict: Verdict,
            rule: Rule,
            reason: String,
            stopsWith: ProcessIdentity? = nil
        ) {
            identity = process.identity
            name = process.name
            self.verdict = verdict
            self.rule = rule
            self.reason = reason
            memoryBytes = process.memoryForScoringBytes
            cpuPercent = process.cpuPercent
            memoryText = RadarFormat.bytes(process.memoryForScoringBytes)
            cpuText = RadarFormat.percent(process.cpuPercent)
            self.stopsWith = stopsWith
        }
    }

    /// One pass stops at most this many copies; the next look finds the rest.
    public static let maximumStops = 32

    /// Follows the radar's "which copy to keep" recommendation within the
    /// conservative safety rules.
    public static let planner: any DuplicateCullPlanning = ConservativeDuplicateCullPlanner()

    public let clusterID: String
    public let displayName: String
    /// Live copies in the cluster's order; exited or recycled members are left out.
    public let decisions: [Decision]
    public let stopCount: Int
    public let reclaimBytes: UInt64
    public let reclaimText: String
    public let summary: String

    public init(clusterID: String, displayName: String, decisions: [Decision]) {
        self.clusterID = clusterID
        self.displayName = displayName
        self.decisions = decisions
        let stops = decisions.filter { $0.verdict == .stop }
        stopCount = stops.count
        reclaimBytes = stops.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        reclaimText = stops.isEmpty ? "\u{2014}" : RadarFormat.bytes(reclaimBytes)
        summary = Self.summary(decisions: decisions, stopCount: stops.count, reclaimBytes: reclaimBytes)
    }

    /// The copies to stop one by one, each taking the copies it started with it.
    public var stopTargets: [Decision] {
        decisions.filter { $0.verdict == .stop && $0.stopsWith == nil }
    }

    public var keepCount: Int {
        decisions.count - stopCount
    }

    public static func plan(
        for cluster: DuplicateProcessCluster,
        sample: [ProcessMetrics],
        currentUserID: uid_t
    ) -> DuplicateCullPlan {
        plans(for: [cluster], sample: sample, currentUserID: currentUserID)[cluster.id]
            ?? DuplicateCullPlan(clusterID: cluster.id, displayName: cluster.displayName, decisions: [])
    }

    /// Plans keyed by cluster id; the sample is indexed once for all of them.
    public static func plans(
        for clusters: [DuplicateProcessCluster],
        sample: [ProcessMetrics],
        currentUserID: uid_t
    ) -> [String: DuplicateCullPlan] {
        planner.plans(for: clusters, sample: sample, currentUserID: currentUserID)
    }

    private static func summary(decisions: [Decision], stopCount: Int, reclaimBytes: UInt64) -> String {
        guard !decisions.isEmpty else { return "Every copy has already exited." }
        let keepCount = decisions.count - stopCount
        if stopCount > 0 {
            let stops = "Stop \(stopCount) orphaned \(stopCount == 1 ? "copy" : "copies")"
            let keeps = keepCount > 0 ? " and keep \(keepCount)" : ""
            return "\(stops)\(keeps), freeing about \(RadarFormat.bytes(reclaimBytes))."
        }
        var counts: [Rule: Int] = [:]
        for decision in decisions { counts[decision.rule, default: 0] += 1 }
        let order = Rule.allCases
        let dominant = counts.max { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value < rhs.value
                : order.firstIndex(of: lhs.key) ?? 0 > order.firstIndex(of: rhs.key) ?? 0
        }?.key
        return "Nothing to stop: \(dominant.map(nothingToStopReason) ?? "every copy is in use")."
    }

    private static func nothingToStopReason(_ rule: Rule) -> String {
        switch rule {
        case .notYours: "the copies belong to another user or the system"
        case .busy: "the copies are busy right now"
        case .busyChild, .lightWork: "the copies are still doing work"
        case .unmeasured: "their CPU use is not measured yet"
        case .launchdService: "launchd runs these copies and would start them again"
        case .openedApp: "these are apps you opened"
        case .usedByParent: "every copy is used by a running app"
        case .parentOutsideScan: "what started them is outside this scan"
        case .keptNewest: "the only idle copy is kept in case it is still wanted"
        case .recommendedKeep: "the only idle copy is the one worth keeping"
        case .overLimit, .orphaned, .stopsWithCopy: "every copy is in use"
        }
    }
}

/// Decides which copies of each cluster to keep.
public protocol DuplicateCullPlanning: Sendable {
    func plans(
        for clusters: [DuplicateProcessCluster],
        sample: [ProcessMetrics],
        currentUserID: uid_t
    ) -> [String: DuplicateCullPlan]
}

/// Keeps every copy that is someone else's, busy, run by launchd, or started
/// by something still running, and the copy the radar recommends keeping
/// (`keepIdentity`: the one in a terminal, else the most recently active).
/// Stops only idle copies whose parent is gone (launchd adopted them), and
/// never every copy of a cluster.
public struct ConservativeDuplicateCullPlanner: DuplicateCullPlanning {
    public static let busyCPUPercent = 5.0
    public static let idleCPUPercent = 2.0

    public init() {}

    public func plans(
        for clusters: [DuplicateProcessCluster],
        sample: [ProcessMetrics],
        currentUserID: uid_t
    ) -> [String: DuplicateCullPlan] {
        guard !clusters.isEmpty else { return [:] }
        let index = SampleIndex(sample)
        var plans: [String: DuplicateCullPlan] = [:]
        plans.reserveCapacity(clusters.count)
        for cluster in clusters {
            plans[cluster.id] = plan(for: cluster, index: index, userID: UInt32(currentUserID))
        }
        return plans
    }

    private func plan(for cluster: DuplicateProcessCluster, index: SampleIndex, userID: UInt32) -> DuplicateCullPlan {
        // Sample metrics are the fresher ones; a member whose identity is not
        // in the sample has exited or its PID was recycled.
        let live = cluster.members.compactMap { index.live($0.identity) }
        var kept: [ProcessIdentity: (rule: DuplicateCullPlan.Rule, reason: String)] = [:]
        var candidates: [ProcessMetrics] = []
        for copy in live {
            if let keep = keepReason(copy, index: index, userID: userID) {
                kept[copy.identity] = keep
            } else if copy.identity == cluster.keepIdentity {
                kept[copy.identity] = (.recommendedKeep, "Kept as \(cluster.keepReason)")
            } else {
                candidates.append(copy)
            }
        }

        // Members arrive largest first, so the cap keeps the biggest wins.
        for copy in candidates.dropFirst(DuplicateCullPlan.maximumStops) {
            kept[copy.identity] = (.overLimit, "Past the \(DuplicateCullPlan.maximumStops)-copy limit for one pass")
        }
        var roots = Array(candidates.prefix(DuplicateCullPlan.maximumStops))
        var riders = followers(of: roots, live: live, kept: kept, index: index)
        if !roots.isEmpty, roots.count + riders.count == live.count,
           let newest = roots.max(by: { Self.startsBefore($0, $1) }) {
            // Stopping every copy is not "the extras": the newest idle one
            // is the likeliest still wanted.
            roots.removeAll { $0.identity == newest.identity }
            kept[newest.identity] = (.keptNewest, "Newest idle copy, kept in case it is still wanted")
            riders = followers(of: roots, live: live, kept: kept, index: index)
        }

        let rootIDs = Set(roots.map(\.identity))
        let decisions = live.map { copy -> DuplicateCullPlan.Decision in
            if rootIDs.contains(copy.identity) {
                return .init(process: copy, verdict: .stop, rule: .orphaned,
                             reason: "Orphaned \u{2014} the app that started it is gone")
            }
            if let root = riders[copy.identity] {
                return .init(process: copy, verdict: .stop, rule: .stopsWithCopy,
                             reason: "Started by the copy with PID \(root.pid); stops with it", stopsWith: root)
            }
            let keep = kept[copy.identity] ?? (.usedByParent, "In use")
            return .init(process: copy, verdict: .keep, rule: keep.rule, reason: keep.reason)
        }
        return DuplicateCullPlan(clusterID: cluster.id, displayName: cluster.displayName, decisions: decisions)
    }

    /// Nil when the copy is a stop candidate: yours, idle, and orphaned.
    private func keepReason(
        _ copy: ProcessMetrics,
        index: SampleIndex,
        userID: UInt32
    ) -> (rule: DuplicateCullPlan.Rule, reason: String)? {
        if copy.userID != userID || copy.isSystemProcess {
            return (.notYours, "Not yours")
        }
        if copy.cpuPercent >= Self.busyCPUPercent {
            return (.busy, "Busy right now (\(RadarFormat.percent(copy.cpuPercent)) CPU)")
        }
        if let port = copy.forensics.listeningPorts.min() {
            return (.busy, "Busy right now (serving port \(port))")
        }
        guard copy.parentPID == 1 else {
            if let parent = index.byPID[copy.parentPID] {
                return (.usedByParent, "Used by \(parent.name)")
            }
            return (.parentOutsideScan, "Started by PID \(copy.parentPID), outside this scan")
        }
        // launchd is the parent of orphans, but also of the agents, XPC
        // services, Homebrew services and apps it runs on purpose.
        let path = copy.executablePath
        let lowered = path.lowercased()
        if KillRiskAssessor.isLaunchdManagedService(path: path)
            || LaunchOrigin.isLaunchdManaged(path: path, commandLine: copy.commandLine)
            || lowered.contains("/contents/xpcservices/") || lowered.contains(".xpc/") {
            return (.launchdService, "Run by launchd, which would start it again")
        }
        if KillRiskAssessor.isAppMainBinary(path: path, name: copy.name) {
            return (.openedApp, "An app you opened")
        }
        if copy.cpuMeasurementStatus == .unavailable {
            return (.unmeasured, "CPU not measured yet")
        }
        if copy.cpuPercent >= Self.idleCPUPercent {
            return (.lightWork, "Still doing some work (\(RadarFormat.percent(copy.cpuPercent)) CPU)")
        }
        if index.hasBusyDescendant(copy, busyCPUPercent: Self.busyCPUPercent) {
            return (.busyChild, "Something it started is busy")
        }
        return nil
    }

    /// Kept copies of yours that a stopped copy started: its stop takes
    /// their whole tree, so the plan must say so rather than claim to keep them.
    private func followers(
        of roots: [ProcessMetrics],
        live: [ProcessMetrics],
        kept: [ProcessIdentity: (rule: DuplicateCullPlan.Rule, reason: String)],
        index: SampleIndex
    ) -> [ProcessIdentity: ProcessIdentity] {
        guard !roots.isEmpty else { return [:] }
        let rootIDs = Set(roots.map(\.identity))
        var riders: [ProcessIdentity: ProcessIdentity] = [:]
        for copy in live where kept[copy.identity]?.rule == .usedByParent {
            if let root = index.ancestor(of: copy, in: rootIDs) {
                riders[copy.identity] = root
            }
        }
        return riders
    }

    private static func startsBefore(_ lhs: ProcessMetrics, _ rhs: ProcessMetrics) -> Bool {
        (lhs.identity.startTimeSeconds, lhs.identity.startTimeMicroseconds, lhs.pid)
            < (rhs.identity.startTimeSeconds, rhs.identity.startTimeMicroseconds, rhs.pid)
    }
}

private struct SampleIndex {
    /// Bounds tree walks, as ad-hoc stop families are bounded.
    private static let walkLimit = ProcessFamily.adHocMemberLimit

    let byPID: [Int32: ProcessMetrics]
    private let childrenByParent: [Int32: [ProcessMetrics]]

    init(_ sample: [ProcessMetrics]) {
        var byPID: [Int32: ProcessMetrics] = [:]
        var children: [Int32: [ProcessMetrics]] = [:]
        byPID.reserveCapacity(sample.count)
        for process in sample {
            byPID[process.pid] = process
            if process.pid != process.parentPID {
                children[process.parentPID, default: []].append(process)
            }
        }
        self.byPID = byPID
        childrenByParent = children
    }

    func live(_ identity: ProcessIdentity) -> ProcessMetrics? {
        guard let process = byPID[identity.pid], process.identity == identity else { return nil }
        return process
    }

    func hasBusyDescendant(_ root: ProcessMetrics, busyCPUPercent: Double) -> Bool {
        var queue = [root]
        var cursor = 0
        while cursor < queue.count, queue.count < Self.walkLimit {
            let parent = queue[cursor]
            cursor += 1
            // A child cannot start before its parent; older ones hold a recycled parent PID.
            for child in childrenByParent[parent.pid] ?? []
            where child.identity.startTimeSeconds >= parent.identity.startTimeSeconds {
                if child.cpuPercent >= busyCPUPercent || !child.forensics.listeningPorts.isEmpty {
                    return true
                }
                queue.append(child)
            }
        }
        return false
    }

    func ancestor(of process: ProcessMetrics, in candidates: Set<ProcessIdentity>) -> ProcessIdentity? {
        var current = process
        for _ in 0..<Self.walkLimit {
            guard current.parentPID > 1, let parent = byPID[current.parentPID],
                  parent.identity.startTimeSeconds <= current.identity.startTimeSeconds else { return nil }
            if candidates.contains(parent.identity) { return parent.identity }
            current = parent
        }
        return nil
    }
}
