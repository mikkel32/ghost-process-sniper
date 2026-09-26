import Foundation

/// Stop risk for family pages and stop plans. Assessing reads the name, path
/// and command line of everything the stop would hit, so it runs once per
/// change in that set instead of on every render; metrics change each
/// refresh, identities don't. The workload is rebuilt per sample because the
/// reclaim estimate and preflight read its CPU and memory.
struct StopRiskCache {
    struct Entry {
        let key: Int
        let revision: UInt64
        let workload: KillWorkloadProfile
        let risk: KillRiskAssessment
        /// Why the root can never be stopped (Ghost runs inside it, or it
        /// ends the login session); nil for an ordinary family.
        let blockedReason: String?
    }

    private let assessor = KillRiskAssessor()
    private let protection: KillProtectionPolicy

    init(protection: KillProtectionPolicy = KillProtectionPolicy()) {
        self.protection = protection
    }
    private var entries: [String: Entry] = [:]
    private var index: KillSampleIndex?
    private var revision: UInt64?
    /// Assessments actually run, for tests of the memo.
    private(set) var assessmentCount = 0

    var entryCount: Int { entries.count }

    mutating func entry(
        for family: ProcessFamily,
        sample: [ProcessMetrics],
        revision sampleRevision: UInt64,
        liveFamilyKeys: @autoclosure () -> Set<String>
    ) -> Entry {
        if revision != sampleRevision {
            revision = sampleRevision
            index = nil
            let live = liveFamilyKeys()
            entries = entries.filter { live.contains($0.key) }
        }
        let sampleIndex = index ?? KillSampleIndex(sample)
        index = sampleIndex
        let stopSet = KillWorkloadProfile.stopSet(root: family.root, index: sampleIndex, family: family)
        let key = Self.key(root: family.root, stopSet: stopSet)
        let memo = entries[family.familyKey].flatMap { $0.key == key ? $0 : nil }
        if let memo, memo.revision == sampleRevision {
            return memo
        }
        let workload = KillWorkloadProfile(root: family.root, stopSet: stopSet, index: sampleIndex)
        let risk: KillRiskAssessment
        if let memo {
            risk = memo.risk
        } else {
            risk = assessor.assess(workload)
            assessmentCount += 1
        }
        // Ghost's parent chain can change between samples (a reparented
        // shell), so the floor is looked up on every sample, not memoized.
        let blocked = protection.neverReason(forRoot: family.root) { sampleIndex.byPID[$0]?.parentPID }
        let entry = Entry(key: key, revision: sampleRevision, workload: workload, risk: risk, blockedReason: blocked)
        entries[family.familyKey] = entry
        return entry
    }

    /// Names, paths, command lines and ports only change with the stop set.
    static func key(root: ProcessMetrics, stopSet: [ProcessMetrics]) -> Int {
        var hasher = Hasher()
        hasher.combine(root.identity)
        hasher.combine(root.parentPID)
        for member in stopSet.sorted(by: { $0.pid < $1.pid }) {
            hasher.combine(member.identity)
            hasher.combine(member.forensics.listeningPorts)
        }
        return hasher.finalize()
    }
}

public extension ProcessMonitor {
    /// What stopping the family would interrupt, for its page and its stop
    /// preview alike, so both always agree.
    func stopRisk(for family: ProcessFamily) -> KillRiskAssessment {
        stopRiskEntry(for: family).risk
    }

    /// Why the family can never be stopped, such as Ghost running inside
    /// it; the family page disables its stop button and says so.
    func stopBlockedReason(for family: ProcessFamily) -> String? {
        stopRiskEntry(for: family).blockedReason
    }

    internal func stopWorkload(for family: ProcessFamily) -> KillWorkloadProfile {
        stopRiskEntry(for: family).workload
    }

    private func stopRiskEntry(for family: ProcessFamily) -> StopRiskCache.Entry {
        stopRiskCache.entry(
            for: family,
            sample: sampledProcesses,
            revision: sampleRevision,
            liveFamilyKeys: Set(families.map(\.familyKey))
        )
    }
}
