import Darwin
import Foundation

/// Search subjects for the latest sample: every tracked family plus every
/// running process the radar does not track. Folded text is cached per
/// process identity, so a refresh only folds processes that are new or were
/// renamed, and nothing is built until someone actually searches.
public struct ProcessSearchIndex: Sendable {
    public struct Untracked: Sendable {
        public let process: ProcessMetrics
        public let subject: SearchSubject
    }

    private(set) var familySubjects: [String: SearchSubject] = [:]
    private(set) var untracked: [Untracked] = []
    private var texts: [ProcessIdentity: SearchableProcess] = [:]
    private var builtFor: (sample: UInt64, content: SnapshotContentRevision)?
    private let currentUserID: UInt32

    public init(currentUserID: UInt32 = UInt32(geteuid())) {
        self.currentUserID = currentUserID
    }

    public mutating func update(
        rows: [FamilyTriageViewModel],
        families: [ProcessFamily],
        processes: [ProcessMetrics],
        sampleRevision: UInt64,
        contentRevision: SnapshotContentRevision
    ) {
        if let builtFor, builtFor.sample == sampleRevision, builtFor.content == contentRevision {
            return
        }
        var live: [ProcessIdentity: SearchableProcess] = [:]
        live.reserveCapacity(processes.count)
        let familiesByKey = Dictionary(families.map { ($0.familyKey, $0) }, uniquingKeysWith: { first, _ in first })

        var subjects: [String: SearchSubject] = [:]
        subjects.reserveCapacity(rows.count)
        var trackedIdentities = Set<ProcessIdentity>()
        for row in rows {
            let family = familiesByKey[row.familyKey]
            if let family { trackedIdentities.formUnion(family.members.map(\.identity)) }
            subjects[row.familyKey] = subject(for: row, family: family, live: &live)
        }

        var untracked: [Untracked] = []
        untracked.reserveCapacity(max(0, processes.count - trackedIdentities.count))
        for process in processes where !trackedIdentities.contains(process.identity) {
            var flags: Set<ProcessSearchQuery.Flag> = [.untracked]
            if process.userID == currentUserID { flags.insert(.mine) }
            if process.isSystemProcess { flags.insert(.system) }
            let subject = SearchSubject(
                root: text(for: process, live: &live),
                measurements: SearchMeasurements(
                    cpuPercent: process.cpuPercent,
                    memoryBytes: Double(process.memoryForScoringBytes),
                    gpuPercent: process.gpuUsagePercent,
                    threads: Double(process.threadCount)
                ),
                flags: flags
            )
            untracked.append(Untracked(process: process, subject: subject))
        }

        texts = live
        familySubjects = subjects
        self.untracked = untracked
        builtFor = (sampleRevision, contentRevision)
    }

    /// Subjects for rows alone, when no live sample is at hand.
    static func subjects(for rows: [FamilyTriageViewModel]) -> [String: SearchSubject] {
        let index = ProcessSearchIndex()
        var live: [ProcessIdentity: SearchableProcess] = [:]
        return Dictionary(rows.map { ($0.familyKey, index.subject(for: $0, family: nil, live: &live)) },
                          uniquingKeysWith: { first, _ in first })
    }

    private func subject(
        for row: FamilyTriageViewModel,
        family: ProcessFamily?,
        live: inout [ProcessIdentity: SearchableProcess]
    ) -> SearchSubject {
        var flags: Set<ProcessSearchQuery.Flag> = [.tracked]
        if row.needsAttention { flags.insert(.attention) } else { flags.insert(.quiet) }
        if row.level >= .hot { flags.insert(.hot) }
        if row.level == .critical { flags.insert(.critical) }
        if row.hasCredibleLeak { flags.insert(.leaking) }
        if row.isKillable { flags.insert(.killable) }
        if row.kind != .unknownHeavy, row.devConfidence >= 0.35 { flags.insert(.dev) }

        let root: SearchableProcess
        var helpers: [SearchableProcess] = []
        var threads = 0
        if let family {
            root = text(for: family.root, live: &live)
            for member in family.members {
                threads += member.threadCount
                if member.identity != family.root.identity { helpers.append(text(for: member, live: &live)) }
            }
            if family.root.userID == currentUserID { flags.insert(.mine) }
            if family.root.isSystemProcess { flags.insert(.system) }
            if let cluster = family.duplicateCluster, !cluster.isInternalToSingleFamily { flags.insert(.duplicate) }
        } else {
            root = SearchableProcess(
                pid: row.familyID.pid,
                name: row.displayName,
                commandLine: row.subtitle,
                executablePath: row.signature.canonicalPath,
                ownerName: ""
            )
        }
        return SearchSubject(
            root: root,
            helpers: helpers,
            kindLabel: row.kindText,
            measurements: SearchMeasurements(
                cpuPercent: row.cpuPercent,
                memoryBytes: Double(row.memoryBytes),
                gpuPercent: row.gpuPercent,
                threads: Double(threads),
                leakMegabytesPerMinute: row.leakVelocity,
                children: Double(row.childCount)
            ),
            flags: flags
        )
    }

    private func text(for process: ProcessMetrics, live: inout [ProcessIdentity: SearchableProcess]) -> SearchableProcess {
        if let reused = live[process.identity] { return reused }
        let ports = process.forensics.listeningPorts
        let text: SearchableProcess
        if let cached = texts[process.identity],
           cached.displayName == process.name,
           cached.commandLine == process.commandLine,
           cached.executablePath == process.executablePath,
           cached.ownerName == process.ownerName {
            text = cached.updating(listeningPorts: ports)
        } else {
            text = SearchableProcess(
                pid: process.pid,
                name: process.name,
                commandLine: process.commandLine,
                executablePath: process.executablePath,
                ownerName: process.ownerName,
                listeningPorts: ports
            )
        }
        live[process.identity] = text
        return text
    }
}
