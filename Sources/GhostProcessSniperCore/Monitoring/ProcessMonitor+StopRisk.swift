import Foundation

/// Stop risk for family pages and stop plans. Assessing reads every member's
/// name, path and command line, so it runs once per change in membership
/// instead of on every render; metrics change each refresh, identities don't.
struct StopRiskCache {
    struct Entry {
        let key: Int
        let workload: KillWorkloadProfile
        let risk: KillRiskAssessment
    }

    private let assessor = KillRiskAssessor()
    private var entries: [String: Entry] = [:]
    private var index: [Int32: ProcessMetrics]?
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
        let key = Self.key(for: family)
        if let entry = entries[family.familyKey], entry.key == key {
            return entry
        }
        let pids = index ?? KillWorkloadProfile.pidIndex(sample)
        index = pids
        let workload = KillWorkloadProfile(family: family, index: pids)
        let entry = Entry(key: key, workload: workload, risk: assessor.assess(workload))
        assessmentCount += 1
        entries[family.familyKey] = entry
        return entry
    }

    /// Names, paths, command lines and ports only change with membership.
    static func key(for family: ProcessFamily) -> Int {
        var hasher = Hasher()
        hasher.combine(family.root.identity)
        hasher.combine(family.root.parentPID)
        for member in family.members.sorted(by: { $0.pid < $1.pid }) {
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
